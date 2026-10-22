import AppKit
import SwiftUI
import Combine
import BolBhAICore
import CoreAudio

struct Preferences: Codable, Equatable {
    var modelPath = ""
    var executablePath = ""
    var workerPath = ""
    var language = "auto"
    var clean = false
    var endpoint = "http://127.0.0.1:1234"
    var cleanupModel = "google/gemma-4-e4b"
    var microphoneUID = ""
    var shortcutKey: UInt32 = 49
    var shortcutModifiers: UInt32 = 768
    var autoInsert = true
    var clipboardFallback = true
    var historyEnabled = false
    var dictionaryText = ""
    var speech: SpeechConfiguration { .init(executablePath: executablePath, modelPath: modelPath, language: language) }
    var cleanup: CleanupConfiguration { .init(endpoint: endpoint, modelID: cleanupModel) }
    var dictionary: [DictionaryEntry] {
        dictionaryText.split(separator: "\n").compactMap { line in
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else { return nil }
            return DictionaryEntry(spoken: pair[0], written: pair[1])
        }
    }
}

@MainActor final class RecorderAdapter: RecordingService {
    let recorder = AudioRecorder()
    var microphoneUID = ""
    func start() async throws -> URL {
        guard await recorder.requestPermission() else { throw NativeServiceError.message("Allow microphone access in System Settings → Privacy & Security → Microphone.") }
        try Task.checkCancellation()
        let device = AudioRecorder.microphones().first { $0.uid == microphoneUID }
        if !microphoneUID.isEmpty, device == nil { throw NativeServiceError.message("Selected microphone disconnected. Refresh microphones and select a connected device.") }
        return try recorder.start(deviceID: device?.id)
    }
    func stop() throws -> URL { try recorder.stop() }
    func cancel() { recorder.cancel() }
}

/// Switching configuration swaps services only while idle. Each worker retains one model.
actor SpeechRouter: TranscriptionService {
    private var worker: PersistentWhisperService?
    private var path = ""
    func configure(workerPath: String) async {
        if path == workerPath { return }
        await worker?.shutdown(); path = workerPath
        worker = FileManager.default.isExecutableFile(atPath: workerPath) ? PersistentWhisperService(serverPath: workerPath) : nil
    }
    func transcribe(_ audio: URL, configuration: SpeechConfiguration) async throws -> String {
        if let worker { return try await worker.transcribe(audio, configuration: configuration) }
        return try await WhisperCLIService().transcribe(audio, configuration: configuration)
    }
    func shutdown() async { await worker?.shutdown() }
}

