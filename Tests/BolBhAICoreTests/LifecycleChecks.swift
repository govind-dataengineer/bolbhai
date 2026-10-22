import Foundation
@testable import BolBhAICore

/// These mocks keep requests suspended even when their task is cancelled. Tests
/// choose exactly when an obsolete backend returns, after a new session starts.
private actor ControlledSpeech: TranscriptionService {
    private var nextRequest = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var returned: Set<Int> = []

    func transcribe(_ audio: URL, configuration: SpeechConfiguration) async throws -> String {
        nextRequest += 1
        let request = nextRequest
        let text = try await withCheckedThrowingContinuation { continuation in
            pending[request] = continuation
        }
        returned.insert(request)
        return text
    }

    func hasPending(_ request: Int) -> Bool { pending[request] != nil }
    func hasReturned(_ request: Int) -> Bool { returned.contains(request) }
    func release(_ request: Int, text: String) throws {
        guard let continuation = pending.removeValue(forKey: request) else { throw LifecycleCheckError.missingRequest }
        continuation.resume(returning: text)
    }
    func releaseAll() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private actor ControlledCleanup: CleanupService {
    private var nextRequest = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var returned: Set<Int> = []

    func clean(_ text: String, configuration: CleanupConfiguration) async throws -> String {
        nextRequest += 1
        let request = nextRequest
        let result = try await withCheckedThrowingContinuation { continuation in
            pending[request] = continuation
        }
        returned.insert(request)
        return result
    }

    func hasPending(_ request: Int) -> Bool { pending[request] != nil }
    func hasReturned(_ request: Int) -> Bool { returned.contains(request) }
    func release(_ request: Int, text: String) throws {
        guard let continuation = pending.removeValue(forKey: request) else { throw LifecycleCheckError.missingRequest }
        continuation.resume(returning: text)
    }
    func releaseAll() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private actor SequenceSpeech: TranscriptionService {
    private var count = 0
    func transcribe(_ audio: URL, configuration: SpeechConfiguration) async throws -> String {
        count += 1
        return count == 1 ? "obsolete raw transcript" : "current raw transcript"
    }
}

private struct PassthroughCleanup: CleanupService {
    func clean(_ text: String, configuration: CleanupConfiguration) async throws -> String { text }
}

@MainActor
private final class LifecycleRecorder: RecordingService {
    let directory: URL
    private(set) var recordings: [URL] = []
    private var current: URL?

    init(directory: URL) { self.directory = directory }
    func start() async throws -> URL {
        guard current == nil else { throw LifecycleCheckError.overlappingRecording }
        let url = directory.appendingPathComponent("audio-\(UUID().uuidString).caf")
        try Data([1]).write(to: url)
        recordings.append(url)
        current = url
        return url
    }
    func stop() throws -> URL {
        guard let url = current else { throw LifecycleCheckError.noRecording }
        current = nil
        return url
    }
    func cancel() {
        if let current { try? FileManager.default.removeItem(at: current) }
        current = nil
    }
}

private enum LifecycleCheckError: Error {
    case timeout, missingRequest, noRecording, overlappingRecording
}

@MainActor private final class SuspendedPermissionRecorder: RecordingService {
    let url: URL
    private var permission: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { permission != nil }
    var returned = false
    init(url: URL) { self.url = url }
    func start() async throws -> URL {
        await withCheckedContinuation { permission = $0 }
        try Data([1]).write(to: url)
        returned = true
        return url
    }
    func stop() throws -> URL { url }
    func cancel() { try? FileManager.default.removeItem(at: url) }
    func answer() { let pending = permission; permission = nil; pending?.resume() }
}

/// A bounded synchronous actor occupation makes the history append genuinely
/// queue behind another job. Only this test actor thread waits; the main actor
/// polls flags asynchronously and always releases the occupation on exit.
private final class HistoryQueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var occupied = false
    private var appendRequested = false
    private var timedOut = false

    var isOccupied: Bool { lock.withLock { occupied } }
    var didRequestAppend: Bool { lock.withLock { appendRequested } }
    var didTimeOut: Bool { lock.withLock { timedOut } }
    func markAppendRequested() { lock.withLock { appendRequested = true } }
    func occupy() {
        lock.withLock { occupied = true }
        let result = semaphore.wait(timeout: .now() + 2)
        lock.withLock { timedOut = result == .timedOut }
    }
    func release() { semaphore.signal() }
}

private extension HistoryStore {
    func occupyExecutorForCheck(_ gate: HistoryQueueGate) { gate.occupy() }
}

@MainActor
func runLifecycleChecks() async throws {
    let tests = LifecycleChecks()
    try await checks("obsolete transcription cannot replace restarted session") { try await tests.testLateTranscriptionAfterRestart() }
    try await checks("obsolete cleanup cannot replace restarted session") { try await tests.testLateCleanupAfterRestart() }
    try await checks("cancelled queued history append cannot write") { try await tests.testCancelledQueuedHistoryAppend() }
    try await checks("graceful shutdown joins a previously cancelled backend") { try await tests.testShutdownWaitsForRetiringProcessing() }
    try await checks("graceful shutdown does not wait for microphone permission") { try await tests.testShutdownDoesNotWaitForPermission() }
}

@MainActor
private final class LifecycleChecks {
    private func fixture() throws -> (URL, SpeechConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BolBhAI-lifecycle-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let model = directory.appendingPathComponent("fixture-model.bin")
        var header = Data([0x6c, 0x6d, 0x67, 0x67, 0x99, 0xca, 0, 0])
        header.append(Data(repeating: 0, count: 8))
        try header.write(to: model)
        return (directory, SpeechConfiguration(executablePath: "/usr/bin/true", modelPath: model.path))
    }

    private func waitFor(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LifecycleCheckError.timeout
    }

    func testShutdownWaitsForRetiringProcessing() async throws {
        let (directory, speech) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = ControlledSpeech()
        let recorder = LifecycleRecorder(directory: directory)
        let session = DictationSession(recorder: recorder, transcription: backend, cleanup: PassthroughCleanup())
        var finished = false, started = false, delivered = false
        session.onReady = { _ in delivered = true }
        do {
            session.begin(speech: speech, cleanup: .init(), clean: false)
            try await waitFor { session.state == .recording }
            session.stop()
            try await waitFor { await backend.hasPending(1) }
            session.cancel()
            let shutdown = Task { started = true; await session.cancelAndWait(); finished = true }
            try await waitFor { started }
            XCTAssertFalse(finished, "Quit must join retiring processing before exiting")
            try await backend.release(1, text: "Obsolete text")
            await shutdown.value
            XCTAssertTrue(finished); XCTAssertFalse(delivered)
            XCTAssertEqual(session.state, .idle)
            XCTAssertTrue(recorder.recordings.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        } catch { await backend.releaseAll(); throw error }
    }

    func testShutdownDoesNotWaitForPermission() async throws {
        let (directory, speech) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SuspendedPermissionRecorder(url: directory.appendingPathComponent("permission.caf"))
        let session = DictationSession(recorder: recorder, transcription: SequenceSpeech(), cleanup: PassthroughCleanup())
        var finished = false
        do {
            session.begin(speech: speech, cleanup: .init(), clean: false)
            try await waitFor { recorder.isWaiting }
            let shutdown = Task { await session.cancelAndWait(); finished = true }
            try await waitFor { finished }
            await shutdown.value
            XCTAssertTrue(recorder.isWaiting, "Quit must complete while permission remains unanswered")
            recorder.answer()
            try await waitFor { recorder.returned }
            XCTAssertEqual(session.state, .idle); XCTAssertFalse(session.isStarting)
            XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path))
        } catch { recorder.answer(); session.cancel(); throw error }
    }

    func testLateTranscriptionAfterRestart() async throws {
        let (directory, speech) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = ControlledSpeech()
        let recorder = LifecycleRecorder(directory: directory)
        let session = DictationSession(recorder: recorder, transcription: backend, cleanup: PassthroughCleanup())
        defer { session.cancel() }
        var delivered: [String] = []
        session.onReady = { delivered.append($0.raw) }
        do {
            session.begin(speech: speech, cleanup: .init(), clean: false)
            try await waitFor { session.state == .recording }
            session.stop()
            try await waitFor { await backend.hasPending(1) }
            session.cancel()
            session.begin(speech: speech, cleanup: .init(), clean: false)
            try await waitFor { session.state == .recording }
            session.stop()
            try await waitFor { await backend.hasPending(2) }

            try await backend.release(1, text: "obsolete transcript")
            try await waitFor { await backend.hasReturned(1) }
            // Give the resumed session task an executor turn before checking
            // intermediate state; the current request remains explicitly blocked.
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(session.state, .transcribing)
            XCTAssertNil(session.result)
            XCTAssertEqual(session.rawTranscript, "")
            XCTAssertTrue(delivered.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.recordings[1].path))

            try await backend.release(2, text: "current transcript")
            try await waitFor { session.state == .ready }
            XCTAssertEqual(session.result?.raw, "current transcript")
            XCTAssertEqual(delivered, ["current transcript"])
            XCTAssertTrue(recorder.recordings.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        } catch { await backend.releaseAll(); throw error }
    }

    func testLateCleanupAfterRestart() async throws {
        let (directory, speech) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = ControlledCleanup()
        let recorder = LifecycleRecorder(directory: directory)
        let session = DictationSession(recorder: recorder, transcription: SequenceSpeech(), cleanup: backend)
        defer { session.cancel() }
        var delivered: [String] = []
        session.onReady = { delivered.append($0.cleaned) }
        do {
            session.begin(speech: speech, cleanup: .init(), clean: true)
            try await waitFor { session.state == .recording }
            session.stop()
            try await waitFor { await backend.hasPending(1) }
            session.cancel()
            session.begin(speech: speech, cleanup: .init(), clean: true)
            try await waitFor { session.state == .recording }
            session.stop()
            try await waitFor { await backend.hasPending(2) }

            try await backend.release(1, text: "Obsolete cleaned transcript.")
            try await waitFor { await backend.hasReturned(1) }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(session.state, .cleaning)
            XCTAssertNil(session.result)
            XCTAssertEqual(session.rawTranscript, "current raw transcript")
            XCTAssertTrue(delivered.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.recordings[1].path))

            try await backend.release(2, text: "Current cleaned transcript.")
            try await waitFor { session.state == .ready }
            XCTAssertEqual(session.result?.raw, "current raw transcript")
            XCTAssertEqual(session.result?.cleaned, "Current cleaned transcript.")
            XCTAssertEqual(delivered, ["Current cleaned transcript."])
            XCTAssertTrue(recorder.recordings.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        } catch { await backend.releaseAll(); throw error }
    }

    func testCancelledQueuedHistoryAppend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BolBhAI-history-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let store = HistoryStore(file: file)
        try await store.append(.init(raw: "existing", cleaned: "existing"), enabled: true)
        let originalData = try Data(contentsOf: file)
        let gate = HistoryQueueGate()
        let occupation = Task { await store.occupyExecutorForCheck(gate) }
        defer { gate.release() }
        try await waitFor { gate.isOccupied }

        let append = Task {
            gate.markAppendRequested()
            try await store.append(.init(raw: "obsolete", cleaned: "obsolete"), enabled: true)
        }
        try await waitFor { gate.didRequestAppend }
        append.cancel()
        gate.release()
        await occupation.value
        do { try await append.value; XCTFail("A cancelled queued append must throw CancellationError.") }
        catch is CancellationError { }
        XCTAssertFalse(gate.didTimeOut)
        XCTAssertEqual(try Data(contentsOf: file), originalData)
        let retained = try await store.entries(enabled: true)
        XCTAssertEqual(retained.map(\.raw), ["existing"])
        try await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
