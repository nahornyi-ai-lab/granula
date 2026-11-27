import FluidAudio
import Foundation
import Testing
@testable import GranulaCore

// Live transcript: phrases cut at pauses, echoes hidden, lines translated and
// saved as they finish. The speech model is replaced by a fake that "hears" a
// word in each burst of sound, so the timing logic is tested exactly.

private func word(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
    WordTiming(word: text, startTime: start, endTime: end)
}

// MARK: - Segmenter

@Suite struct LiveSegmenterTests {
    @Test func phraseFollowedByPauseIsFinished() {
        let words = [word("a", 0, 0.4), word("b", 0.5, 0.9), word("c", 2.0, 2.4)]
        let cut = LiveSegmenter.cut(words, duration: 2.6)
        #expect(cut.lines.map { $0.map(\.word) } == [["a", "b"]])
        #expect(cut.partial.map(\.word) == ["c"])
        #expect(cut.cutAt == (0.9 + 2.0) / 2)
    }

    /// Real token timings of "Okay, got it." followed by silence (window 0–6.29 s): the decoder put
    /// the period at the window's end. Without moving it the line never finished in the silence.
    @Test func shortPhraseEndingInAPeriodFinishesInTheSilenceAfterIt() {
        let tokens = [(" Okay", 2.48, 2.80), (",", 3.20, 3.44), (" got", 3.44, 3.76), (" it", 3.76, 4.08),
                      (".", 6.16, 6.24)].enumerated().map { i, t in
            TokenTiming(token: t.0, tokenId: i, startTime: t.1, endTime: t.2, confidence: 1)
        }
        let words = buildWordTimings(from: Transcriber.untimedClosingPunctuation(tokens))
        let cut = LiveSegmenter.cut(words, duration: 6.29)
        #expect(cut.lines.map(LiveSegmenter.text) == ["Okay, got it."])
        #expect(cut.lines.first?.last?.endTime == 4.08)
        #expect(cut.partial.isEmpty)
    }

    @Test func trailingSilenceFinishesThePhrase() {
        let words = [word("a", 0, 0.4), word("b", 0.5, 0.9)]
        let cut = LiveSegmenter.cut(words, duration: 2.0)
        #expect(cut.lines.map { $0.map(\.word) } == [["a", "b"]])
        #expect(cut.partial.isEmpty)
        #expect(cut.cutAt == 0.9 + 1.1 / 2)
    }

    @Test func phraseStillBeingSpokenStaysPartial() {
        let words = [word("a", 0, 0.4), word("b", 0.5, 0.9)]
        let cut = LiveSegmenter.cut(words, duration: 1.3)
        #expect(cut.lines.isEmpty)
        #expect(cut.cutAt == nil)
        #expect(cut.partial.map(\.word) == ["a", "b"])
    }

    @Test func longPhraseIsCutAtItsWidestSettledGap() {
        // 11.6 s of speech without a pause: 0.4 s words 0.1 s apart, a 0.5 s gap
        // after 5.9 s, and a wider one too close to the end to be trusted.
        let starts = stride(from: 0.0, through: 5.5, by: 0.5).map { $0 }
            + stride(from: 6.4, through: 9.9, by: 0.5).map { $0 } + [11.0]
        let words = starts.enumerated().map { word("w\($0.offset)", $0.element, $0.element + 0.4) }
        let cut = LiveSegmenter.cut(words, duration: 11.6)
        #expect(cut.lines.count == 1)
        let finished = try! #require(cut.lines.first)
        #expect(abs(finished.last!.endTime - 5.9) < 0.01)
        #expect(cut.partial.first.map { abs($0.startTime - 6.4) < 0.01 } == true)
        #expect(cut.cutAt.map { abs($0 - 6.15) < 0.01 } == true)
    }

    @Test func silenceIsTrimmedButKeepsTheLastSecond() {
        #expect(LiveSegmenter.cut([], duration: 4).cutAt == 3)
        #expect(LiveSegmenter.cut([], duration: 2).cutAt == nil)
    }

    @Test func flushFinishesEverything() {
        let words = [word("a", 0, 0.4), word("b", 0.5, 0.9)]
        let cut = LiveSegmenter.cut(words, duration: 1.0, flush: true)
        #expect(cut.lines.map { $0.map(\.word) } == [["a", "b"]])
        #expect(cut.cutAt == 1.0)
        #expect(cut.partial.isEmpty)
    }

