import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import AudioToolbox
import Carbon
import CoreAudio
import Foundation

enum NativeServiceError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

struct MicrophoneDevice: Identifiable, Sendable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

@MainActor
protocol AudioRecording: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start(deviceID: AudioDeviceID?) throws -> URL
    func stop() throws -> URL
    func cancel()
}

/// The file is protected by one lock shared by the tap and shutdown. Closing the
/// sink waits for any current write and prevents late buffers writing a closed file.
private final class RecordingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failure: String?
    private let reportFailure: @Sendable (String) -> Void

    init(file: AVAudioFile, reportFailure: @escaping @Sendable (String) -> Void) {
        self.file = file
        self.reportFailure = reportFailure
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let file, failure == nil else { lock.unlock(); return }
        do {
            try file.write(from: buffer)
            lock.unlock()
        } catch {
            let message = "Could not save microphone audio: \(error.localizedDescription)"
            failure = message
            lock.unlock()
            reportFailure(message)
        }
    }

    func close() -> String? {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        return failure
    }
}

@MainActor
final class AudioRecorder: AudioRecording {
    var onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var sink: RecordingSink?
    private var recordingURL: URL?
    private var sessionID: UUID?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false

    static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestPermission() async -> Bool {
        switch Self.permissionStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// IDs are valid for the current device inventory; persist UID when possible.
    static func microphones() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return [] }
        return devices.compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            return MicrophoneDevice(
                id: id,
                name: deviceString(id, selector: kAudioObjectPropertyName) ?? "Microphone \(id)",
                uid: deviceString(id, selector: kAudioDevicePropertyDeviceUID) ?? ""
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func deviceString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // AudioHardwareBase.h documents retained CFString results for both
        // kAudioObjectPropertyName and kAudioDevicePropertyDeviceUID. Use the raw
        // unmanaged slot required by HAL, then balance that ownership explicitly.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// No microphone access occurs until this explicitly invoked method.
    func start(deviceID: AudioDeviceID? = nil) throws -> URL {
        guard sessionID == nil else { throw NativeServiceError.message("A recording is already in progress.") }
        guard Self.permissionStatus == .authorized else {
            throw NativeServiceError.message("Microphone access is required. Allow BolBhAI in System Settings → Privacy & Security → Microphone.")
        }
        if let deviceID, !Self.microphones().contains(where: { $0.id == deviceID }) {
            throw NativeServiceError.message("The selected microphone is no longer connected. Select another microphone.")
        }

        let currentEngine = AVAudioEngine()
        let input = currentEngine.inputNode
        if var deviceID {
            guard let unit = input.audioUnit else { throw NativeServiceError.message("The microphone audio unit is unavailable.") }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw NativeServiceError.message("Could not select microphone (Core Audio \(status)).") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NativeServiceError.message("The microphone has no usable audio format. Reconnect it or choose another device.")
        }

        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BolBhAI-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("recording.caf")
        do {
            let audioFile = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let currentSink = RecordingSink(file: audioFile) { [weak self] message in
                Task { @MainActor [weak self] in self?.fail(message, session: id) }
            }
            engine = currentEngine
            sink = currentSink
            recordingURL = url
            sessionID = id
            // Apple supports installing/removing a tap on a running node. We use
            // the hardware format and a new engine each time to avoid stale routes.
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                currentSink.write(buffer)
            }
            tapInstalled = true
            currentEngine.prepare()
            try currentEngine.start()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: currentEngine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fail("The microphone configuration changed. Recording was discarded; select a connected microphone and try again.", session: id)
                }
            }
            return url
        } catch {
            cancel()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() throws -> URL {
        guard let url = recordingURL, sessionID != nil else { throw NativeServiceError.message("There is no active recording.") }
        let failure = shutDown()
        recordingURL = nil
        if let failure {
            Self.deleteTemporaryRecording(url)
            throw NativeServiceError.message(failure)
        }
        return url
    }

    func cancel() {
        let url = recordingURL
        _ = shutDown()
        recordingURL = nil
        if let url { Self.deleteTemporaryRecording(url) }
    }

    /// Call after transcription too: successful stop transfers ownership to the caller.
    static func deleteTemporaryRecording(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("BolBhAI-"), url.lastPathComponent == "recording.caf",
           UUID(uuidString: String(parent.lastPathComponent.dropFirst(8))) != nil {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    private func fail(_ message: String, session: UUID) {
        guard sessionID == session else { return }
        cancel()
        onFailure?(message)
    }

    private func shutDown() -> String? {
        sessionID = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        let failure = sink?.close()
        sink = nil
        engine = nil
        return failure
    }

    isolated deinit { cancel() }
}

@MainActor
protocol GlobalShortcutHandling: AnyObject {
    func register(keyCode: UInt32, modifiers: UInt32, onPress: @escaping @MainActor () -> Void) throws
    func unregister()
}

/// Carbon receives only the registered shortcut; it does not monitor arbitrary
/// keystrokes or require Input Monitoring. Key releases suppress autorepeat.
@MainActor
final class GlobalShortcut: GlobalShortcutHandling {
    static let commandModifier = UInt32(cmdKey)
    static let optionModifier = UInt32(optionKey)
    static let controlModifier = UInt32(controlKey)
    static let shiftModifier = UInt32(shiftKey)
    private static let signature: OSType = 0x426F6C42 // BolB
    private static var nextID: UInt32 = 0
    private var identifier: UInt32 = 0
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var callback: (@MainActor () -> Void)?
    private var isPressed = false

    func register(keyCode: UInt32, modifiers: UInt32, onPress: @escaping @MainActor () -> Void) throws {
        let allowed = Self.commandModifier | Self.optionModifier | Self.controlModifier | Self.shiftModifier
        guard keyCode <= 127, modifiers != 0, modifiers & ~allowed == 0 else {
            throw NativeServiceError.message("Choose a physical key code from 0–127 and at least one Command, Option, Control, or Shift modifier.")
        }
        unregister()
        Self.nextID &+= 1
        identifier = Self.nextID
        callback = onPress
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let kind = GetEventKind(event)
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak shortcut] in shortcut?.receive(id: id, kind: kind) }
            return noErr
        }, eventTypes.count, &eventTypes, context, &handler)
        guard handlerStatus == noErr else {
            unregister()
            throw NativeServiceError.message("Could not install shortcut handler (Carbon \(handlerStatus)).")
        }
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: identifier), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard status == noErr else {
            unregister()
            throw NativeServiceError.message("Could not register shortcut (Carbon \(status)). The key combination may already be used by another app.")
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        callback = nil
        isPressed = false
        identifier = 0
    }

    private func receive(id: EventHotKeyID, kind: UInt32) {
        guard id.signature == Self.signature, id.id == identifier, identifier != 0 else { return }
        if kind == UInt32(kEventHotKeyReleased) { isPressed = false; return }
        guard kind == UInt32(kEventHotKeyPressed), !isPressed else { return }
        isPressed = true
        callback?()
    }

    isolated deinit { unregister() }
}

