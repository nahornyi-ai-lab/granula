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
                Text("Настройка Granula").font(Theme.serif(24))
            }
            Text("Четыре шага, один раз. Звук и расшифровка остаются на этом Mac; для ИИ-итога текст расшифровки отправляется в Claude.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(number: 1, title: "Микрофон", detail: "Ваш голос — дорожка «Я».",
                 state: micOK ? .ok : (micDenied ? .failed(String(localized: "Доступ запрещён — включите Granula в Настройках")) : .idle)) {
                if micDenied {
                    Button("Открыть Настройки") { openSettings("Privacy_Microphone") }
                } else if !micOK {
                    Button("Разрешить") {
                        Task {
                            micOK = await MicCapture.requestAccess()
                            micDenied = !micOK
                        }
                    }
                }
            }

            step(number: 2, title: "Звук звонка",
                 detail: "Голос собеседника — дорожка «Собеседник». Проверка проиграет короткий звук.",
                 state: systemState) {
                if systemState != .ok {
                    Button { runSystemCheck() } label: {
                        systemState == .idle ? Text("Проверить") : Text("Проверить снова")
                    }
                        .disabled(systemState == .running)
                    if case .failed = systemState {
                        Button("Открыть Настройки") { openSettings("Privacy_ScreenCapture") }
                    }
                }
            }

            step(number: 3, title: "Модель распознавания",
                 detail: "Parakeet, ~600 МБ, работает без интернета. Русский, украинский, английский.",
                 state: modelState) {
                if modelState == .running {
                    ProgressView(value: modelProgress).frame(width: 120)
                } else if modelState != .ok {
                    Button("Загрузить") { loadModel() }
                }
            }

            step(number: 4, title: "Календарь",
                 detail: "Встречи из «Календаря» Mac: список предстоящих и напоминание за минуту. Granula только читает.",
                 state: calendarAccess == .granted ? .ok : (calendarAccess == .denied ? .failed(String(localized: "Доступ запрещён — включите Granula в Настройках → Календари")) : .idle)) {
                if calendarAccess != .granted {
                    Button {
                        Task {
                            await model.connectCalendar()
                            calendarAccess = CalendarWatcher.access
                        }
                    } label: {
                        calendarAccess == .denied ? Text("Открыть Настройки") : Text("Разрешить")
                    }
                }
            }

            HStack {
                Spacer()
                Button("Готово") {
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
                "Звук не дошёл. Разрешите Granula в «Настройки → Конфиденциальность → Запись экрана и системного звука → Только системный звук», затем «Проверить снова»."))
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
                modelState = .failed(String(localized: "Не загрузилась: \(error.localizedDescription)"))
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
