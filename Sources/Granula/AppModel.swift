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
    @Published private(set) var upcoming: [CalendarMeeting] = [] {
        didSet { refreshPrepared() }
    }
    /// Upcoming meetings that have something prepared (their `prepKey`).
    @Published private(set) var preparedKeys: Set<String> = []
    @Published private(set) var calendarAccess = CalendarWatcher.access
    @Published var remindersOn = UserDefaults.standard.object(forKey: AppModel.remindersKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(remindersOn, forKey: Self.remindersKey) }
    }
    static let remindersKey = "calendarReminders"
    @Published private(set) var language = AppLanguage.chosen
    /// The live transcript of the current recording.
    @Published private(set) var live: LiveSnapshot?
    @Published var liveSettings = LiveSettings.load() {
        didSet { liveSettingsChanged(from: oldValue) }
    }
    @Published var showTranslationSettings = false
    /// A language the Translation sheet also offers packs for (a transcript translated on request),
    /// from `translationSettingsSources`.
    @Published var translationSettingsTarget: String?
    @Published var translationSettingsSources: [String] = []
    /// Live hints: the owner's choices, the current recording's hints, whether a key is saved.
    @Published var hintSettings = HintSettings.load() {
        didSet { hintSettingsChanged(from: oldValue) }
    }
    @Published private(set) var hints: HintsSnapshot?
    @Published private(set) var hasHintKey = KeyFile.exists(name: HintSettings.keyName)
    @Published var showHintsSettings = false
    @Published private(set) var hintCheck: HintCheck?
    /// The current recording's own choices, kept in its meeting.json: hints (the lightbulb) and
    /// translation ("Don't translate" in the Live window turns it off for this meeting only).
    @Published private(set) var meetingHints = false
    @Published private(set) var meetingTranslates = true
    /// Which Check may still show its result.
    private var hintCheckRun = 0
    enum HintCheck: Equatable {
        case checking
        case done(judge: HintError?, answer: HintError?)
    }
    /// Opens the main window (set by the app, which has SwiftUI's openWindow); sheets live there.
    var openMainWindow: (() -> Void)?
    /// Meetings whose transcript is being translated on request.
    @Published private(set) var translatingTranscripts: Set<String> = []
    /// Bumped when a meeting's transcript files change outside processing (live log done, translation).
    @Published private(set) var transcriptRevision = 0

    let store = MeetingStore(root: UserDefaults.standard.string(forKey: AppModel.folderKey)
        .map { URL(fileURLWithPath: $0, isDirectory: true) })
    static let folderKey = "meetingsFolder"
    private(set) lazy var processor = MeetingProcessor(store: store)
    private let callDetector = CallDetector()
    private let callPanel = CallPromptPanel()
    private var recorder: Recorder?
    private var liveSession: LiveSession?
    private let liveWindow = LiveWindow()
    private var liveHints: LiveHints?
    /// Live snapshots to the hints, in order.
    private var hintFeed: AsyncStream<LiveSnapshot>.Continuation?
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
    /// The live translation's language: the default To, unless this meeting does not translate.
    var liveTarget: String? { isRecording && !meetingTranslates ? nil : liveSettings.target }
    /// Whether the Live window shows the hints column.
    var hintsShown: Bool { isRecording ? meetingHints : hintSettings.enabled }
    /// What the speech model listens for with this meeting's translation.
    private var liveLanguages: [String] {
        LiveSettings.detectionLanguages(source: liveSettings.source, target: liveTarget, languages: liveSettings.languages)
    }
    /// The owner's hint choices with this meeting's on or off.
    private var meetingHintSettings: HintSettings {
        var settings = hintSettings
        settings.enabled = meetingHints
        return settings
    }
    var recordingID: String? { recorder?.record.id }

    private init() {}

    func launch() {
        Log.event("app.launched", "e2e=\(e2e.isActive)")
        processor.onUpdate = { [weak self] in self?.handleUpdate($0) }
        loadFolder()

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
        // A fresh E2E build asks for the calendar first; the run below waits for it.
        var calendarReady: Task<Void, Never>?
        if e2e.isActive && CalendarWatcher.access == .notAsked {
            calendarReady = Task { await connectCalendar() }
        } else {
            calendar.start()
        }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReminder() }
        }

        if !e2e.isActive && !UserDefaults.standard.bool(forKey: "onboardingDone") {
            showOnboarding = true
        }
        // E2E runs set the whole pair (unset: Don't translate, Auto) and the meeting languages,
        // so the owner's own choices never leak into a test. The target first: From needs a To.
        if e2e.isActive {
            liveSettings.target = e2e.translate
            liveSettings.source = e2e.translateFrom
            if let languages = e2e.languages {
                liveSettings.languages = languages
                processor.meetingLanguages = languages
            }
            // Hints only in a hints E2E, with the default models and the run's own "About me".
            hintSettings = e2e.hintsOut == nil ? HintSettings(enabled: false) : HintSettings(aboutMe: e2e.hintsAbout ?? "")
        }
        if e2e.liveWindow { liveSettings.window = true }
        if e2e.start {
            Task {
                // The meeting going on now is linked (and prepared) only once the calendar is read.
                await calendarReady?.value
                if let file = e2e.prepare { prepareForE2E(file) }
                await startRecording()
            }
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
        // An open Prepare sheet saves its last typing before the prep is read below.
        NotificationCenter.default.post(name: .flushContextEdits, object: nil)
        do {
            let linked = event ?? CalendarRules.current(in: calendar.meetings, now: Date())
            if event == nil, let linked { Log.event("calendar.linked", "title=\(linked.title)") }
            let title = linked?.title ?? callApp.map { String(localized: "Call in \($0.name)") }
                ?? String(localized: "Meeting")
            var record = try store.create(title: title, callApp: callApp?.family)
            if let linked {
                record.meeting.calendarEventID = linked.eventID
                record.meeting.attendees = linked.attendees.isEmpty ? nil : linked.attendees
            }
            // What was prepared for this calendar meeting: its context and its two choices.
            let prepared = linked?.prepKey.flatMap { store.loadPrep(key: $0) }
            meetingHints = prepared?.prep.hints ?? hintSettings.enabled
            meetingTranslates = prepared?.prep.translate ?? true
            record.meeting.hints = meetingHints
            // The pair goes with the meeting: its transcript is translated the same way afterwards.
            let target = meetingTranslates ? liveSettings.target : nil
            record.meeting.translateTo = TranslationLanguages.isAvailable ? target : nil
            record.meeting.translateFrom = record.meeting.translateTo == nil ? nil : liveSettings.source
            try store.save(record)
            try store.write(prepared?.context ?? "", MeetingFile.context, of: record)
            if let prepared {
                Log.event("prep.used", "folder=\(store.prepFolder(key: prepared.prep.key).lastPathComponent) "
                    + "chars=\(prepared.context.count) hints=\(meetingHints) translate=\(meetingTranslates)")
            }
            let session = LiveSession(
                folder: record.folder, startedAt: record.meeting.startedAt,
                languages: LiveSettings.detectionLanguages(source: liveSettings.source, target: target,
                                                           languages: liveSettings.languages),
                target: target, recognizer: Transcriber.shared, translator: Translators.make(.live))
            let recorder = try Recorder(record: record, live: session)
            self.recorder = recorder
            liveSession = session
            live = LiveSnapshot()
            startHints(for: record)
            recordingFromCalendar = event != nil
            // Auto-stop only follows a call that is still on the microphone.
            recordingCallFamily = callApp.flatMap { callDetector.activeNow.contains($0.family) ? $0.family : nil }
            if event != nil, recordingCallFamily == nil, let family = callDetector.activeNow.sorted().first {
                adoptCall(family)
            }
            meetings.insert(record, at: 0)
            selection = record.id
            // Weak: the session keeps this closure, and it must not keep the session after the meeting.
            await session.setOnChange { [weak session] snapshot in
                guard let session else { return }
                Task { @MainActor in AppModel.shared.liveChanged(snapshot, from: session) }
            }
            // Each await below may let a Stop in (hot key, sleep, quit): stopRecording has then
            // saved and queued the meeting, and nothing more is set up.
            guard self.recorder === recorder else { return }
            await recorder.start()
            guard self.recorder === recorder else { return }
            await session.start()
            guard self.recorder === recorder else { return }
            if liveSettings.window { showLiveWindow() }
            if let folder = e2e.liveSnapshotFolder { takeLiveSnapshots(to: folder, while: recorder) }
            snapshot = recorder.snapshot
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            if let seconds = e2e.stopAfter { stopForE2E(after: seconds, recorder: recorder) }
        } catch {
            Log.error("recording.start_failed", error)
            presentError(String(localized: "Couldn't start recording: \(error.localizedDescription)"))
        }
    }

    /// E2E auto-stop. It counts from the moment the speech model is loaded (or failed to),
    /// so a slow first load does not cut off the audio a test plays after `live.ready`.
    private func stopForE2E(after seconds: TimeInterval, recorder: Recorder) {
        Task { [weak self] in
            for _ in 0..<900 {
                guard let self, self.recorder === recorder else { return }
                if let status = self.live?.status, status != .loadingModel { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.recorder === recorder else { return }
            self.stopRecording(reason: "e2e")
        }
    }

    func stopRecording(reason: String) {
        guard let recorder else { return }
        ticker?.invalidate()
        ticker = nil
        let peaks = recorder.stop()
        self.recorder = nil
        finishLive(folder: recorder.record.folder)
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

    // MARK: - Live transcript

    private func liveChanged(_ snapshot: LiveSnapshot, from session: LiveSession) {
        guard liveSession === session else { return }
        live = snapshot
        hintFeed?.yield(snapshot)
    }

    /// The phrases in progress become lines and the log is closed after the recording.
    private func finishLive(folder: URL) {
        liveWindow.hide()
        live = nil
        stopHints()
        guard let session = liveSession else { return }
        liveSession = nil
        Task {
            await session.finish()
            transcriptRevision += 1
        }
    }

    private func liveSettingsChanged(from old: LiveSettings) {
        // From equal to To is Auto: there is nothing to translate from the target language.
        // (Set inside its own didSet, it does not call this again; the code below sees it.)
        if let source = liveSettings.source, let target = liveSettings.target, TranslationLanguages.same(source, target) {
            liveSettings.source = nil
        }
        // E2E runs set their own choices; the owner's stay as they were.
        if !e2e.isActive { liveSettings.save() }
        guard isRecording else { return }
        if liveSettings.window != old.window {
            if liveSettings.window { showLiveWindow() } else { liveWindow.hide() }
        }
        // A new default To (Translation… or the Live window) applies to this meeting too,
        // "Don't translate" included.
        let was = meetingTranslates ? old.target : nil
        if liveSettings.target != old.target { meetingTranslates = liveSettings.target != nil }
        applyLiveTranslation(
            from: was, source: old.source,
            languages: LiveSettings.detectionLanguages(source: old.source, target: was, languages: old.languages))
    }

    /// The Live window's To: "Don't translate" turns translation off for this meeting only;
    /// a language turns it on and becomes the default, as in Translation….
    func setLiveTarget(_ code: String?) {
        guard isRecording else { liveSettings.target = code; return }
        if let code, liveSettings.target != code {
            liveSettings.target = code  // liveSettingsChanged turns this meeting's translation on
            return
        }
        let on = code != nil
        guard on != meetingTranslates else { return }
        let was = liveTarget, languages = liveLanguages
        meetingTranslates = on
        applyLiveTranslation(from: was, source: liveSettings.source, languages: languages)
    }

    /// Sends this meeting's translation to the live session and to its meeting.json when it changed.
    private func applyLiveTranslation(from oldTarget: String?, source oldSource: String?, languages oldLanguages: [String]) {
        let target = liveTarget
        let languages = liveLanguages
        if target != oldTarget || languages != oldLanguages {
            Log.event("live.languages", "from=\(liveSettings.source ?? "auto") to=\(target ?? "off") detect=\(languages.joined(separator: ","))")
            // One task: the languages and the target reach the session together.
            let session = liveSession
            Task { await session?.update(target: target, languages: languages) }
        }
        if target != oldTarget || liveSettings.source != oldSource,
           let folder = recorder?.record.folder, var current = store.load(folder: folder) {
            // From is off without a To: a greyed-out From must not decide the transcript's translation.
            current.meeting.translateTo = TranslationLanguages.isAvailable ? target : nil
            current.meeting.translateFrom = current.meeting.translateTo == nil ? nil : liveSettings.source
            try? store.save(current)
        }
    }

    private func showLiveWindow() {
        liveWindow.show(model: self, hints: hintsShown) { [weak self] in self?.liveSettings.window = false }
    }

    // MARK: - Live hints

    /// The hints of a recording that starts now; fed with every live snapshot.
    private func startHints(for record: MeetingRecord) {
        let id = record.id
        let hints = LiveHints(settings: meetingHintSettings, startedAt: record.meeting.startedAt,
                              key: { KeyFile.read(name: HintSettings.keyName) },
                              context: { await AppModel.shared.hintContext(for: id) },
                              translator: Translators.make(.live))
        // Each snapshot holds every line so far: the newest is enough, and order is kept.
        let (stream, feed) = AsyncStream<LiveSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        liveHints = hints
        hintFeed = feed
        self.hints = HintsSnapshot()
        // Weak: the hints keep this closure, and it must not keep them after the meeting.
        let onChange: @Sendable (HintsSnapshot) -> Void = { [weak hints] snapshot in
            guard let hints else { return }
            Task { @MainActor in AppModel.shared.hintsChanged(snapshot, from: hints) }
        }
        Task {
            await hints.setOnChange(onChange)
            for await snapshot in stream { await hints.update(snapshot) }
        }
    }

    private func hintsChanged(_ snapshot: HintsSnapshot, from hints: LiveHints) {
        guard liveHints === hints else { return }
        self.hints = snapshot
        if let url = e2e.hintsOut { writeHintsForE2E(snapshot, to: url) }
    }

    /// Requests stop with the recording; its hints are not kept.
    private func stopHints() {
        hintFeed?.finish()
        hintFeed = nil
        hints = nil
        guard let liveHints else { return }
        self.liveHints = nil
        Task { await liveHints.cancelAll() }
    }

    /// The meeting's title, attendees, notes and context as they are now (it may have been renamed).
    func hintContext(for id: String) -> HintContext {
        guard let record = meetings.first(where: { $0.id == id }) else { return HintContext() }
        let current = store.load(folder: record.folder) ?? record
        return HintContext(title: current.meeting.title, attendees: current.meeting.attendees ?? [],
                           notes: store.read(MeetingFile.notes, of: current) ?? "",
                           context: store.read(MeetingFile.context, of: current) ?? "")
    }

    /// The lightbulb: hints on or off for the current meeting only.
    func setMeetingHints(_ on: Bool) {
        guard isRecording else { hintSettings.enabled = on; return }
        guard on != meetingHints else { return }
        meetingHints = on
        Log.event("hints.meeting", "on=\(on)")
        if let folder = recorder?.record.folder, var current = store.load(folder: folder) {
            current.meeting.hints = on
            try? store.save(current)
        }
        let settings = meetingHintSettings
        if let liveHints { Task { await liveHints.update(settings: settings) } }
        liveWindow.setHints(on)
    }

    private func hintSettingsChanged(from old: HintSettings) {
        // E2E runs set their own choices; the owner's stay as they were.
        if !e2e.isActive { hintSettings.save() }
        guard hintSettings != old else { return }
        // "Turn on hints for new meetings" leaves the current one as it is.
        let settings = meetingHintSettings
        if let liveHints { Task { await liveHints.update(settings: settings) } }
        if settings.judge != old.judge || settings.answer != old.answer { resetHintCheck() }
    }

    /// A Check still running for the old models or key will not show its result.
    private func resetHintCheck() {
        hintCheckRun += 1
        hintCheck = nil
    }

    /// Hints…, on the main window, which may be closed or behind the call.
    func presentHintsSettings() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        showHintsSettings = true
    }

    /// Saves the OpenRouter key in Granula's key file; false when it could not be written.
    @discardableResult
    func saveHintKey(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, KeyFile.save(key, name: HintSettings.keyName) else { return false }
        hasHintKey = true
        resetHintCheck()
        if let liveHints { Task { await liveHints.keyChanged() } }
        Log.event("hints.key_saved")
        return true
    }

    func removeHintKey() {
        KeyFile.delete(name: HintSettings.keyName)
        hasHintKey = KeyFile.exists(name: HintSettings.keyName)
        resetHintCheck()
        if let liveHints { Task { await liveHints.keyChanged() } }
        Log.event("hints.key_removed")
    }

    /// Hints… → Check: a tiny request to each of the two models.
    func checkHints() {
        guard hintCheck != .checking else { return }
        let key: String
        switch KeyFile.read(name: HintSettings.keyName) {
        case .found(let value):
            key = value
        case .missing:
            hasHintKey = false
            return
        case .refused:
            hintCheck = .done(judge: .keyUnavailable, answer: .keyUnavailable)
            return
        }
        resetHintCheck()
        hintCheck = .checking
        let run = hintCheckRun
        let settings = hintSettings
        Task {
            let result = await LiveHints.check(settings: settings, key: key)
            Log.event("hints.check", "judge=\(result.judge?.tag ?? "ok") answer=\(result.answer?.tag ?? "ok")")
            // The models or the key changed meanwhile: this result is about something else.
            guard run == hintCheckRun, hintCheck == .checking else { return }
            hintCheck = .done(judge: result.judge, answer: result.answer)
        }
    }

    /// `--e2e-hints-out <file>`: the hints as JSON, rewritten on every change.
    private func writeHintsForE2E(_ snapshot: HintsSnapshot, to url: URL) {
        let hints: [[String: Any]] = snapshot.hints.map { hint in
            var state = "writing"
            var error: Any = NSNull()
            switch hint.state {
            case .writing: break
            case .done: state = "done"
            case .failed(let why):
                state = "failed"
                error = why.tag
            }
            return ["id": hint.id, "said": hint.said, "start": hint.start, "text": hint.text,
                    "translation": hint.translation.map { $0 as Any } ?? NSNull(), "state": state, "error": error]
        }
        let object: [String: Any] = ["judgeError": snapshot.judgeError.map { $0.tag as Any } ?? NSNull(), "hints": hints]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Translation

    /// Translates a finished meeting's transcript into `target` (the Transcript tab's "Translate").
    func translateTranscript(_ record: MeetingRecord, to target: String) {
        guard !translatingTranscripts.contains(record.id),
              let transcript = Transcript.load(from: record.url(MeetingFile.transcriptJSON)),
              let translator = Translators.make(.best) else { return }
        translatingTranscripts.insert(record.id)
        // The meeting's From → To: a meeting set to English → Russian tells its lines between the
        // two, and the new target too when it is a third language.
        let languages = LiveSettings.transcriptLanguages(
            meetingFrom: record.meeting.translateFrom, meetingTo: record.meeting.translateTo, target: target,
            languages: liveSettings.languages)
        Task {
            let outcome = await TranscriptTranslation.build(transcript, to: target, languages: languages, translator: translator)
            translatingTranscripts.remove(record.id)
            guard let translation = outcome.translation else {
                presentMissingLanguages(outcome.missing, target: target)
                return
            }
            // The meeting may have been renamed (its folder moved) while this ran.
            let latest = meetings.first { $0.id == record.id } ?? record
            let current = store.load(folder: latest.folder) ?? latest
            do {
                try translation.jsonData().write(to: current.url(MeetingFile.translationJSON), options: .atomic)
                try store.write(translation.markdown(for: transcript), MeetingFile.translationMarkdown, of: current)
            } catch {
                presentError(String(localized: "Couldn't save the translation: \(error.localizedDescription)"))
                return
            }
            // translateTo/translateFrom stay the pair the meeting was recorded with (translation.json
            // has this translation's own target), so a later translation still knows the pair.
            replace(current)
            transcriptRevision += 1
            if !outcome.missing.isEmpty { presentMissingLanguages(outcome.missing, target: target) }
        }
    }

    private func presentMissingLanguages(_ missing: [String], target: String) {
        guard !missing.isEmpty else {
            presentError(String(localized: "Couldn't translate the transcript."))
            return
        }
        let alert = NSAlert()
        let pairs = missing.map { "\(TranslationLanguages.name($0)) → \(TranslationLanguages.name(target))" }
        alert.messageText = String(localized: "Download the languages to translate")
        alert.informativeText = String(localized: "Not downloaded yet: \(pairs.joined(separator: ", ")).")
        alert.addButton(withTitle: String(localized: "Download…"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            presentTranslationSettings(target: target, sources: missing)
        }
    }

    /// Translation…, also with the packs a transcript's translation is missing (`target`, `sources`).
    /// The sheet lives on the main window, which may be closed or behind the call.
    func presentTranslationSettings(target: String? = nil, sources: [String] = []) {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        translationSettingsTarget = target
        translationSettingsSources = sources
        showTranslationSettings = true
    }

    func translationSettingsDismissed() {
        translationSettingsTarget = nil
        translationSettingsSources = []
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
        let title = lead > 0 ? String(localized: "In \(minutes) min: \(meeting.title)")
            : String(localized: "Now: \(meeting.title)")
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
            presentError(String(localized: "Couldn't rename: \(error.localizedDescription)"))
        }
    }

    func saveNotes(_ text: String, for id: String) {
        guard let record = record(id: id) else { return }
        try? store.write(text, MeetingFile.notes, of: record)
    }

    /// The Context block of the meeting screen.
    func saveContext(_ text: String, for id: String) {
        guard let record = record(id: id) else { return }
        try? store.write(text, MeetingFile.context, of: record)
    }

    // MARK: - Meeting prep

    /// What is prepared for an upcoming meeting: its context and its two choices (nil: the default).
    func prep(for meeting: CalendarMeeting) -> (context: String, hints: Bool?, translate: Bool?) {
        guard let key = meeting.prepKey, let saved = store.loadPrep(key: key) else { return ("", nil, nil) }
        return (saved.context, saved.prep.hints, saved.prep.translate)
    }

    /// Saves the prep of an upcoming meeting: the Prepare sheet as it is typed, and the prep E2E.
    /// False when it could not be saved.
    @discardableResult
    func savePrep(for meeting: CalendarMeeting, context: String, hints: Bool?, translate: Bool?) -> Bool {
        guard let key = meeting.prepKey else { return false }
        let prep = MeetingPrep(key: key, title: meeting.title, start: meeting.start, hints: hints, translate: translate)
        do {
            try store.savePrep(prep, context: context)
        } catch {
            Log.error("prep.save_failed", error)
            return false
        }
        Log.event("prep.saved", "folder=\(store.prepFolder(key: key).lastPathComponent) chars=\(context.count) "
            + "hints=\(hints.map { String($0) } ?? "default") translate=\(translate.map { String($0) } ?? "default")")
        refreshPrepared()
        return true
    }

    /// Which upcoming meetings show a filled Prepare icon.
    private func refreshPrepared() {
        preparedKeys = Set(upcoming.compactMap { meeting -> String? in
            guard let key = meeting.prepKey, let saved = store.loadPrep(key: key) else { return nil }
            let empty = saved.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && saved.prep.hints == nil && saved.prep.translate == nil
            return empty ? nil : key
        })
    }

    /// E2E: what the Prepare sheet saves, for the calendar meeting going on now, from a text file.
    /// Only the test event ("E2E prep"): a real meeting's prep is never touched.
    private func prepareForE2E(_ file: URL) {
        guard let meeting = CalendarRules.current(in: calendar.meetings, now: Date()), meeting.title == "E2E prep",
              let text = ContextImport.text(from: file),
              savePrep(for: meeting, context: text, hints: nil, translate: e2e.prepareTranslate) else {
            Log.event("e2e.prepare_failed", "file=\(file.lastPathComponent)")
            return
        }
    }

    func retry(_ record: MeetingRecord) {
        processor.retry(record)
    }

    func regenerate(_ record: MeetingRecord, template: String) {
        processor.retry(record, template: template, regenerateSummary: true)
    }

    func cancelSummary() { processor.cancelSummary() }

    func reloadTemplates() { templates = Templates.all(in: store.templatesFolder) }

    /// Templates and meetings of the meetings folder; finishes what was left there unprocessed.
    private func loadFolder() {
        Templates.installDefaults(in: store.templatesFolder)
        templates = Templates.all(in: store.templatesFolder)
        meetings = store.loadAll()
        processor.recover()
        meetings = store.loadAll()
        refreshPrepared()
    }

    /// "Meetings folder…": new meetings go to the chosen folder; old ones stay in the old one.
    func chooseFolder() {
        guard !isRecording, !meetings.contains(where: { $0.meeting.status == .processing }) else {
            presentError(String(localized: "You can change the folder once recording and processing are finished."))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.root
        panel.message = String(localized: "Meetings are now saved to \(store.root.path)")
        panel.prompt = String(localized: "Choose")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL != store.root.standardizedFileURL else { return }
        let oldTemplates = store.templatesFolder
        let oldRoot = store.root
        do {
            try store.use(root: url)
        } catch {
            presentError(String(localized: "Couldn't use this folder: \(error.localizedDescription)"))
            return
        }
        if !FileManager.default.fileExists(atPath: store.templatesFolder.path) {
            try? FileManager.default.copyItem(at: oldTemplates, to: store.templatesFolder)
        }
        store.copyPreps(from: oldRoot)
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        Log.event("storage.folder_changed", "path=\(url.path)")
        selection = nil
        loadFolder()
    }

    func openFolder(_ record: MeetingRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.folder])
    }

    func copySummary(_ record: MeetingRecord) { copy(MeetingFile.summary, of: record) }

    func copyTranscript(_ record: MeetingRecord) { copy(MeetingFile.transcriptMarkdown, of: record) }

    func copyTranslation(_ record: MeetingRecord) { copy(MeetingFile.translationMarkdown, of: record) }

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
        alert.messageText = String(localized: "The language changes after Granula restarts")
        if isRecording {
            alert.informativeText = String(localized: "A recording is in progress — restart Granula after it.")
            alert.runModal()
            return
        }
        alert.addButton(withTitle: String(localized: "Restart"))
        alert.addButton(withTitle: String(localized: "Later"))
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

    /// `--e2e-snapshot <folder>`: Home, the newest meeting (the same action as a click),
    /// Home again — each saved as PNG of the main window. Needs no screen-recording permission.
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

    /// `--e2e-live-snapshots <folder>`: the meeting window and the Live window
    /// every 5 s while recording, to see the live transcript as the owner does.
    private func takeLiveSnapshots(to folder: URL, while recorder: Recorder) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            var n = 1
            while self.recorder === recorder {
                try? await Task.sleep(for: .seconds(5))
                guard self.recorder === recorder else { break }
                snapshotWindow(to: folder.appendingPathComponent("live-\(n).png"))
                if liveWindow.snapshot(to: folder.appendingPathComponent("window-\(n).png")) {
                    Log.event("e2e.snapshot", "file=window-\(n).png")
                }
                n += 1
            }
        }
    }

    /// The main window: titled and not a panel (the Live window, the call prompt).
    private func snapshotWindow(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }),
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
    /// Live transcript checks: translate from → into these languages, show the Live window,
    /// snapshot while recording.
    let translate: String?
    let translateFrom: String?
    /// `--e2e-languages ru,en,uk,es`: the meeting languages (Auto tells a line's language among them).
    let languages: [String]?
    let liveWindow: Bool
    let liveSnapshotFolder: URL?
    /// `--e2e-hints-out <file>`: hints on for the run (default models), written as JSON on every
    /// change; `--e2e-hints-about <text>`: the run's "About me". Without them hints are off in E2E.
    let hintsOut: URL?
    let hintsAbout: String?
    /// `--e2e-prepare <text file>`: before `--e2e-start`, the file's text is saved as the prep of the
    /// calendar meeting going on now; `--e2e-prepare-translate on|off`: its translation choice.
    let prepare: URL?
    let prepareTranslate: Bool?
    var isActive: Bool {
        start || stopAfter != nil || acceptCallPrompt || snapshotFolder != nil
            || translate != nil || translateFrom != nil || languages != nil || liveWindow || liveSnapshotFolder != nil
            || hintsOut != nil || prepare != nil
    }

    init(arguments: [String]) {
        // Only local builds (scripts/build-app.sh without --release) define GRANULA_E2E;
        // a release build ignores every flag, so nothing can start a recording from the command line.
        #if !GRANULA_E2E
        let arguments: [String] = []
        #endif
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        translate = value("--e2e-translate")
        translateFrom = value("--e2e-translate-from")
        languages = value("--e2e-languages").map { list in
            TranslationLanguages.spoken.filter(list.split(separator: ",").map(String.init).contains)
        }.flatMap { $0.isEmpty ? nil : $0 }
        liveWindow = arguments.contains("--e2e-live-window")
        liveSnapshotFolder = value("--e2e-live-snapshots").map { URL(fileURLWithPath: $0) }
        hintsOut = value("--e2e-hints-out").map { URL(fileURLWithPath: $0) }
        hintsAbout = value("--e2e-hints-about")
        prepare = value("--e2e-prepare").map { URL(fileURLWithPath: $0) }
        prepareTranslate = value("--e2e-prepare-translate").map { $0 == "on" }
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
