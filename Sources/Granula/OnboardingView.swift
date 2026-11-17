import AppKit
import AVFoundation
import GranulaCore
import os.lock
import SwiftUI

/// First run: microphone, system audio (checked with a real test sound), model.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var micOK = MicCapture.isAuthorized
    @State private var micDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    @State private var systemState: CheckState = .idle
    @State private var modelState: CheckState = Transcriber.modelsPresent ? .ok : .idle
    @State private var modelProgress = 0.0
    @State private var calendarAccess = CalendarWatcher.access

    enum CheckState: Equatable { case idle, running, ok, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                Text("Set up Granula").font(Theme.serif(24))
            }
            Text("Four steps, once. Audio and transcripts stay on this Mac; for the AI summary the transcript text is sent to Claude.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(number: 1, title: "Microphone", detail: "Your voice — the “Me” track.",
                 state: micOK ? .ok : (micDenied ? .failed(String(localized: "Access denied — turn Granula on in System Settings")) : .idle)) {
                if micDenied {
                    Button("Open Settings") { openSettings("Privacy_Microphone") }
                } else if !micOK {
                    Button("Allow") {
                        Task {
                            micOK = await MicCapture.requestAccess()
                            micDenied = !micOK
                        }
                    }
                }
            }

            step(number: 2, title: "Call audio",
                 detail: "The other side's voice — the “Them” track. The check plays a short sound.",
                 state: systemState) {
                if systemState != .ok {
                    Button { runSystemCheck() } label: {
                        systemState == .idle ? Text("Check") : Text("Check again")
                    }
                        .disabled(systemState == .running)
                    if case .failed = systemState {
                        Button("Open Settings") { openSettings("Privacy_ScreenCapture") }
                    }
                }
            }

            step(number: 3, title: "Speech recognition model",
                 detail: "Parakeet, ~600 MB, works offline. Russian, Ukrainian, English.",
                 state: modelState) {
                if modelState == .running {
                    ProgressView(value: modelProgress).frame(width: 120)
                } else if modelState != .ok {
                    Button("Download") { loadModel() }
                }
            }

            step(number: 4, title: "Calendar",
                 detail: "Meetings from the Mac Calendar app: the upcoming list and a reminder a minute before. Granula only reads.",
                 state: calendarAccess == .granted ? .ok : (calendarAccess == .denied ? .failed(String(localized: "Access denied — turn Granula on in System Settings → Calendars")) : .idle)) {
                if calendarAccess != .granted {
                    Button {
                        Task {
                            await model.connectCalendar()
                            calendarAccess = CalendarWatcher.access
                        }
                    } label: {
                        calendarAccess == .denied ? Text("Open Settings") : Text("Allow")
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    UserDefaults.standard.set(true, forKey: "onboardingDone")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    @ViewBuilder
    private func step(number: Int, title: LocalizedStringKey, detail: LocalizedStringKey, state: CheckState,
                      @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(state == .ok ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12))
                if state == .ok {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let why) = state {
                    Text(why).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state == .running && number != 3 {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer()
            actions()
        }
    }

    private func runSystemCheck() {
        systemState = .running
        Task {
            let heard = await SystemAudioCheck.run()
            systemState = heard ? .ok : .failed(String(localized:
                "No sound came through. Allow Granula in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then click “Check again”."))
        }
    }

    private func loadModel() {
        modelState = .running
        Task {
            do {
                try await Transcriber.shared.prepare { p in
                    Task { @MainActor in modelProgress = p }
                }
                modelState = .ok
            } catch {
                modelState = .failed(String(localized: "Failed to load: \(error.localizedDescription)"))
            }
        }
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Starts the system tap, plays a short sound from another process
/// (`afplay` — Granula itself is excluded from the tap) and checks that
/// something other than exact zeros arrived. A denied permission yields zeros.
enum SystemAudioCheck {
    @MainActor
    static func run() async -> Bool {
        let capture = SystemAudioCapture()
        let peak = OSAllocatedUnfairLock(initialState: Float(0))
        capture.onBuffer = { buffer in
            guard let data = buffer.floatChannelData else { return }
            var p: Float = 0
            for i in 0..<Int(buffer.frameLength) { p = max(p, abs(data[0][i])) }
            let current = p
            peak.withLock { $0 = max($0, current) }
        }
        do { try capture.start() } catch {
            Log.error("system.check_failed", error)
            return false
        }
        try? await Task.sleep(for: .milliseconds(400))
        let sound = Process()
        sound.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        sound.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try? sound.run()
        try? await Task.sleep(for: .milliseconds(1600))
        capture.stop()
        let heard = peak.withLock { $0 }
        Log.event("system.check", String(format: "peak=%.5f", heard))
        return heard > 0.0005
    }
}
