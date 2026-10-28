import AppKit
import Combine
import GranulaCore
import SwiftUI

/// App state: meetings on disk, the current recording, the call prompt.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var meetings: [MeetingRecord] = []
    @Published var selection: String?
    @Published private(set) var snapshot: Recorder.Snapshot?
    @Published var showOnboarding = false
    @Published private(set) var templates: [SummaryTemplate] = []
    @Published private(set) var upcoming: [CalendarMeeting] = []
    @Published private(set) var calendarAccess = CalendarWatcher.access
    @Published var remindersOn = UserDefaults.standard.object(forKey: AppModel.remindersKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(remindersOn, forKey: Self.remindersKey) }
    }
    static let remindersKey = "calendarReminders"
    @Published private(set) var language = AppLanguage.chosen

    let store = MeetingStore()
    private(set) lazy var processor = MeetingProcessor(store: store)
    private let callDetector = CallDetector()
    private let callPanel = CallPromptPanel()
    private var recorder: Recorder?
    private var recordingCallFamily: String?
    private var ticker: Timer?
    private var sleepObserver: NSObjectProtocol?
    private let calendar = CalendarWatcher()
    private var reminderTimer: Timer?
    private var reminded: Set<String> = []
    /// The calendar meeting the panel is showing, if it shows one.
    private var shownReminder: CalendarMeeting?
    private var recordingFromCalendar = false
    let e2e = E2EOptions(arguments: CommandLine.arguments)

    var isRecording: Bool { recorder != nil }
    var recordingID: String? { recorder?.record.id }

    private init() {}

    func launch() {
        Log.event("app.launched", "e2e=\(e2e.isActive)")
        Templates.installDefaults(in: store.templatesFolder)
        templates = Templates.all(in: store.templatesFolder)
        processor.onUpdate = { [weak self] in self?.handleUpdate($0) }
        meetings = store.loadAll()
        processor.recover()
        meetings = store.loadAll()

        callDetector.onCallDetected = { [weak self] app in self?.callDetected(app) ?? false }
        callDetector.onCallEnded = { [weak self] family in self?.callPanel.hide(callFamily: family) }
        callDetector.start()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording(reason: "sleep") }
        }
        HotKey.shared.register { [weak self] in self?.toggleRecording() }

        calendar.onChange = { [weak self] in
            guard let self else { return }
            upcoming = calendar.meetings
            checkReminder()
        }
        if e2e.isActive && CalendarWatcher.access == .notAsked {
            Task { await connectCalendar() }
        } else {
            calendar.start()
        }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReminder() }
        }

        if !e2e.isActive && !UserDefaults.standard.bool(forKey: "onboardingDone") {
            showOnboarding = true
        }
        if e2e.start {
            Task { await startRecording() }
        }
        if let folder = e2e.snapshotFolder {
            takeE2ESnapshots(to: folder)
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { stopRecording(reason: "user") } else { Task { await startRecording() } }
    }

    /// Starts a recording: plain, from the call prompt, or from a calendar meeting
    /// (its title and attendees go into meeting.json). A plain or call-prompt recording
    /// during a calendar meeting takes that meeting's title and attendees too.
    func startRecording(callApp: CallDetector.CallApp? = nil, event: CalendarMeeting? = nil) async {
        guard recorder == nil else { return }
        hidePanel()
        do {
            let linked = event ?? CalendarRules.current(in: calendar.meetings, now: Date())
            if event == nil, let linked { Log.event("calendar.linked", "title=\(linked.title)") }
            let title = linked?.title ?? callApp.map { String(localized: "Звонок в \($0.name)") }
                ?? String(localized: "Встреча")
            var record = try store.create(title: title, callApp: callApp?.family)
            if let linked {
                record.meeting.calendarEventID = linked.eventID
                record.meeting.attendees = linked.attendees.isEmpty ? nil : linked.attendees
                try store.save(record)
            }
            let recorder = try Recorder(record: record)
            self.recorder = recorder
            recordingFromCalendar = event != nil
            // Auto-stop only follows a call that is still on the microphone.
            recordingCallFamily = callApp.flatMap { callDetector.activeNow.contains($0.family) ? $0.family : nil }
            if event != nil, recordingCallFamily == nil, let family = callDetector.activeNow.sorted().first {
                adoptCall(family)
            }
            meetings.insert(record, at: 0)
            selection = record.id
            await recorder.start()
            // Stopped while start was waiting (permission prompt, sleep): nothing more to set up.
            guard self.recorder === recorder else { return }
            snapshot = recorder.snapshot
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            if let seconds = e2e.stopAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.stopRecording(reason: "e2e")
                }
            }
        } catch {
            Log.error("recording.start_failed", error)
            presentError(String(localized: "Не удалось начать запись: \(error.localizedDescription)"))
        }
    }

    func stopRecording(reason: String) {
        guard let recorder else { return }
        ticker?.invalidate()
        ticker = nil
        let peaks = recorder.stop()
        self.recorder = nil
        if let family = recordingCallFamily { callDetector.markHandled(family) }
        recordingCallFamily = nil
        recordingFromCalendar = false
        snapshot = nil
        Log.event("recording.stop_reason", reason)
        var record = store.load(folder: recorder.record.folder) ?? recorder.record
        record.meeting.endedAt = Date()
        record.meeting.status = .processing
        record.meeting.micPeak = peaks.mic
        record.meeting.systemPeak = peaks.system
        try? store.save(record)
        replace(record)
        processor.enqueue(record)
    }

    private func tick() {
        guard let recorder else { return }
        snapshot = recorder.snapshot
        if let family = recordingCallFamily, callDetector.isInactive(family, for: 15) {
            Log.event("recording.autostop", "app=\(family)")
            stopRecording(reason: "call_ended")
        }
    }

    // MARK: - Call prompt

    private func callDetected(_ app: CallDetector.CallApp) -> Bool {
        if isRecording {
            // A call that starts during a calendar meeting's recording ends it 15 s after the call.
            guard recordingFromCalendar, recordingCallFamily == nil else { return false }
            adoptCall(app.family)
            return true
        }
        // The meeting reminder already offers to record; it keeps the calendar title.
        if shownReminder != nil { return true }
        Log.event("call.prompt_shown", "app=\(app.family)")
        callPanel.show(app: app, onRecord: { [weak self] in
            Log.event("call.prompt_accepted", "app=\(app.family)")
            Task { await self?.startRecording(callApp: app) }
        }, onDismiss: { [weak self] in
            Log.event("call.prompt_dismissed", "app=\(app.family)")
            self?.callPanel.hide()
        })
        if e2e.acceptCallPrompt {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, !self.isRecording else { return }
                Log.event("call.prompt_accepted", "app=\(app.family) e2e=1")
                Task { await self.startRecording(callApp: app) }
            }
        }
        return true
    }

    private func adoptCall(_ family: String) {
        recordingCallFamily = family
        Log.event("calendar.call_adopted", "app=\(family)")
    }

    private func hidePanel() {
        callPanel.hide()
        shownReminder = nil
    }

    // MARK: - Calendar

    /// Asks for calendar access (the macOS prompt) or, if it was refused, opens Settings.
    func connectCalendar() async {
        if CalendarWatcher.access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        await calendar.requestAccess()
        calendarAccess = CalendarWatcher.access
        upcoming = calendar.meetings
    }

    /// Every 15 s: hides a stale reminder and shows the next one that is due.
    private func checkReminder() {
        let now = Date()
        if let shown = shownReminder, now.timeIntervalSince(shown.start) > CalendarRules.reminderHideAfter {
            Log.event("calendar.reminder_expired", "title=\(shown.title)")
            hidePanel()
        }
        guard remindersOn, let due = CalendarRules.dueReminder(
            in: calendar.meetings, now: now, reminded: reminded, isRecording: isRecording) else { return }
        reminded.insert(due.reminderKey)
        showReminder(due)
    }

    private func showReminder(_ meeting: CalendarMeeting) {
        let lead = meeting.start.timeIntervalSinceNow
        Log.event("calendar.reminder_shown", "title=\(meeting.title) lead=\(Int(lead.rounded()))")
        let minutes = max(1, Int((lead / 60).rounded(.up)))
        let title = lead > 0 ? String(localized: "Через \(minutes) мин: \(meeting.title)")
            : String(localized: "Сейчас: \(meeting.title)")
        callPanel.show(title: title, onRecord: { [weak self] in
            Log.event("calendar.reminder_accepted", "title=\(meeting.title)")
            Task { await self?.startRecording(event: meeting) }
        }, onDismiss: { [weak self] in
            Log.event("calendar.reminder_dismissed", "title=\(meeting.title)")
            self?.hidePanel()
        })
        shownReminder = meeting
        if e2e.acceptCallPrompt {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, !self.isRecording, self.shownReminder == meeting else { return }
                Log.event("calendar.reminder_accepted", "title=\(meeting.title) e2e=1")
                Task { await self.startRecording(event: meeting) }
            }
        }
    }

    // MARK: - Meetings

    func record(id: String?) -> MeetingRecord? {
        guard let id else { return nil }
        return meetings.first { $0.id == id }
    }

    func rename(_ record: MeetingRecord, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var fresh = store.load(folder: record.folder), fresh.meeting.title != title else { return }
        do {
            if [.recording, .processing].contains(fresh.meeting.status) {
                // Folder stays put while it is being written; renamed when done.
                fresh.meeting.title = title
                try store.save(fresh)
            } else {
                fresh = try store.rename(fresh, to: title)
            }
            replace(fresh)
        } catch {
            presentError(String(localized: "Не удалось переименовать: \(error.localizedDescription)"))
        }
    }

    func saveNotes(_ text: String, for id: String) {
        guard let record = record(id: id) else { return }
        try? store.write(text, MeetingFile.notes, of: record)
    }

    func retry(_ record: MeetingRecord) {
        processor.retry(record)
    }

    func regenerate(_ record: MeetingRecord, template: String) {
        processor.retry(record, template: template, regenerateSummary: true)
    }

    func cancelSummary() { processor.cancelSummary() }

    func reloadTemplates() { templates = Templates.all(in: store.templatesFolder) }

    func openFolder(_ record: MeetingRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.folder])
    }

    func copySummary(_ record: MeetingRecord) { copy(MeetingFile.summary, of: record) }

    func copyTranscript(_ record: MeetingRecord) { copy(MeetingFile.transcriptMarkdown, of: record) }

    private func copy(_ file: String, of record: MeetingRecord) {
        guard let text = store.read(file, of: record) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func handleUpdate(_ record: MeetingRecord) {
        var record = record
        // A title edited during recording/processing renames the folder once it is done.
        if ![.recording, .processing].contains(record.meeting.status),
           !MeetingStore.folder(record.folder, matches: record.meeting.title, date: record.meeting.startedAt),
           let renamed = try? store.rename(record, to: record.meeting.title) {
            record = renamed
        }
        replace(record)
    }

    private func replace(_ record: MeetingRecord) {
        if let i = meetings.firstIndex(where: { $0.id == record.id }) {
            meetings[i] = record
        } else {
            meetings.insert(record, at: 0)
        }
    }

    func presentError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    func quitCleanup() {
        stopRecording(reason: "quit")
    }

    // MARK: - Language

    /// Saves the interface language and offers to restart; a running recording is never cut.
    func setLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        AppLanguage.choose(new)
        language = new
        Log.event("app.language", "value=\(new.rawValue.isEmpty ? "system" : new.rawValue)")
        let alert = NSAlert()
        alert.messageText = String(localized: "Язык сменится после перезапуска Granula")
        if isRecording {
            alert.informativeText = String(localized: "Сейчас идёт запись — перезапустите Granula после неё.")
            alert.runModal()
            return
        }
        alert.addButton(withTitle: String(localized: "Перезапустить"))
        alert.addButton(withTitle: String(localized: "Позже"))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    private func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    // MARK: - E2E snapshots

    /// `--e2e-snapshot <folder>`: «Главная», the newest meeting (the same action as a click),
    /// «Главная» again — each saved as PNG of the main window. Needs no screen-recording permission.
    private func takeE2ESnapshots(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            snapshotWindow(to: folder.appendingPathComponent("1-home.png"))
            selection = meetings.max { $0.meeting.startedAt < $1.meeting.startedAt }?.id
            try? await Task.sleep(for: .seconds(2))
            snapshotWindow(to: folder.appendingPathComponent("2-meeting.png"))
            selection = nil
            try? await Task.sleep(for: .seconds(2))
            snapshotWindow(to: folder.appendingPathComponent("3-home.png"))
            Log.event("e2e.snapshots_done", "folder=\(folder.path)")
        }
    }

    private func snapshotWindow(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.event("e2e.snapshot_failed", "file=\(url.lastPathComponent)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        Log.event("e2e.snapshot", "file=\(url.lastPathComponent)")
    }
}

/// Test-only launch arguments for E2E scripts.
struct E2EOptions {
    let start: Bool
    let stopAfter: TimeInterval?
    let acceptCallPrompt: Bool
    let snapshotFolder: URL?
    var isActive: Bool { start || stopAfter != nil || acceptCallPrompt || snapshotFolder != nil }

    init(arguments: [String]) {
        start = arguments.contains("--e2e-start")
        acceptCallPrompt = arguments.contains("--e2e-accept-call-prompt")
        if let i = arguments.firstIndex(of: "--e2e-stop-after"), i + 1 < arguments.count {
            stopAfter = TimeInterval(arguments[i + 1])
        } else {
            stopAfter = nil
        }
        if let i = arguments.firstIndex(of: "--e2e-snapshot"), i + 1 < arguments.count {
            snapshotFolder = URL(fileURLWithPath: arguments[i + 1])
        } else {
            snapshotFolder = nil
        }
    }
}
