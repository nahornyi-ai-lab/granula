import AppKit
import GranulaCore
import SwiftUI

@main
struct GranulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Granula", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
                .sheet(isPresented: $model.showOnboarding) {
                    OnboardingView().environmentObject(model)
                }
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                // ⌥⌘R itself is the global hot key; a menu shortcut too would toggle twice.
                Button(model.recordMenuTitle) { model.toggleRecording() }
            }
            CommandGroup(after: .appSettings) {
                Button("Permissions and model…") { model.showOnboarding = true }
                Button("Meetings folder…") { model.chooseFolder() }
                LanguagePicker().environmentObject(model)
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            if model.isRecording {
                Image(systemName: "record.circle.fill")
            } else {
                Image(nsImage: Theme.menuBarMark)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.quitCleanup() }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let snapshot = model.snapshot {
            Text("Recording · \(Transcript.clock(snapshot.elapsed))")
        }
        Button(model.recordMenuTitle) { model.toggleRecording() }
        Button("Open Granula") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        if model.calendarAccess == .granted {
            Toggle("Meeting reminders", isOn: $model.remindersOn)
        } else {
            Button("Connect calendar") { Task { await model.connectCalendar() } }
        }
        Button("Permissions and model…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.showOnboarding = true
        }
        Button("Meetings folder…") { model.chooseFolder() }
        LanguagePicker()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// "Language" submenu with a check mark next to the current choice.
struct LanguagePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Language", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
            ForEach(AppLanguage.allCases) { Text(verbatim: $0.name).tag($0) }
        }
    }
}

extension AppModel {
    /// ⌥⌘R itself is the global hot key; it is shown in the title, not bound as a menu shortcut.
    var recordMenuTitle: String {
        (isRecording ? String(localized: "Stop recording") : String(localized: "New meeting")) + "  ⌥⌘R"
    }
}
