import SwiftUI
import AppKit

@main struct BolBhAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra("BolBhAI", systemImage: model.session.state == .recording ? "mic.fill" : "waveform") {
            MenuContent(model: model)
        }
        Window("BolBhAI", id: "settings") {
            SettingsView(model: model)
        }.defaultSize(width: 700, height: 760)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shutdownHandler: (@MainActor () async -> Void)?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await Self.shutdownHandler?(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("BolBhAI · \(model.session.state.rawValue.capitalized)")
        Text(model.session.message).font(.caption)
        Button(model.session.state == .recording ? "Stop recording" : "Start recording") { model.toggle() }
            .disabled(model.isPreparing || model.session.isStarting || [.transcribing, .cleaning].contains(model.session.state))
        if model.session.isBusy || model.isPreparing { Button("Cancel") { model.cancel() } }
        if model.session.result != nil { Button("Copy transcript") { model.copy() } }
        Divider()
        Button("Settings & transcripts…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit BolBhAI") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
