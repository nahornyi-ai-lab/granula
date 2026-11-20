import FluidAudio
import Foundation
import os.lock

/// The audio of one track since its last cut, on the recording's timeline.
/// Capture threads append; the session's loop reads and cuts.
public final class LiveTrack: @unchecked Sendable {
    static let rate = TrackWriter.sampleRate
    /// The loop fell this far behind (the model busy with a long recording): drop the oldest audio,
    /// down to `keepSeconds`, so the array is not moved on every buffer.
    static let maxSeconds: TimeInterval = 60
    static let keepSeconds: TimeInterval = 50

    struct Window {
        var samples: [Float]
        /// Timeline position of the first sample.
        var origin: TimeInterval
        /// Sound arrived since the previous window was taken.
        var heardSound: Bool
        /// Seconds of audio that arrived since the previous window was taken.
        var newSeconds: TimeInterval
        /// Seconds since audio last arrived (wall clock): the device may be gone.
        var idle: TimeInterval
        var duration: TimeInterval { Double(samples.count) / LiveTrack.rate }
    }

    private struct State {
        var samples: [Float] = []
        var origin: TimeInterval = 0
        var heardSound = false
        var newFrames = 0
        var lastAppend = Date()
        /// No one reads the track any more (no model, or the recording ended).
        var off = false
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init() {}

    /// Samples starting at `position` seconds of the timeline; a gap is filled with silence.
    public func append(_ samples: UnsafeBufferPointer<Float>, at position: TimeInterval) {
        guard !samples.isEmpty else { return }
        state.withLockUnchecked { s in
            guard !s.off else { return }
            var peak: Float = 0
            for x in samples { peak = max(peak, abs(x)) }
            if s.samples.isEmpty {
                s.origin = position
            } else {
                let end = s.origin + Double(s.samples.count) / Self.rate
                let gap = Int(((position - end) * Self.rate).rounded())
                if gap > 0 { s.samples += [Float](repeating: 0, count: min(gap, Int(Self.maxSeconds * Self.rate))) }
            }
            s.samples.append(contentsOf: samples)
            s.newFrames += samples.count
            s.lastAppend = Date()
            if peak >= TrackWriter.soundThreshold { s.heardSound = true }
            if s.samples.count > Int(Self.maxSeconds * Self.rate) {
                let drop = s.samples.count - Int(Self.keepSeconds * Self.rate)
                s.samples.removeFirst(drop)
                s.origin += Double(drop) / Self.rate
            }
        }
    }

    /// The audio since the last cut, when `use` accepts it — it decides from the
    /// counts alone (new seconds, sound heard, seconds idle). Only a window that is
    /// used starts the counts again, so audio skipped now still counts next time.
    func takeWindow(if use: (_ newSeconds: TimeInterval, _ heardSound: Bool, _ idle: TimeInterval) -> Bool) -> Window? {
        state.withLockUnchecked { s in
            let newSeconds = Double(s.newFrames) / Self.rate
            let idle = Date().timeIntervalSince(s.lastAppend)
            guard use(newSeconds, s.heardSound, idle) else { return nil }
            let window = Window(samples: s.samples, origin: s.origin, heardSound: s.heardSound,
                                newSeconds: newSeconds, idle: idle)
            s.heardSound = false
            s.newFrames = 0
            return window
        }
    }

    /// Stops collecting: nothing will read this track again.
    func stop() {
        state.withLockUnchecked { s in
            s.off = true
            s.samples = []
            s.newFrames = 0
        }
    }

