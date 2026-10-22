import Foundation
import AVFoundation
@testable import BolBhAICore

private struct FakeTranscriber: TranscriptionService {
    var delay: UInt64 = 0
    func transcribe(_ audio: URL, configuration: SpeechConfiguration) async throws -> String {
        // Intentionally ignore cancellation to simulate a backend returning a stale result.
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return "do not send 42"
    }
}

@MainActor func runSessionChecks() async throws {
    let tests = SessionTests()
    try await checks("session states, fallback, audio deletion") { try await tests.testStatesFallbackAndAudioDeletion() }
    try await checks("cancel discards late results") { try await tests.testCancelDiscardsLateResultAndDeletesAudio() }
    try await checks("dictionary boundaries") { tests.testDictionaryWordBoundaries() }
    try await checks("configuration") { try tests.testConfigurationRejectsEnglishOnlyModelAndRemoteEndpoint() }
    try await checks("history opt-in retention deletion") { try await tests.testHistoryOptInRetentionAndDeletion() }
    try await checks("subprocess cancellation file cleanup") { try await tests.testSubprocessFailureAndCancellationCleanup() }
    try await checks("silent audio rejection and temporary file cleanup") { try await tests.testSilenceRejectedBeforeInference() }
    try await checks("mono PCM conversion and right-channel speech downmix") { try await tests.testMonoAndStereoConversion() }
}
private struct FailedCleanup: CleanupService {
    func clean(_ text: String, configuration: CleanupConfiguration) async throws -> String { throw CleanupError.unavailable }
}
@MainActor private final class FakeRecorder: RecordingService {
    let url: URL
    init(url: URL) { self.url = url }
    func start() async throws -> URL { try Data([1]).write(to: url); return url }
    func stop() throws -> URL { url }
    func cancel() { try? FileManager.default.removeItem(at: url) }
}

@MainActor final class SessionTests: XCTestCase {
    func fixture() throws -> (URL, SpeechConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data([0x6c,0x6d,0x67,0x67,0x99,0xca,0,0]); data.append(Data(repeating: 0, count: 8))
        let model = directory.appendingPathComponent("model.bin"); try data.write(to: model)
        return (directory, SpeechConfiguration(executablePath: "/usr/bin/true", modelPath: model.path))
    }
    func waitFor(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("State did not settle")
    }
    func testStatesFallbackAndAudioDeletion() async throws {
        let (directory, speech) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("recording.caf")
        let session = DictationSession(recorder: FakeRecorder(url: audio), transcription: FakeTranscriber(), cleanup: FailedCleanup())
        session.begin(speech: speech, cleanup: .init(), clean: true)
        try await waitFor { session.state == .recording }
        session.begin(speech: speech, cleanup: .init(), clean: false)
        XCTAssertEqual(session.state, .recording)
        session.stop(); XCTAssertEqual(session.state, .transcribing)
        try await waitFor { session.state == .ready }
        XCTAssertEqual(session.result?.raw, session.result?.cleaned)
        XCTAssertTrue(session.result?.cleanupStatus.contains("failed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }
    func testCancelDiscardsLateResultAndDeletesAudio() async throws {
        let (directory, speech) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("recording.caf")
        let session = DictationSession(recorder: FakeRecorder(url: audio), transcription: FakeTranscriber(delay: 200_000_000), cleanup: FailedCleanup())
        var delivered = false; session.onReady = { _ in delivered = true }
        session.begin(speech: speech, cleanup: .init(), clean: true)
        try await waitFor { session.state == .recording }; session.stop(); session.cancel()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(session.state, .idle); XCTAssertNil(session.result); XCTAssertFalse(delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }
    func testDictionaryWordBoundaries() {
        let entry = DictionaryEntry(spoken: "ram", written: "RAM")
        XCTAssertEqual(PersonalDictionary.apply([entry], to: "ram program राम"), "RAM program राम")
        XCTAssertEqual(PersonalDictionary.apply([.init(spoken: "राम", written: "Ram")], to: "राम रामायण"), "Ram रामायण")
        XCTAssertEqual(PersonalDictionary.apply([.init(spoken: "cafe", written: "Cafe")], to: "cafe cafe\u{301}"), "Cafe cafe\u{301}")
    }
    func testConfigurationRejectsEnglishOnlyModelAndRemoteEndpoint() throws {
        let (directory, speech) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try speech.validate()
        var english = try Data(contentsOf: URL(fileURLWithPath: speech.modelPath)); english[4] = 0x98
        try english.write(to: URL(fileURLWithPath: speech.modelPath)); XCTAssertThrowsError(try speech.validate())
        XCTAssertThrowsError(try CleanupConfiguration(endpoint: "http://example.com:1234").validate())
    }
    func testHistoryOptInRetentionAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let store = HistoryStore(file: historyURL)
        try await store.append(.init(raw: "private", cleaned: "private"), enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        try await store.append(.init(raw: "old", cleaned: "old", date: Date().addingTimeInterval(-8 * 86400)), enabled: true)
        let entries = try await store.entries(enabled: true); XCTAssertTrue(entries.isEmpty)
        try await store.append(.init(raw: "new", cleaned: "new"), enabled: true)
        let disabled = try await store.entries(enabled: false); XCTAssertTrue(disabled.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
    }
    func testSubprocessFailureAndCancellationCleanup() async throws {
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("BolBhAI-process-") })
        do { _ = try await ProcessRunner.run("/usr/bin/false", arguments: []); XCTFail("Expected failure") } catch { }
        let task = Task { try await ProcessRunner.run("/bin/sleep", arguments: ["5"]) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("BolBhAI-process-") })
        XCTAssertEqual(before, after)
    }
    func testSilenceRejectedBeforeInference() async throws {
        let (directory, speech) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("silence.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            memset(buffer.floatChannelData![0], 0, 16000 * MemoryLayout<Float>.size)
            try file.write(from: buffer)
        }
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("BolBhAI-inference-") })
        do { _ = try await WhisperCLIService().transcribe(audio, configuration: speech); XCTFail("Silence must fail before inference") }
        catch { XCTAssertTrue(error.localizedDescription.contains("silent")) }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("BolBhAI-inference-") })
        XCTAssertEqual(before, after)
    }
    func testMonoAndStereoConversion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for channels in [1, 2] {
            let source = directory.appendingPathComponent("\(channels)-channel.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: AVAudioChannelCount(channels))!
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false]
            do {
                let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
                buffer.frameLength = 16000
                for channel in 0..<channels {
                    for frame in 0..<16000 {
                        // Stereo deliberately has silence in the left channel.
                        buffer.floatChannelData![channel][frame] = channel == channels - 1 ? 0.4 * sin(Float(frame) * 0.1) : 0
                    }
                }
                try file.write(from: buffer)
            }
            let output = directory.appendingPathComponent("converted-\(channels)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let converted = try await AudioPreparation.convert(source, in: output)
            let statistics = try AudioPreparation.validate(converted)
            XCTAssertTrue(statistics.peak > 0.19, "Mono output must preserve the non-silent channel")
        }
    }
}
