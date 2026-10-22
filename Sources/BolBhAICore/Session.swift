import Foundation
import Combine

@MainActor public protocol RecordingService: AnyObject {
    func start() async throws -> URL
    func stop() throws -> URL
    func cancel()
}

public enum SessionState: String, Sendable { case idle, recording, transcribing, cleaning, ready, error }

public struct DictationResult: Sendable {
    public let raw: String
    public let cleaned: String
    public let cleanupStatus: String
    public let transcriptionTime: TimeInterval
    public let cleanupTime: TimeInterval
}

@MainActor public final class DictationSession: ObservableObject {
    @Published public private(set) var state: SessionState = .idle
    @Published public private(set) var result: DictationResult?
    @Published public private(set) var rawTranscript = ""
    @Published public private(set) var message = "Ready to dictate"
    @Published public private(set) var isStarting = false
    public var onReady: ((DictationResult) -> Void)?
    private let recorder: any RecordingService
    private let transcription: any TranscriptionService
    private let cleanup: any CleanupService
    private var task: Task<Void, Never>?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var audioURL: URL?
    private var speech: SpeechConfiguration?
    private var cleanupConfiguration: CleanupConfiguration?
    private var useCleanup = false
    private var dictionary: [DictionaryEntry] = []

    public init(recorder: any RecordingService, transcription: any TranscriptionService, cleanup: any CleanupService) {
        self.recorder = recorder; self.transcription = transcription; self.cleanup = cleanup
    }
    public var isBusy: Bool { isStarting || [.recording, .transcribing, .cleaning].contains(state) }

    public func begin(speech: SpeechConfiguration, cleanup: CleanupConfiguration, clean: Bool, dictionary: [DictionaryEntry] = []) {
        guard !isBusy else { return }
        let token = UUID(); generation = token
        self.speech = speech; self.cleanupConfiguration = cleanup; useCleanup = clean; self.dictionary = dictionary
        result = nil; rawTranscript = ""; isStarting = true; message = "Requesting microphone…"
        task = Task {
            do {
                try speech.validate()
                if clean { try cleanup.validate() }
                let url = try await recorder.start()
                guard token == generation, !Task.isCancelled else { Self.deleteRecording(url); return }
                audioURL = url; isStarting = false; state = .recording; message = "Recording — toggle shortcut to stop"
            } catch {
                guard token == generation else { return }
                recorder.cancel(); isStarting = false; state = .error; message = error.localizedDescription
            }
        }
    }

    public func stop() {
        guard state == .recording, let speech, let cleanupConfiguration else { return }
        let token = generation
        do {
            let url = try recorder.stop()
            audioURL = url; state = .transcribing; message = "Transcribing locally…"
            let clean = useCleanup, entries = dictionary
            let processingTask = Task {
                defer { Self.deleteRecording(url); processingTasks[token] = nil; if generation == token { audioURL = nil } }
                do {
                    let start = Date()
                    let raw = try await transcription.transcribe(url, configuration: speech)
                    let speechTime = Date().timeIntervalSince(start)
                    guard token == generation, !Task.isCancelled else { return }
                    rawTranscript = raw
                    var edited = raw, cleanupTime: TimeInterval = 0, status = "Verbatim — cleanup bypassed"
                    var cleanupSucceeded = false
                    if clean {
                        state = .cleaning; message = "Cleaning through localhost…"
                        let start = Date()
                        do {
                            edited = try await cleanup.clean(raw, configuration: cleanupConfiguration)
                            cleanupSucceeded = true
                            status = "Cleanup completed — review for accuracy"
                        } catch is CancellationError { return }
                        catch { status = "Cleanup failed; raw retained. \(error.localizedDescription)" }
                        cleanupTime = Date().timeIntervalSince(start)
                    }
                    guard token == generation, !Task.isCancelled else { return }
                    // Verbatim truly preserves the transcript. Dictionary edits are explicit and only in Clean mode.
                    if clean && cleanupSucceeded { edited = PersonalDictionary.apply(entries, to: edited) }
                    let completed = DictationResult(raw: raw, cleaned: edited, cleanupStatus: status, transcriptionTime: speechTime, cleanupTime: cleanupTime)
                    result = completed; state = .ready; message = status; onReady?(completed)
                } catch is CancellationError { }
                catch {
                    guard token == generation else { return }
                    state = .error; message = error.localizedDescription
                }
            }
            task = processingTask
            processingTasks[token] = processingTask
        } catch { recorder.cancel(); removeAudio(); state = .error; message = error.localizedDescription }
    }

    public func cancel(message: String = "Cancelled") {
        generation = UUID(); task?.cancel(); task = nil
        processingTasks.values.forEach { $0.cancel() }
        recorder.cancel(); removeAudio(); isStarting = false
        state = .idle; result = nil; rawTranscript = ""; self.message = message
    }
    /// Graceful app termination joins every retiring inference job, including a
    /// prior cancelled session. Permission requests have no audio/process resources
    /// yet and may require user interaction, so they must not block Quit.
    public func cancelAndWait(message: String = "Cancelled") async {
        let pending = Array(processingTasks.values)
        cancel(message: message)
        for task in pending { await task.value }
    }
    public func fail(message: String) { cancel(message: message); state = .error }
    private func removeAudio() { if let audioURL { Self.deleteRecording(audioURL) }; audioURL = nil }
    private static func deleteRecording(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if url.lastPathComponent == "recording.caf", parent.lastPathComponent.hasPrefix("BolBhAI-"), UUID(uuidString: String(parent.lastPathComponent.dropFirst(8))) != nil {
            try? FileManager.default.removeItem(at: parent)
        } else { try? FileManager.default.removeItem(at: url) }
    }
}