    @Test func unknownTokensAreCleanedLikeTheFinalTranscript() {
        #expect(LiveSegmenter.text(of: [word("вс<unk>", 0, 0.3), word("хорошо", 0.4, 0.8)]) == "вс хорошо")
        #expect(LiveSegmenter.text(of: [word("вс<unk>м", 0, 0.3)]) == "всём")  // not localized: letters
    }
}

// MARK: - Language

@Suite struct LanguageDetectorTests {
    let languages = ["ru", "uk", "en"]

    @Test func clearSentencesAreRecognized() {
        #expect(LanguageDetector.detect("Давайте обсудим бюджет на следующий квартал", among: languages, previous: nil) == "ru")  // not localized: test speech
        #expect(LanguageDetector.detect("Ми готові підписати договір наступного тижня", among: languages, previous: nil) == "uk")  // not localized: test speech
        #expect(LanguageDetector.detect("Let's move the launch to next Tuesday", among: languages, previous: nil) == "en")
    }

    @Test func shortLineKeepsTheSpeakersLanguage() {
        #expect(LanguageDetector.detect("так", among: languages, previous: "uk") == "uk")  // not localized: test speech
        #expect(LanguageDetector.detect("так", among: languages, previous: "ru") == "ru")  // not localized: test speech
        #expect(LanguageDetector.detect("123", among: languages, previous: "uk") == "uk")
        // Written in another alphabet: not the speaker's language.
        #expect(LanguageDetector.detect("okay", among: languages, previous: "ru") == "en")
    }

    @Test func oneMeetingLanguageNeedsNoGuess() {
        #expect(LanguageDetector.detect("anything at all", among: ["ru"], previous: nil) == "ru")
    }
}

// MARK: - Log

@Suite struct LiveLogTests {
    @Test func lastVersionOfEachLineWinsAndBrokenRowsAreSkipped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("granula-live-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = LiveLog(url: url)
        var first = LiveLine(id: 0, speaker: .them, start: 1, end: 2, text: "hello")
        let second = LiveLine(id: 1, speaker: .me, start: 0.5, end: 0.9, text: "hi")
        log.append(first)
        log.append(second)
        first.translation = "привет"  // not localized: test data
        log.append(first)
        log.close()
        // A row cut by a crash mid-write.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":2,"speak"#.utf8))
        try handle.close()

        let lines = try #require(LiveLog.load(from: url))
        #expect(lines.map(\.id) == [1, 0])
        #expect(lines[1].translation == "привет")  // not localized: test data
    }
}

// MARK: - Session

/// "Hears" one word per burst of sound: the burst's loudness picks the word.
private struct FakeRecognizer: SpeechRecognizing {
    static let vocabulary = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india"]

    func load() async throws -> Bool { true }

    func words(in samples: [Float]) async throws -> [WordTiming] {
        var words: [WordTiming] = []
        var start: Int?
        var sum: Float = 0
        func close(_ end: Int) {
            guard let s = start else { return }
            let level = sum / Float(end - s)
            let index = max(0, min(Self.vocabulary.count - 1, Int((level * 10).rounded()) - 1))
            words.append(WordTiming(word: Self.vocabulary[index], startTime: Double(s) / 16_000, endTime: Double(end) / 16_000))
            start = nil
            sum = 0
        }
        for (i, x) in samples.enumerated() {
            if abs(x) >= 0.05 {
                if start == nil { start = i }
                sum += abs(x)
            } else {
                close(i)
            }
        }
        // A burst touching the window's end is a word still being spoken: heard, unfinished.
        close(samples.count)
        return words
    }
}

private actor FakeTranslator: LineTranslating {
    var missing: Set<String> = []
    private(set) var calls = 0

    init(missing: Set<String> = []) { self.missing = missing }

    /// The owner downloaded the pack for `language`.
    func install(_ language: String) { missing.remove(language) }

    func translate(_ text: String, from source: String, to target: String) async -> LineTranslation {
        calls += 1
        if source == target { return .sameLanguage }
        if missing.contains(source) { return .missingLanguage(source) }
        return .translated("\(target):\(text.uppercased())")
    }

    func missingLanguages(_ sources: [String], to target: String) async -> [String] {
        sources.filter { missing.contains($0) && $0 != target }
    }
}

