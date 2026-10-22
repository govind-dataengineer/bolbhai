import SwiftUI
import BolBhAICore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform.circle.fill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) { Text("BolBhAI").font(.title.bold()); Text("Voice to text, on this Mac").foregroundStyle(.secondary) }
                Spacer()
                Text(model.session.state.rawValue.capitalized).padding(8).background(.quaternary, in: Capsule())
            }
            Picker("View", selection: $model.selectedSection) { Text("Dictation").tag(0); Text("Settings").tag(1); Text("History").tag(2) }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.selectedSection == 0 { dictation }
                    if model.selectedSection == 1 { settings }
                    if model.selectedSection == 2 { history }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
        }.padding(24).frame(minWidth: 620, minHeight: 600)
    }
    private var dictation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.session.message).foregroundStyle(model.session.state == .error ? .red : .secondary).textSelection(.enabled)
            HStack {
                Button(model.session.state == .recording ? "Stop recording" : "Start recording") { model.toggle() }.buttonStyle(.borderedProminent)
                    .disabled(model.isPreparing || model.session.isStarting || [.transcribing, .cleaning].contains(model.session.state))
                Button("Cancel") { model.cancel() }.disabled(!model.session.isBusy && !model.isPreparing)
                Spacer()
                Picker("Mode", selection: $model.preferences.clean) { Text("Verbatim").tag(false); Text("Clean").tag(true) }.frame(width: 210).disabled(model.session.isBusy || model.isPreparing)
            }
            Text("Use the global shortcut while your destination text field is focused. Starting here provides a transcript for copying.").font(.caption).foregroundStyle(.secondary)
            GroupBox("Raw transcript") { Text(model.session.rawTranscript.isEmpty ? "Your original transcription appears here." : model.session.rawTranscript).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading).padding(6) }
            GroupBox("Final text") { Text(model.session.result?.cleaned ?? "Ready after processing.").textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading).padding(6) }
            if let result = model.session.result {
                Text(result.cleanupStatus).font(.caption).textSelection(.enabled)
                Text(String(format: "Transcription %.2f s · Cleanup %.2f s", result.transcriptionTime, result.cleanupTime)).font(.caption).foregroundStyle(.secondary)
                Button("Copy final text") { model.copy() }
            }
            Text(model.insertionStatus).font(.caption).textSelection(.enabled)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Speech") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { TextField("Whisper model path", text: $model.preferences.modelPath); Button("Choose…") { model.choosePath(\.modelPath) } }
                    HStack { TextField("whisper-cli path", text: $model.preferences.executablePath); Button("Choose…") { model.choosePath(\.executablePath, executable: true) } }
                    HStack { TextField("whisper-server path (resident model)", text: $model.preferences.workerPath); Button("Choose…") { model.choosePath(\.workerPath, executable: true) } }
                    Picker("Language", selection: $model.preferences.language) { Text("Detect · English/Hindi/Hinglish").tag("auto"); Text("English").tag("en"); Text("Hindi").tag("hi") }
                    HStack { Text(model.speechStatus).font(.caption); Spacer(); Button("Validate") { model.validateSpeech() } }
                    Picker("Microphone", selection: $model.preferences.microphoneUID) { Text("System default").tag(""); ForEach(model.microphones) { Text($0.name).tag($0.uid) } }
                    HStack { Button("Refresh microphones") { model.refreshMicrophones() }; Button("Microphone permission…") { model.openPrivacy("Microphone") } }
                }.padding(6)
            }
            GroupBox("Optional cleanup · LM Studio") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Localhost origin", text: $model.preferences.endpoint)
                    TextField("Exact cleanup model ID", text: $model.preferences.cleanupModel)
                    if !model.models.isEmpty {
                        Picker("Available model", selection: $model.preferences.cleanupModel) {
                            Text(model.preferences.cleanupModel).tag(model.preferences.cleanupModel)
                            ForEach(model.models.filter { $0.id != model.preferences.cleanupModel }) { Text("\($0.displayName) · \($0.isLoaded == true ? "loaded" : "on disk")").tag($0.id) }
                        }
                    }
                    HStack { Text(model.modelStatus).font(.caption); Spacer(); Button("Refresh models") { model.refreshModels() } }
                    Text(model.cleanupPrivacyStatus).font(.caption).textSelection(.enabled)
                    Text("Clean mode requires LM Studio’s Redact Content enabled, File Logging OFF, and verbose/token logs disabled. Restart the server after changing those settings. BolBhAI checks them before sending dictation.").font(.caption).foregroundStyle(.secondary)
                    Text("LM Studio’s local service must remain running for Clean mode. Verbatim works without it. Review cleanup for changes in meaning.").font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox("Shortcut & insertion") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Modifiers", selection: $model.preferences.shortcutModifiers) { Text("⌘ ⇧").tag(UInt32(768)); Text("⌃ ⌥").tag(UInt32(6144)); Text("⌘ ⌥").tag(UInt32(2304)); Text("⌃ ⇧").tag(UInt32(4608)) }
                        Picker("Key", selection: $model.preferences.shortcutKey) { Text("Space").tag(UInt32(49)); Text("D").tag(UInt32(2)); Text("B").tag(UInt32(11)); Text("F").tag(UInt32(3)) }
                    }
                    Text(model.shortcutStatus).font(.caption)
                    Toggle("Insert into the original focused field when safe", isOn: $model.preferences.autoInsert)
                    Toggle("Allow clipboard/paste fallback", isOn: $model.preferences.clipboardFallback)
                    Button("Enable Accessibility…") { model.requestAccessibility() }
                    Text("Focus changes, password fields, unsupported fields, or a changed clipboard require manual copying. No Enter key is sent. Toggle recording only; hold mode is deferred.").font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox("Personal dictionary · Clean mode only") {
                VStack(alignment: .leading) {
                    Text("One mapping per line: spoken phrase = preferred spelling. Only complete word/phrase matches are replaced after successful cleanup.").font(.caption)
                    TextEditor(text: $model.preferences.dictionaryText).font(.system(.body, design: .monospaced)).frame(height: 90)
                    Text("\(model.preferences.dictionary.count) valid entries (maximum 100 used)").font(.caption)
                }.padding(6)
            }
        }.textFieldStyle(.roundedBorder).disabled(model.session.isBusy || model.isPreparing)
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Save local history", isOn: $model.preferences.historyEnabled)
            Text("Disabled by default. When enabled, stores raw and final text in plaintext on this Mac for 7 days, up to 100 entries. Disabling deletes saved history. Deletion removes the file; it is not secure disk erasure.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Delete all history") { model.clearHistory() }; Button("Refresh") { model.refreshHistory() } }
            Text(model.storageStatus).font(.caption)
            ForEach(model.history) { entry in
                GroupBox(entry.date.formatted()) { VStack(alignment: .leading) { Text(entry.cleaned).textSelection(.enabled); DisclosureGroup("Raw transcript") { Text(entry.raw).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading).padding(6) }
            }
        }
    }
}
