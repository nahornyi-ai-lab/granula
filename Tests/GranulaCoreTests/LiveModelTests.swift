import AVFoundation
import Foundation
import Testing
@testable import GranulaCore

/// The live transcript with the real model: a call spoken by macOS voices
/// (Russian, English, Ukrainian, Spanish) is fed in real time, as capture would. Every
/// phrase must show up as a line within seconds of its end.
/// Needs the downloaded speech model; skipped without it.
@Suite struct LiveModelTests {
    static let phrases: [(voice: String, text: String)] = [
        ("Milena", "Давайте обсудим бюджет на следующий квартал и сроки запуска."),  // not localized: test speech
        ("Samantha", "The client agreed to move the launch to next Tuesday."),
        ("Lesya", "Ми готові підписати договір наступного тижня."),  // not localized: test speech
        ("Milena", "Тогда я отправлю презентацию сегодня вечером."),  // not localized: test speech
        ("Mónica", "Podemos firmar el contrato la próxima semana."),
    ]

    @Test(.enabled(if: Transcriber.modelsPresent && FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
    func phrasesAppearWithinSecondsOfBeingSpoken() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("granula-live-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The call: 1 s lead, phrases 2 s apart, 3 s tail.
        var samples = [Float](repeating: 0, count: 16_000)
        var spans: [(start: Double, end: Double, text: String)] = []
        for (i, phrase) in Self.phrases.enumerated() {
            let url = dir.appendingPathComponent("p\(i).wav")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", phrase.voice, "-o", url.path, "--data-format=LEF32@16000", phrase.text]
            try say.run()
            say.waitUntilExit()
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let start = Double(samples.count) / 16_000
            samples += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            spans.append((start, Double(samples.count) / 16_000, phrase.text))
            samples += [Float](repeating: 0, count: (i == Self.phrases.count - 1 ? 3 : 2) * 16_000)
        }

        let startedAt = Date()
        let session = LiveSession(folder: dir, startedAt: startedAt, languages: ["ru", "en", "uk", "es"], target: nil,
                                  recognizer: Transcriber.shared, translator: nil)
        await session.start()
        for _ in 0..<600 where await session.snapshot.status != .running {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await session.snapshot.status == .running)

        // Real time: 100 ms of audio every 100 ms. The audio's timeline starts now,
        // after the model loaded; the session's clock started before.
        let begin = Date()
        let lead = begin.timeIntervalSince(startedAt)
        let chunk = 1_600
        var position = 0
        while position < samples.count {
            let end = min(samples.count, position + chunk)
            samples[position..<end].withUnsafeBufferPointer {
                session.feed(.them, $0, at: Double(position) / 16_000)
            }
            position = end
            let due = begin.addingTimeInterval(Double(position) / 16_000)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
        let snapshotBeforeStop = await session.snapshot
        await session.finish()
        let stats = await session.decodeStats

        let lines = snapshotBeforeStop.visibleLines
        print(String(format: "decodes=%d mean=%.0f ms max=%.0f ms", stats.count, stats.mean * 1000, stats.max * 1000))
        for line in lines {
            print(String(format: "[%5.1f–%5.1f] +%.1fs %@", line.start, line.end, (line.finishedAt ?? 0) - lead - line.end, line.text))
        }
        func words(_ text: String) -> [String] {
            text.lowercased().replacingOccurrences(of: "ё", with: "е")  // not localized: letters
                .split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        for span in spans {
            let near = lines.filter { $0.end >= span.start - 1 && $0.start <= span.end + 1 }
            let heard = Set(near.flatMap { words($0.text) })
            let expected = words(span.text)
            let recall = Double(expected.filter(heard.contains).count) / Double(expected.count)
            let delay = near.compactMap { line in line.finishedAt.map { $0 - lead - line.end } }.max()
            print(String(format: "recall=%.2f delay=%@ — %@", recall, delay.map { String(format: "%.1fs", $0) } ?? "none", span.text))
            #expect(recall >= 0.7, "\(span.text)")
            #expect((delay ?? 99) <= 3, "line for “\(span.text)” came too late")
        }
    }
}