@MainActor final class AppModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "preferences-v1") }
            if oldValue.shortcutKey != preferences.shortcutKey || oldValue.shortcutModifiers != preferences.shortcutModifiers { registerShortcut() }
            if oldValue.historyEnabled != preferences.historyEnabled {
                historyGeneration = UUID(); insertionTask?.cancel(); refreshHistory()
            }
        }
    }
    @Published var microphones: [MicrophoneDevice] = []
    @Published var models: [LMStudioModel] = []
    @Published var modelStatus = "Refresh to check LM Studio"
    @Published var cleanupPrivacyStatus = "Checking local logging settings…"
    @Published var speechStatus = ""
    @Published var shortcutStatus = ""
    @Published var insertionStatus = ""
    @Published var history: [HistoryEntry] = []
    @Published var storageStatus = ""
    @Published var selectedSection = 0
    @Published private(set) var isPreparing = false
    let session: DictationSession
    let adapter = RecorderAdapter()
    let shortcut = GlobalShortcut()
    let inserter = TextInserter()
    let router = SpeechRouter()
    let overlay = RecordingOverlay()
    let historyStore: HistoryStore
    private var target: InsertionTarget?
    private var subscription: AnyCancellable?
    private var timeoutTask: Task<Void, Never>?
    private var insertionTask: Task<Void, Never>?
    private var beginTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var historyGeneration = UUID()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BolBhAI")
        historyStore = HistoryStore(file: support.appendingPathComponent("history.json"))
        var prefs = UserDefaults.standard.data(forKey: "preferences-v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        let resourceBin = Bundle.main.resourceURL?.appendingPathComponent("bin")
        let repository = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent() : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if prefs.executablePath.isEmpty { prefs.executablePath = resourceBin?.appendingPathComponent("whisper-cli").path ?? "" }
        if !FileManager.default.isExecutableFile(atPath: prefs.executablePath) { prefs.executablePath = repository.appendingPathComponent(".local/whisper.cpp/build/bin/whisper-cli").path }
        if prefs.workerPath.isEmpty { prefs.workerPath = resourceBin?.appendingPathComponent("whisper-server").path ?? "" }
        if !FileManager.default.isExecutableFile(atPath: prefs.workerPath) { prefs.workerPath = repository.appendingPathComponent(".local/whisper.cpp/build/bin/whisper-server").path }
        if prefs.modelPath.isEmpty {
            let installed = support.appendingPathComponent("Models/ggml-small.bin")
            prefs.modelPath = FileManager.default.isReadableFile(atPath: installed.path) ? installed.path : repository.appendingPathComponent(".local/models/ggml-small.bin").path
        }
        preferences = prefs
        session = DictationSession(recorder: adapter, transcription: router, cleanup: LMStudioCleanupService())
        AppDelegate.shutdownHandler = { [weak self] in await self?.shutdown() }
        subscription = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send(); self?.updateOverlay() }
        }
        session.onReady = { [weak self] result in self?.completed(result) }
        adapter.recorder.onFailure = { [weak self] message in self?.cancel(message: message); self?.session.fail(message: message) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel(message: "Mac went to sleep. Recording discarded; ready to retry after wake."); await self?.router.shutdown() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMicrophones(); self?.validateSpeech() }
        })
        refreshMicrophones(); validateSpeech(); validateCleanupPrivacy(); registerShortcut(); refreshHistory()
    }

    func toggle() {
        if session.state == .recording { timeoutTask?.cancel(); session.stop(); return }
        guard !session.isBusy, beginTask == nil else { return }
        generation = UUID(); let token = generation
        target = inserter.captureTarget(); insertionStatus = ""; isPreparing = true
        adapter.microphoneUID = preferences.microphoneUID
        let prefs = preferences
        beginTask = Task {
            await router.configure(workerPath: prefs.workerPath)
            guard !Task.isCancelled, token == generation else { return }
            session.begin(speech: prefs.speech, cleanup: prefs.cleanup, clean: prefs.clean, dictionary: prefs.dictionary)
            beginTask = nil; isPreparing = false
        }
    }
    func cancel(message: String = "Cancelled") {
        cancelClientWork()
        session.cancel(message: message); overlay.hide()
    }
    private func cancelClientWork() {
        generation = UUID(); isPreparing = false
        beginTask?.cancel(); beginTask = nil; insertionTask?.cancel(); timeoutTask?.cancel(); timeoutTask = nil
        target = nil
    }
    func completed(_ result: DictationResult) {
        timeoutTask?.cancel(); overlay.hide()
        let intended = target, auto = preferences.autoInsert, fallback = preferences.clipboardFallback
        let token = generation
        let historyToken = historyGeneration
        insertionTask = Task {
            guard !Task.isCancelled, token == generation else { return }
            if auto {
                let outcome = await inserter.insert(result.cleaned, target: intended, allowClipboardFallback: fallback)
                guard !Task.isCancelled, token == generation else { return }
                switch outcome {
                case .inserted: insertionStatus = "Insertion requested. Check the destination; no Enter key was sent."
                case .manual(let reason): insertionStatus = reason + " Use Copy for manual insertion."
                }
            } else { insertionStatus = "Ready to copy." }
            guard !Task.isCancelled, token == generation, historyToken == historyGeneration else { return }
            do { try await historyStore.append(.init(raw: result.raw, cleaned: result.cleaned), enabled: preferences.historyEnabled); await loadHistory() }
            catch { storageStatus = "History storage failed: \(error.localizedDescription)" }
        }
    }
    func copy() { if let result = session.result { inserter.copy(result.cleaned); insertionStatus = "Copied. Paste manually when ready." } }
    func refreshMicrophones() { microphones = AudioRecorder.microphones() }
    func validateSpeech() {
        do { try preferences.speech.validate(); speechStatus = "Multilingual model readable · " + (FileManager.default.isExecutableFile(atPath: preferences.workerPath) ? "persistent worker available" : "CLI reloads model each time") }
        catch { speechStatus = error.localizedDescription }
    }
    func refreshModels() {
        validateCleanupPrivacy()
        modelStatus = "Checking localhost…"
        let config = preferences.cleanup
        Task {
            do {
                let discovered = try await LMStudioCleanupService().discoverModels(configuration: config)
                guard preferences.cleanup == config else { return }
                models = discovered.filter { ["llm", "unknown"].contains($0.type) }
                modelStatus = "\(models.count) local models · " + (models.first { $0.id == config.modelID || $0.loadedInstanceIDs?.contains(config.modelID) == true }.map { $0.isLoaded == true ? "selected model loaded" : "selected model not loaded / state unknown" } ?? "select an available model")
            } catch { guard preferences.cleanup == config else { return }; models = []; modelStatus = error.localizedDescription }
        }
    }
    func validateCleanupPrivacy() {
        do { try LMStudioLoggingPolicy().validate(configuration: preferences.cleanup); cleanupPrivacyStatus = "Local logging settings are disabled. Restart LM Studio's server after changing them." }
        catch { cleanupPrivacyStatus = error.localizedDescription }
    }
    func registerShortcut() {
        do { try shortcut.register(keyCode: preferences.shortcutKey, modifiers: preferences.shortcutModifiers) { [weak self] in self?.toggle() }; shortcutStatus = "Toggle shortcut registered" }
        catch { shortcutStatus = error.localizedDescription }
    }
    func choosePath(_ keyPath: WritableKeyPath<Preferences, String>, executable: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        panel.message = executable ? "Select a whisper.cpp executable" : "Select a multilingual whisper.cpp GGML model"
        if panel.runModal() == .OK, let url = panel.url { preferences[keyPath: keyPath] = url.path; validateSpeech() }
    }
    func requestAccessibility() { TextInserter.requestAccessibilityPermission() }
    func openPrivacy(_ name: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(name)") { NSWorkspace.shared.open(url) } }
    func refreshHistory() { Task { await loadHistory() } }
    private func loadHistory() async {
        let token = historyGeneration
        do { let loaded = try await historyStore.entries(enabled: preferences.historyEnabled); guard token == historyGeneration else { return }; history = loaded }
        catch { storageStatus = error.localizedDescription }
    }
    func clearHistory() {
        historyGeneration = UUID(); insertionTask?.cancel()
        Task { do { try await historyStore.clear(); history = []; storageStatus = "History deleted" } catch { storageStatus = error.localizedDescription } }
    }
    private func updateOverlay() {
        if session.state == .recording, timeoutTask == nil {
            let token = generation
            timeoutTask = Task {
                try? await Task.sleep(for: .seconds(300))
                if !Task.isCancelled, token == generation, session.state == .recording { session.stop() }
            }
        } else if session.state != .recording {
            timeoutTask?.cancel(); timeoutTask = nil
        }
        if session.isBusy { overlay.show(state: session.state.rawValue, message: session.isStarting ? "Microphone permission…" : session.message) }
        else { overlay.hide() }
    }
    func shutdown() async {
        cancelClientWork(); overlay.hide(); shortcut.unregister()
        await session.cancelAndWait()
        await router.shutdown()
    }
}

@MainActor final class RecordingOverlay {
    private var panel: NSPanel?
    func show(state: String, message: String) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: HStack(spacing: 12) {
            Image(systemName: state == "recording" ? "mic.fill" : "waveform").foregroundStyle(state == "recording" ? Color.red : Color.accentColor)
            VStack(alignment: .leading) { Text(state.capitalized).font(.headline); Text(message).font(.caption).lineLimit(1) }
        }.padding(14).frame(width: 320, height: 64).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame; panel?.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.minY + 36))
        }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
}