    /// Forgets the audio before `time` (timeline seconds).
    func drop(before time: TimeInterval) {
        state.withLockUnchecked { s in
            let n = min(s.samples.count, max(0, Int(((time - s.origin) * Self.rate).rounded())))
            guard n > 0 else { return }
            s.samples.removeFirst(n)
            s.origin += Double(n) / Self.rate
        }
    }
}

/// The live transcript of one recording: both tracks are recognized every half
/// second with the same model as the final transcript, finished phrases become
/// lines (saved to `live.jsonl`), and lines are translated as they finish.
/// The final transcript is still built from the full recording after the meeting.
public actor LiveSession {
    public nonisolated let me = LiveTrack()
    public nonisolated let them = LiveTrack()

    public static let interval: Duration = .milliseconds(500)
    /// The phrase in progress is translated at most this often, once it has `partialWords`.
    static let partialEvery: TimeInterval = 1.5
    static let partialWords = 4
    /// A track is recognized again once this much new audio arrived.
    static let minNewAudio: TimeInterval = 0.25
    /// No audio from a track for this long (device gone, capture stalled): its phrase in progress ends.
    static let stalledAfter: TimeInterval = LiveSegmenter.pause + 0.5
    /// Lines translated into a newly chosen language, counting back from the last.
    static let retranslate = 10

    private let recognizer: SpeechRecognizing
    private let translator: LineTranslating?
    private let log: LiveLog?
    private let startedAt: Date
    private var languages: [String]
    private var target: String?

    private var status: LiveSnapshot.Status = .loadingModel
    private var lines: [LiveLine] = []
    private var partials: [Speaker: LivePartial] = [:]
    private var nextID = 0
    private var lastLanguage: [Speaker: String] = [:]
    private var missing: Set<String> = []
    private var missingCheckedAt = Date.distantPast

    private var queue: [Int] = []
    /// Older lines whose language pack arrived during the meeting: translated when
    /// nothing newer waits, so new lines and the phrase in progress come first.
    private var backlog: [Int] = []
    /// The line being translated right now.
    private var inFlight: Int?
    private var translating: Task<Void, Never>?
    private var partialTranslatedAt: [Speaker: Date] = [:]
    private var partialTranslatedText: [Speaker: String] = [:]
    private var finishing = false
    private var loop: Task<Void, Never>?
    private var onChange: (@Sendable (LiveSnapshot) -> Void)?
    private var lastEmitted: LiveSnapshot?
    private var recognitionErrors = 0
    /// How long recognition takes, for the log: count, total and worst seconds.
    private var decodes = 0
    private var decodeTotal: TimeInterval = 0
    private var decodeMax: TimeInterval = 0

    public init(folder: URL?, startedAt: Date, languages: [String], target: String?,
                recognizer: SpeechRecognizing, translator: LineTranslating?) {
        self.log = folder.map { LiveLog(url: $0.appendingPathComponent(MeetingFile.live)) }
        self.startedAt = startedAt
        self.languages = languages
        self.target = target
        self.recognizer = recognizer
        self.translator = translator
    }

    /// Audio for the live transcript (called on capture threads).
    public nonisolated func feed(_ speaker: Speaker, _ samples: UnsafeBufferPointer<Float>, at position: TimeInterval) {
        (speaker == .me ? me : them).append(samples, at: position)
    }

    public func setOnChange(_ handler: @escaping @Sendable (LiveSnapshot) -> Void) {
        onChange = handler
        emit(force: true)
    }

    /// Loads the model and starts recognizing every `interval`.
    /// `cycling: false` (tests) only loads; the caller runs `cycle()` itself.
    public func start(cycling: Bool = true) {
        guard loop == nil else { return }
        loop = Task(priority: .userInitiated) { [weak self] in
            guard let self, await self.loadModel(), cycling else { return }
            while !Task.isCancelled {
                await self.cycle()
                try? await Task.sleep(for: Self.interval)
            }
        }
        refreshMissing(force: true)
    }

    /// Recording stopped: the phrases in progress become lines, pending lines are translated.
    public func finish() async {
        guard !finishing else { return }
        finishing = true
        loop?.cancel()
        await loop?.value
        if status == .running {
            await cycle(flush: true)
        }
        partials = [:]
        // The transcript after the meeting is translated anyway; only lines still in the queue wait.
        backlog = []
        await translating?.value
        emit(force: true)
        onChange = nil
        me.stop()
        them.stop()
        log?.close()
        let shown = lines.filter { !$0.echo }
        let delays = shown.compactMap { line in line.finishedAt.map { $0 - line.end } }
        let mean = delays.isEmpty ? 0 : delays.reduce(0, +) / Double(delays.count)
        Log.event("live.finished", String(
            format: "lines=%d echoes=%d translated=%d mean_delay=%.2f decodes=%d decode_ms_mean=%.0f decode_ms_max=%.0f",
            shown.count, lines.count - shown.count, shown.filter { $0.translation != nil }.count, mean,
            decodes, decodes == 0 ? 0 : decodeTotal / Double(decodes) * 1000, decodeMax * 1000))
    }

    public func setTarget(_ newTarget: String?) {
        guard newTarget != target else { return }
        target = newTarget
        missing = []
        partialTranslatedText = [:]
        for key in partials.keys { partials[key]?.translation = nil }
        // A translation into another language is not shown as this one's, and the line
        // counts as not translated: choosing that language again translates it again.
        for i in lines.indices where lines[i].target != nil && lines[i].target != newTarget {
            let had = lines[i].translation != nil
            lines[i].target = nil
            lines[i].translation = nil
            lines[i].translatedAt = nil
            if had { log?.append(lines[i]) }
        }
        backlog = []
        if let newTarget, translator != nil {
            let recent = lines.indices.reversed().filter {
                !lines[$0].echo && (lines[$0].target != newTarget || lines[$0].translation == nil)
            }
            queue = recent.prefix(Self.retranslate).reversed().map { lines[$0].id }
        } else {
            queue = []
        }
        refreshMissing(force: true)
        pump()
        emit()
    }

    public func setLanguages(_ newLanguages: [String]) {
        update(target: target, languages: newLanguages)
    }

    /// From, To or the meeting languages changed: the languages first, then the target, so the
    /// lines translated again are told among the new languages. New languages re-translate the
    /// last lines: a line may now count as another language.
    public func update(target newTarget: String?, languages newLanguages: [String]) {
        let languagesChanged = newLanguages != languages
        if languagesChanged {
            languages = newLanguages
            lastLanguage = [:]
            partialTranslatedText = [:]
        }
        if newTarget != target {
            setTarget(newTarget)
            return
        }
        guard languagesChanged else { return }
        if target != nil, translator != nil {
            let recent = lines.indices.reversed().filter { !lines[$0].echo }.prefix(Self.retranslate).reversed()
            for id in recent.map({ lines[$0].id }) where !queue.contains(id) {
                backlog.removeAll { $0 == id }
                queue.append(id)
            }
        }
        refreshMissing(force: true)
        pump()
        emit()
    }

    public var currentLines: [LiveLine] { lines }

    /// Recognition passes so far: how many, mean and worst seconds.
    var decodeStats: (count: Int, mean: TimeInterval, max: TimeInterval) {
        (decodes, decodes == 0 ? 0 : decodeTotal / Double(decodes), decodeMax)
    }

    // MARK: - Recognition

    private func loadModel() async -> Bool {
        do {
            if try await recognizer.load() {
                status = .running
                // origin: the moment line times count from (epoch seconds), for E2E timing.
                Log.event("live.ready", "origin=\(startedAt.timeIntervalSince1970)")
                emit()
                return true
            }
            status = .noModel
            Log.event("live.no_model")
        } catch {
            status = .failed(String(describing: error))
            Log.error("live.model_failed", error)
        }
        me.stop()
        them.stop()
        emit()
        return false
    }

    /// One pass over both tracks. The far end goes first, so a "Me" phrase that is
    /// its echo already has the far end's words to be compared with.
    func cycle(flush: Bool = false) async {
        await recognize(.them, flush: flush)
        await recognize(.me, flush: flush)
        refreshMissing(force: false)
        pump()
        emit()
    }

    private func recognize(_ speaker: Speaker, flush: Bool) async {
        let track = speaker == .me ? me : them
        let hasPartial = partials[speaker] != nil
        var flush = flush
        var stalled = false
        guard let window = track.takeWindow(if: { newSeconds, _, idle in
            if flush || newSeconds >= Self.minNewAudio { return true }
            // No audio arrives (the device is gone): the phrase in progress ends where it is.
            stalled = hasPartial && idle >= Self.stalledAfter
            return stalled
        }) else { return }
        guard !window.samples.isEmpty else { return }
        if stalled { flush = true }
        if !flush && !hasPartial && !window.heardSound {
            // Silence: keep only the last second, where a word may be starting.
            if window.duration >= LiveSegmenter.minSilenceToTrim {
                track.drop(before: window.origin + window.duration - LiveSegmenter.keepSilence)
            }
            return
        }

        let words: [WordTiming]
        let began = Date()
        do {
            words = try await recognizer.words(in: window.samples)
            let took = Date().timeIntervalSince(began)
            decodes += 1
            decodeTotal += took
            decodeMax = max(decodeMax, took)
        } catch {
            recognitionErrors += 1
            if recognitionErrors <= 3 { Log.error("live.recognition_failed", error) }
            return
        }

        let cut = LiveSegmenter.cut(words, duration: window.duration, flush: flush)
        // The phrase in progress first: a finished far-end line is then compared with
        // the "Me" lines once, not again as the stale partial it just was.
        updatePartial(speaker, cut.partial, origin: window.origin)
        for run in cut.lines {
            let text = LiveSegmenter.text(of: run)
            guard !text.isEmpty, let first = run.first, let last = run.last else { continue }
            var line = LiveLine(id: nextID, speaker: speaker, start: window.origin + first.startTime,
                                end: window.origin + last.endTime, text: text)
            nextID += 1
            line.finishedAt = now
            add(line)
        }
        if let cutAt = cut.cutAt { track.drop(before: window.origin + cutAt) }
    }

    private func updatePartial(_ speaker: Speaker, _ words: [WordTiming], origin: TimeInterval) {
        let text = LiveSegmenter.text(of: words)
        if let first = words.first, let last = words.last, !text.isEmpty {
            let start = origin + first.startTime
            var partial = LivePartial(speaker: speaker, start: start, end: origin + last.endTime, text: text)
            // Keep showing the previous translation of this phrase until a new one is ready.
            if let previous = partials[speaker], abs(previous.start - start) < 0.5 {
                partial.translation = previous.translation
            } else {
                partialTranslatedText[speaker] = nil
            }
            if speaker == .me { partial.echo = isEcho(Segment(speaker: .me, start: partial.start, end: partial.end, text: text)) }
            partials[speaker] = partial
        } else {
            partials[speaker] = nil
            partialTranslatedText[speaker] = nil
        }
    }

    private func add(_ line: LiveLine) {
        var line = line
        if line.speaker == .me { line.echo = isEcho(line.segment) }
        // Lines stay in time order: the two tracks finish phrases at different moments.
        let index = lines.lastIndex { $0.start <= line.start }.map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
        log?.append(line)
        if line.speaker == .them { recheckEchoes(near: line) }
        guard !line.echo, let target, translator != nil else { return }
        // A line already in the target is shown as it is at once, not behind the lines being
        // translated (it would first show as waiting for a translation). Only when the speaker's
        // earlier lines are told: a short line takes the language of the one before it.
        if !waitsForLanguage(line.speaker),
           let language = LanguageDetector.detect(line.text, among: languages, previous: lastLanguage[line.speaker]),
           TranslationLanguages.same(language, target), let i = lines.firstIndex(where: { $0.id == line.id }) {
            lastLanguage[line.speaker] = language
            lines[i].language = language
            lines[i].target = target
            log?.append(lines[i])
            return
        }
        queue.append(line.id)
    }

    /// An earlier line of `speaker` still waits for its language to be told (queued or being translated).
    private func waitsForLanguage(_ speaker: Speaker) -> Bool {
        var ids = Set(queue).union(backlog)
        if let inFlight { ids.insert(inFlight) }
        return lines.contains { ids.contains($0.id) && $0.speaker == speaker }
    }

    // MARK: - Echo

    /// The "Me" text is the far end heard through the speakers (same rule as after the meeting).
    private func isEcho(_ segment: Segment) -> Bool {
        var near: [Segment] = []
        for line in lines.reversed() {
            if line.end < segment.start - 60 { break }
            if line.speaker == .them, overlaps(line.segment, segment) { near.append(line.segment) }
        }
        // Time order, as after the meeting: an echo spanning two far-end lines reads as one.
        near.reverse()
        if let partial = partials[.them] {
            let s = Segment(speaker: .them, start: partial.start, end: partial.end, text: partial.text)
            if overlaps(s, segment) { near.append(s) }
        }
        return EchoFilter.isEcho(segment, of: near)
    }

    private func overlaps(_ them: Segment, _ me: Segment) -> Bool {
        min(me.end, them.end + EchoFilter.pad) > max(me.start, them.start - EchoFilter.pad)
    }

    /// A far-end line that finished after the "Me" line it was heard in hides that line now.
    private func recheckEchoes(near them: LiveLine) {
        for i in lines.indices where lines[i].speaker == .me && !lines[i].echo {
            guard overlaps(them.segment, lines[i].segment), isEcho(lines[i].segment) else { continue }
            lines[i].echo = true
            queue.removeAll { $0 == lines[i].id }
            backlog.removeAll { $0 == lines[i].id }
            log?.append(lines[i])
        }
    }

    // MARK: - Translation

    /// Starts the translation worker if there is work and it is not running.
    private func pump() {
        guard translating == nil, translator != nil, target != nil else { return }
        guard !queue.isEmpty || !backlog.isEmpty || nextPartial() != nil else { return }
        translating = Task(priority: .userInitiated) { [weak self] in await self?.drain() }
    }

    /// Finished lines first, in order; the phrases in progress when nothing else waits.
    private func drain() async {
        while let translator, let target {
            if !queue.isEmpty {
                let id = queue.removeFirst()
                inFlight = id
                await translateLine(id, into: target, with: translator)
                inFlight = nil
            } else if !finishing, let speaker = nextPartial() {
                await translatePartial(speaker, into: target, with: translator)
            } else if !finishing, !backlog.isEmpty {
                let id = backlog.removeFirst()
                inFlight = id
                await translateLine(id, into: target, with: translator)
                inFlight = nil
            } else {
                break
            }
            emit()
        }
        translating = nil
    }

    private func translateLine(_ id: Int, into target: String, with translator: LineTranslating) async {
        guard let i = lines.firstIndex(where: { $0.id == id }), !lines[i].echo else { return }
        let text = lines[i].text, speaker = lines[i].speaker
        let language = LanguageDetector.detect(text, among: languages, previous: lastLanguage[speaker])
        if let language { lastLanguage[speaker] = language }
        var result = LineTranslation.failed
        if let language { result = await translator.translate(text, from: language, to: target) }
        // The line may have moved, turned out to be an echo, or the language changed meanwhile.
        guard self.target == target, let j = lines.firstIndex(where: { $0.id == id }) else { return }
        // No translation this time (same language, no pack, failed): an earlier one is not kept.
        if case .translated = result {} else {
            lines[j].translation = nil
            lines[j].translatedAt = nil
        }
        lines[j].language = language
        lines[j].target = target
        apply(result, from: language) { translation in
            lines[j].translation = translation
            lines[j].translatedAt = now
        }
        log?.append(lines[j])
    }

    private func nextPartial() -> Speaker? {
        let due = Date().addingTimeInterval(-Self.partialEvery)
        return [Speaker.them, .me].first { speaker in
            guard let partial = partials[speaker], !partial.echo,
                  partial.text.split(separator: " ").count >= Self.partialWords,
                  partialTranslatedText[speaker] != partial.text else { return false }
            return (partialTranslatedAt[speaker] ?? .distantPast) < due
        }
    }

    private func translatePartial(_ speaker: Speaker, into target: String, with translator: LineTranslating) async {
        guard let partial = partials[speaker] else { return }
        partialTranslatedAt[speaker] = Date()
        partialTranslatedText[speaker] = partial.text
        guard let language = LanguageDetector.detect(partial.text, among: languages, previous: lastLanguage[speaker])
        else { return }
        let result = await translator.translate(partial.text, from: language, to: target)
        // Only into the same phrase: it may have finished or been replaced meanwhile.
        guard self.target == target, let current = partials[speaker], abs(current.start - partial.start) < 0.5 else { return }
        apply(result, from: language) { partials[speaker]?.translation = $0 }
    }

    private func apply(_ result: LineTranslation, from language: String?, _ set: (String) -> Void) {
        switch result {
        case .translated(let text):
            set(text)
            if let language, missing.remove(language) != nil { requeue(cleared: [language]) }
        case .missingLanguage(let source):
            missing.insert(source)
        case .sameLanguage, .unsupported, .failed:
            break
        }
    }

    /// Which language packs the chosen languages still need; asked again every 10 s while some are missing.
    private func refreshMissing(force: Bool) {
        guard let translator, let target else { return }
        guard force || (!missing.isEmpty && Date().timeIntervalSince(missingCheckedAt) > 10) else { return }
        missingCheckedAt = Date()
        let sources = languages
        Task { [weak self] in
            let found = await translator.missingLanguages(sources, to: target)
            await self?.setMissing(found, target: target)
        }
    }

    private func setMissing(_ found: [String], target: String) {
        guard self.target == target else { return }
        let cleared = missing.subtracting(found)
        missing = Set(found)
        requeue(cleared: cleared)
        emit()
    }

    /// Language packs downloaded during the meeting: the lines that waited for them are translated now.
    private func requeue(cleared: Set<String>) {
        guard !cleared.isEmpty, let target, translator != nil else { return }
        let waiting = lines.filter { line in
            !line.echo && line.translation == nil && line.target == target
                && line.language.map(cleared.contains) == true
                && !queue.contains(line.id) && !backlog.contains(line.id) && line.id != inFlight
        }
        guard !waiting.isEmpty else { return }
        backlog.append(contentsOf: waiting.map(\.id))
        pump()
    }

    // MARK: - Snapshot

    private var now: TimeInterval { Date().timeIntervalSince(startedAt) }

    public var snapshot: LiveSnapshot {
        let translation: LiveSnapshot.TranslationState
        if target == nil {
            translation = .off
        } else if translator == nil {
            translation = .unavailableOS
        } else if !missing.isEmpty {
            translation = .missingLanguages(missing.sorted())
        } else {
            translation = .on
        }
        return LiveSnapshot(status: status, lines: lines, partials: [Speaker.them, .me].compactMap { partials[$0] },
                            target: target, translation: translation,
                            pending: Set(queue + backlog + (inFlight.map { [$0] } ?? [])))
    }

    private func emit(force: Bool = false) {
        let current = snapshot
        guard force || current != lastEmitted else { return }
        lastEmitted = current
        onChange?(current)
    }
}