struct InsertionTarget {
    let application: NSRunningApplication
    let processIdentifier: pid_t
    let applicationName: String
    fileprivate let focusedElement: AXUIElement?
    fileprivate let role: String?
    fileprivate let subrole: String?
    fileprivate let clipboardChangeCount: Int
}

enum InsertionResult: Equatable {
    /// The target accepted an AX write or received a paste event. Applications
    /// provide no general acknowledgement of actual insertion; test them manually.
    case inserted
    case manual(reason: String)
}

@MainActor
protocol TextInserting: AnyObject {
    func captureTarget() -> InsertionTarget?
    func insert(_ text: String, target: InsertionTarget?, allowClipboardFallback: Bool) async -> InsertionResult
    func copy(_ text: String)
}

@MainActor
final class TextInserter: TextInserting {
    private typealias ClipboardSnapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private var clipboardRestorePending = false

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Invoke only from the user's permission button, not during dictation.
    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func captureTarget() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = Self.accessibilityTrusted ? Self.focusedElement(in: app.processIdentifier) : nil
        return InsertionTarget(
            application: app,
            processIdentifier: app.processIdentifier,
            applicationName: app.localizedName ?? "Application",
            focusedElement: element,
            role: element.flatMap { Self.stringAttribute(kAXRoleAttribute, from: $0) },
            subrole: element.flatMap { Self.stringAttribute(kAXSubroleAttribute, from: $0) },
            clipboardChangeCount: NSPasteboard.general.changeCount
        )
    }

    func insert(_ text: String, target: InsertionTarget?, allowClipboardFallback: Bool = true) async -> InsertionResult {
        guard !Task.isCancelled else { return .manual(reason: "Insertion cancelled.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .manual(reason: "There is no text to insert.") }
        guard let target else { return .manual(reason: "No target application was captured. Copy the transcript and paste it where needed.") }
        if let reason = validate(target) { return .manual(reason: reason) }
        guard let element = target.focusedElement else { return .manual(reason: "The focused field cannot be verified. Use Copy and paste manually.") }

        var settable = DarwinBoolean(false)
        let check = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if check == .success, settable.boolValue {
            if let reason = validate(target) { return .manual(reason: reason) }
            guard !Task.isCancelled else { return .manual(reason: "Insertion cancelled.") }
            // kAXSelectedText inserts at the current selection; setting kAXValue
            // would replace the entire field and is deliberately never used.
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            if result == .success { return .inserted }
            // A failed write can be ambiguous in a hung app. Do not retry as paste,
            // which could duplicate an edit that was accepted before timing out.
            return .manual(reason: "The application did not confirm Accessibility insertion (\(result.rawValue)). Check the field before pasting manually.")
        }

        guard allowClipboardFallback else { return .manual(reason: "This field does not support Accessibility insertion. Use Copy and paste manually.") }
        guard check == .success || check == .attributeUnsupported || check == .notImplemented else {
            return .manual(reason: "The application's insertion capabilities cannot be verified. Use Copy and paste manually.")
        }
        guard !clipboardRestorePending else { return .manual(reason: "A previous clipboard paste is finishing. Use Copy and paste manually.") }
        guard CGPreflightPostEventAccess() else { return .manual(reason: "macOS has not allowed keyboard event posting. Enable Accessibility access, or paste manually.") }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == target.clipboardChangeCount else {
            return .manual(reason: "The clipboard changed during dictation. It was preserved; use Copy if you want to replace it.")
        }
        guard let snapshot = snapshotClipboard(pasteboard) else {
            return .manual(reason: "The current clipboard cannot be fully preserved. Use Copy and paste manually.")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return .manual(reason: "Could not create a paste event. Use Copy and paste manually.")
        }
        // Clipboard providers can block while loading promised data. Recheck after
        // the snapshot and immediately before both clipboard mutation and posting.
        if let reason = validate(target) { return .manual(reason: reason) }
        guard !Task.isCancelled else { return .manual(reason: "Insertion cancelled.") }
        guard pasteboard.changeCount == target.clipboardChangeCount else { return .manual(reason: "The clipboard changed while preparing insertion. Use Copy and paste manually.") }
        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount
        guard pasteboard.setString(text, forType: .string) else {
            if pasteboard.changeCount == clearedChangeCount { restore(snapshot, to: pasteboard) }
            return .manual(reason: "Could not prepare clipboard text. Use Copy and paste manually.")
        }
        let ownChangeCount = pasteboard.changeCount
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Routing to the remembered PID avoids dispatching text to a newly focused
        // application in the very small interval between validation and posting.
        keyDown.postToPid(target.processIdentifier)
        keyUp.postToPid(target.processIdentifier)
        clipboardRestorePending = true
        // Unstructured task intentionally survives dictation cancellation after
        // posting. A user/application clipboard change always wins over restoration.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self else { return }
            if pasteboard.changeCount == ownChangeCount { self.restore(snapshot, to: pasteboard) }
            self.clipboardRestorePending = false
        }
        return .inserted
    }

    func copy(_ text: String) {
        // Explicit user action may intentionally replace a changed clipboard.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func validate(_ target: InsertionTarget) -> String? {
        guard !target.application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return "Focus changed from \(target.applicationName). Copy the transcript and paste it into the intended field."
        }
        // Newlines pasted into a shell can execute commands without an Enter
        // event. Terminal automation is outside this prototype's scope.
        if target.application.bundleIdentifier == "com.apple.Terminal" || target.subrole == "AXTerminal" {
            return "Automatic insertion into terminal fields is disabled. Review and copy the transcript manually."
        }
        guard Self.accessibilityTrusted else { return "Accessibility access is required to verify the target. Enable it in settings or use Copy." }
        guard !IsSecureEventInputEnabled() else { return "Secure keyboard input is active. Automatic insertion is disabled; use a supported field." }
        guard let captured = target.focusedElement, let current = Self.focusedElement(in: target.processIdentifier), CFEqual(captured, current) else {
            return "The focused field changed or cannot be verified. Copy the transcript and paste it where needed."
        }
        let role = Self.stringAttribute(kAXRoleAttribute, from: current)
        let subrole = Self.stringAttribute(kAXSubroleAttribute, from: current)
        guard role == target.role, subrole == target.subrole else { return "The focused field changed. Use Copy and paste manually." }
        guard subrole != kAXSecureTextFieldSubrole as String else { return "Automatic insertion into password fields is disabled." }
        let supported = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        guard let role, supported.contains(role) else { return "This focused element is not a supported text field. Use Copy and paste manually." }
        return nil
    }

    private static func focusedElement(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func snapshotClipboard(_ pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        var snapshot: ClipboardSnapshot = []
        for item in pasteboard.pasteboardItems ?? [] {
            var stored: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                stored.append((type, data))
            }
            snapshot.append(stored)
        }
        return snapshot
    }

    private func restore(_ snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) {
        let items = snapshot.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