/// Builds a track: words as bursts (0.4 s each, 0.2 s apart), then silence.
private struct Audio {
    var samples: [Float] = []

    mutating func say(_ words: [String], gain: Float = 1) {
        for (i, w) in words.enumerated() {
            let level = Float(FakeRecognizer.vocabulary.firstIndex(of: w)! + 1) / 10
            samples += (0..<6400).map { $0 % 2 == 0 ? level * gain : -level * gain }
            if i < words.count - 1 { silence(0.2) }
        }
    }

    mutating func silence(_ seconds: Double) {
        samples += [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    var seconds: Double { Double(samples.count) / 16_000 }
}

private func feed(_ session: LiveSession, _ speaker: Speaker, _ audio: Audio, at position: TimeInterval = 0) {
    audio.samples.withUnsafeBufferPointer { session.feed(speaker, $0, at: position) }
}

/// Waits until the session's snapshot matches (translation runs in its own task).
private func eventually(_ session: LiveSession, _ check: (LiveSnapshot) -> Bool) async -> LiveSnapshot {
    for _ in 0..<200 {
        let snapshot = await session.snapshot
        if check(snapshot) { return snapshot }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await session.snapshot
}

@Suite fileprivate struct LiveSessionTests {
    fileprivate func makeSession(target: String? = "ru", languages: [String] = ["en"], translator: FakeTranslator? = FakeTranslator(),
                     folder: URL? = nil) async -> LiveSession {
        let session = LiveSession(folder: folder, startedAt: Date(), languages: languages, target: target,
                                  recognizer: FakeRecognizer(), translator: translator)
        await session.start(cycling: false)
        _ = await eventually(session) { $0.status == .running }
        return session
    }

    @Test func phraseBecomesALineAtThePauseAndIsTranslated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("granula-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = await makeSession(folder: folder)

        var audio = Audio()
        audio.silence(0.5)
        audio.say(["alpha", "bravo"])
        feed(session, .them, audio)
        await session.cycle()
        var snapshot = await session.snapshot
        #expect(snapshot.lines.isEmpty, "no pause yet: the phrase is in progress")
        #expect(snapshot.partials.first?.text == "alpha bravo")

        var pause = Audio()
        pause.silence(1.2)
        feed(session, .them, pause, at: audio.seconds)
        await session.cycle()
        snapshot = await eventually(session) { $0.lines.first?.translation != nil }
        let line = try #require(snapshot.lines.first)
        #expect(line.text == "alpha bravo")
        #expect(line.speaker == .them)
        #expect(abs(line.start - 0.5) < 0.01)
        #expect(line.translation == "ru:ALPHA BRAVO")
        #expect(line.language == "en")
        #expect(snapshot.partials.isEmpty)

        await session.finish()
        let saved = try #require(LiveLog.load(from: folder.appendingPathComponent(MeetingFile.live)))
        #expect(saved.map(\.translation) == ["ru:ALPHA BRAVO"])
    }

    @Test func microphoneEchoOfTheFarEndIsHidden() async throws {
        let session = await makeSession(target: nil)
        var them = Audio()
        them.silence(0.3)
        them.say(["charlie", "delta", "echo"])
        them.silence(1.5)
        // The mic hears the speakers 0.2 s later and quieter; then the owner speaks.
        var me = Audio()
        me.silence(0.5)
        me.say(["charlie", "delta", "echo"], gain: 1)
        me.silence(1.0)
        me.say(["golf", "hotel"])
        me.silence(1.2)
        feed(session, .them, them)
        feed(session, .me, me)
        await session.cycle()
        await session.cycle()
        let snapshot = await session.snapshot
        #expect(snapshot.lines.filter { $0.speaker == .me && $0.echo }.map(\.text) == ["charlie delta echo"])
        #expect(snapshot.visibleLines.map(\.text) == ["charlie delta echo", "golf hotel"])
        #expect(snapshot.visibleLines.map(\.speaker) == [.them, .me])
        await session.finish()
    }

    @Test func stopTurnsThePhraseInProgressIntoALine() async throws {
        let session = await makeSession(target: nil)
        var audio = Audio()
        audio.say(["foxtrot", "golf"])
        feed(session, .me, audio)
        await session.cycle()
        #expect(await session.snapshot.lines.isEmpty)
        await session.finish()
        let snapshot = await session.snapshot
        #expect(snapshot.lines.map(\.text) == ["foxtrot golf"])
        #expect(snapshot.partials.isEmpty)
    }

    @Test func missingLanguagePackIsReported() async throws {
        let session = await makeSession(target: "ru", languages: ["en"], translator: FakeTranslator(missing: ["en"]))
        let snapshot = await eventually(session) { $0.translation != .on }
        #expect(snapshot.translation == .missingLanguages(["en"]))
        await session.finish()
    }

    @Test func noTranslationBeforeMacOS26() async throws {
        let session = await makeSession(target: "ru", translator: nil)
        #expect(await session.snapshot.translation == .unavailableOS)
        var audio = Audio()
        audio.say(["alpha"])
        audio.silence(1.0)
        feed(session, .them, audio)
        await session.cycle()
        var snapshot = await session.snapshot
        #expect(snapshot.lines.count == 1)
        #expect(snapshot.pending.isEmpty, "nothing waits for a translator that does not exist")
        await session.setTarget("uk")
        snapshot = await session.snapshot
        #expect(snapshot.pending.isEmpty)
        await session.finish()
    }

    @Test func echoSpanningTwoFarEndLinesIsHidden() async throws {
        let session = await makeSession(target: nil)
        // The far end pauses 0.9 s and is cut into two lines; the mic hears the
        // pause shorter (0.5 s) and makes one line of both.
        var them = Audio()
        them.silence(0.3)
        them.say(["alpha", "bravo", "charlie"])
        them.silence(0.9)
        them.say(["delta", "echo"])
        them.silence(1.5)
        var me = Audio()
        me.silence(0.3)
        me.say(["alpha", "bravo", "charlie"])
        me.silence(0.5)
        me.say(["delta", "echo"])
        me.silence(1.9)
        feed(session, .them, them)
        feed(session, .me, me)
        await session.cycle()
        let snapshot = await session.snapshot
        #expect(snapshot.lines.filter { $0.speaker == .them }.map(\.text) == ["alpha bravo charlie", "delta echo"])
        #expect(snapshot.lines.filter { $0.speaker == .me }.map(\.echo) == [true])
        #expect(snapshot.visibleLines.allSatisfy { $0.speaker == .them })
        await session.finish()
    }

    @Test func ownerSpeakingOverTheFarEndStaysWhenTheFarEndFinishes() async throws {
        let session = await makeSession(target: nil)
        // The far end is mid-phrase while the owner says "alpha alpha" (headphones: no echo).
        var them = Audio()
        them.say(["alpha", "bravo", "charlie", "delta", "echo"])
        var me = Audio()
        me.silence(0.2)
        me.say(["alpha", "alpha"])
        me.silence(1.6)
        feed(session, .them, them)
        feed(session, .me, me)
        await session.cycle()
        var snapshot = await session.snapshot
        #expect(snapshot.partials.first { $0.speaker == .them }?.text == "alpha bravo charlie delta echo")
        #expect(snapshot.visibleLines.map(\.text) == ["alpha alpha"])

        // The far end's phrase finishes: it is compared with the owner's line once, not twice.
        var pause = Audio()
        pause.silence(1.2)
        feed(session, .them, pause, at: them.seconds)
        await session.cycle()
        snapshot = await session.snapshot
        #expect(snapshot.lines.filter { $0.speaker == .them }.count == 1)
        #expect(snapshot.visibleLines.filter { $0.speaker == .me }.map(\.text) == ["alpha alpha"])
        await session.finish()
    }

    @Test func newLanguageDropsTranslationsIntoTheOldOne() async throws {
        let session = await makeSession(target: "ru", languages: ["en"])
        var audio = Audio()
        audio.say(["alpha"])
        audio.silence(1.0)
        feed(session, .them, audio)
        await session.cycle()
        _ = await eventually(session) { $0.lines.first?.translation == "ru:ALPHA" }
        // Into English: the line is English already, so it has no translation now.
        await session.setTarget("en")
        var snapshot = await eventually(session) { $0.lines.first?.target == "en" && $0.pending.isEmpty }
        #expect(snapshot.lines.first?.translation == nil)
        await session.setTarget("uk")
        snapshot = await eventually(session) { $0.lines.first?.translation != nil }
        #expect(snapshot.lines.first?.translation == "uk:ALPHA")
        // Off: no translation is shown. On again: the line is translated again.
        await session.setTarget(nil)
        #expect(await session.snapshot.lines.first?.translation == nil)
        await session.setTarget("uk")
        snapshot = await eventually(session) { $0.lines.first?.translation != nil }
        #expect(snapshot.lines.first?.translation == "uk:ALPHA")
        await session.finish()
    }

    @Test func newFromLanguageTranslatesTheLastLinesAgain() async throws {
        let session = await makeSession(target: "ru", languages: ["en"])
        var audio = Audio()
        audio.say(["alpha"])
        audio.silence(1.0)
        feed(session, .them, audio)
        await session.cycle()
        _ = await eventually(session) { $0.lines.first?.translation == "ru:ALPHA" }
        // From is now Russian-only: the line counts as Russian, and its old translation goes.
        await session.update(target: "ru", languages: ["ru"])
        let snapshot = await eventually(session) { $0.lines.first?.language == "ru" && $0.pending.isEmpty }
        #expect(snapshot.lines.first?.translation == nil)
        await session.finish()
    }

    @Test func aLineAlreadyInTheTargetIsShownAsItIsAtOnce() async throws {
        let translator = FakeTranslator()
        let session = await makeSession(target: "ru", languages: ["ru"], translator: translator)
        var audio = Audio()
        audio.say(["alpha"])
        audio.silence(1.0)
        feed(session, .them, audio)
        await session.cycle()
        // Told as Russian when it becomes a line: never waiting for a translation, nothing asked.
        let snapshot = await session.snapshot
        #expect(snapshot.lines.first?.language == "ru")
        #expect(snapshot.lines.first?.target == "ru")
        #expect(snapshot.lines.first?.translation == nil)
        #expect(snapshot.pending.isEmpty)
        #expect(await translator.calls == 0)
        await session.finish()
    }

    @Test func linesWaitingForALanguagePackAreTranslatedOnceItArrives() async throws {
        let translator = FakeTranslator(missing: ["en"])
        let session = await makeSession(target: "ru", languages: ["en"], translator: translator)
        var first = Audio()
        first.say(["alpha"])
        first.silence(1.0)
        feed(session, .them, first)
        await session.cycle()
        var snapshot = await eventually(session) { $0.lines.first?.target == "ru" && $0.pending.isEmpty }
        #expect(snapshot.lines.first?.translation == nil)
        #expect(snapshot.translation == .missingLanguages(["en"]))

        // The owner downloads the pack mid-meeting; the next line is translated, and so is the one that waited.
        await translator.install("en")
        var second = Audio()
        second.say(["bravo"])
        second.silence(1.0)
        feed(session, .them, second, at: first.seconds)
        await session.cycle()
        snapshot = await eventually(session) { $0.lines.count == 2 && $0.lines.allSatisfy { $0.translation != nil } }
        #expect(snapshot.lines.map(\.translation) == ["ru:ALPHA", "ru:BRAVO"])
        #expect(snapshot.translation == .on)
        // The new line first; the one that waited after it.
        let waited = try #require(snapshot.lines[0].translatedAt), fresh = try #require(snapshot.lines[1].translatedAt)
        #expect(fresh <= waited)
        await session.finish()
    }

    @Test func phraseFinishesWhenItsTrackGoesQuiet() async throws {
        let session = await makeSession(target: nil)
        var audio = Audio()
        audio.say(["foxtrot", "golf"])
        feed(session, .me, audio)
        await session.cycle()
        #expect(await session.snapshot.partials.first?.text == "foxtrot golf")
        // The microphone is unplugged: no more audio, not even silence.
        try await Task.sleep(for: .seconds(LiveSession.stalledAfter + 0.2))
        await session.cycle()
        let snapshot = await session.snapshot
        #expect(snapshot.lines.map(\.text) == ["foxtrot golf"])
        #expect(snapshot.partials.isEmpty)
        await session.finish()
    }

    @Test func finishedSessionIsReleased() async throws {
        weak var released: LiveSession?
        do {
            let session = await makeSession(target: "ru")
            // The app's handler refers to its session, as AppModel's does.
            await session.setOnChange { _ in _ = session }
            var audio = Audio()
            audio.say(["alpha"])
            audio.silence(1.0)
            feed(session, .them, audio)
            await session.cycle()
            await session.finish()
            released = session
        }
        for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released == nil)
    }

    @Test func choosingALanguageTranslatesRecentLines() async throws {
        let session = await makeSession(target: nil)
        var audio = Audio()
        audio.say(["alpha"])
        audio.silence(1.0)
        audio.say(["bravo"])
        audio.silence(1.0)
        feed(session, .them, audio)
        await session.cycle()
        #expect(await session.snapshot.lines.count == 2)
        await session.setTarget("uk")
        let snapshot = await eventually(session) { $0.lines.allSatisfy { $0.translation != nil } }
        #expect(snapshot.lines.map(\.translation) == ["uk:ALPHA", "uk:BRAVO"])
        await session.finish()
    }

    @Test func lineAlreadyInTheTargetLanguageIsNotTranslated() async throws {
        let session = await makeSession(target: "en", languages: ["en"])
        var audio = Audio()
        audio.say(["india"])
        audio.silence(1.0)
        feed(session, .them, audio)
        await session.cycle()
        let snapshot = await eventually(session) { $0.lines.first?.target != nil }
        #expect(snapshot.lines.first?.translation == nil)
        #expect(snapshot.lines.first?.language == "en")
        await session.finish()
    }
}

@Suite struct LiveTrackTests {
    @Test func aTrackFarBehindKeepsItsLast50Seconds() throws {
        let track = LiveTrack()
        let samples = [Float](repeating: 0.01, count: Int(61 * LiveTrack.rate))
        samples.withUnsafeBufferPointer { track.append($0, at: 0) }
        let window = try #require(track.takeWindow { _, _, _ in true })
        #expect(abs(window.duration - LiveTrack.keepSeconds) < 0.01)
        #expect(abs(window.origin - 11) < 0.01)
    }

    @Test func skippedWindowKeepsItsCounts() throws {
        let track = LiveTrack()
        let loud = [Float](repeating: 0.5, count: Int(0.1 * LiveTrack.rate))
        loud.withUnsafeBufferPointer { track.append($0, at: 0) }
        // Too little new audio yet: not taken, and the sound heard is not forgotten.
        #expect(track.takeWindow { new, _, _ in new >= 0.25 } == nil)
        let quiet = [Float](repeating: 0, count: Int(0.2 * LiveTrack.rate))
        quiet.withUnsafeBufferPointer { track.append($0, at: 0.1) }
        let window = try #require(track.takeWindow { new, _, _ in new >= 0.25 })
        #expect(window.heardSound)
        #expect(abs(window.newSeconds - 0.3) < 0.01)
    }

    @Test func stoppedTrackIgnoresAudio() {
        let track = LiveTrack()
        track.stop()
        let samples = [Float](repeating: 0.5, count: 16_000)
        samples.withUnsafeBufferPointer { track.append($0, at: 0) }
        #expect(track.takeWindow { _, _, _ in true }?.samples.isEmpty == true)
    }
}

// MARK: - Transcript after the meeting

@Suite struct TranscriptTranslationTests {
    @Test func linesAreTranslatedAndSameLanguageKept() async throws {
        let transcript = Transcript(segments: [
            Segment(speaker: .them, start: 0, end: 2, text: "Давайте обсудим бюджет на следующий квартал"),  // not localized: test speech
            Segment(speaker: .me, start: 3, end: 5, text: "Let's move the launch to next Tuesday"),
        ])
        let outcome = await TranscriptTranslation.build(transcript, to: "en", languages: ["ru", "en"],
                                                        translator: FakeTranslator())
        let translation = try #require(outcome.translation)
        #expect(translation.lines[0] == "en:ДАВАЙТЕ ОБСУДИМ БЮДЖЕТ НА СЛЕДУЮЩИЙ КВАРТАЛ")  // not localized: test speech
        #expect(translation.lines[1] == nil)
        #expect(translation.markdown(for: transcript).contains("[00:03] Me: Let's move the launch to next Tuesday"))
        #expect(outcome.missing.isEmpty)
    }

    @Test func nothingIsSavedWhenEveryPackIsMissing() async throws {
        let transcript = Transcript(segments: [
            Segment(speaker: .them, start: 0, end: 2, text: "Давайте обсудим бюджет на следующий квартал"),  // not localized: test speech
        ])
        let outcome = await TranscriptTranslation.build(transcript, to: "en", languages: ["ru", "en"],
                                                        translator: FakeTranslator(missing: ["ru"]))
        #expect(outcome.translation == nil)
        #expect(outcome.missing == ["ru"])
    }
}
