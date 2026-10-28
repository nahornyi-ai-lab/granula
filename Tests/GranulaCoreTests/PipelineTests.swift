import AVFoundation
import XCTest
@testable import GranulaCore

/// T1 — the critical positive scenario: without it the meeting text is lost.
/// Real model, real FLEURS speech (bench/data, see bench/scripts/setup.sh):
/// the far end speaks Ukrainian and English on the system track; the mic
/// hears that through the speakers (delayed, quieter, noisy) and then the
/// owner says a Russian sentence.
final class PipelineTests: XCTestCase {
    static let bench = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("bench/data/sets/clean")

    static let ukRef = "змішайте два порошки шляхом обертання їх у посудині а потім чистими мокрими руками зімніть їх у кулю"
    static let enRef = "the document according to the leak will refer to the borders dispute which palestine wants based on the borders before the 1967 mideast war"
    static let ruRef = "он не назвал цифру для сокращений бюджетов сказав что они будут сделаны исходя из производительности экономики китая"

    func testTranscriptLabelsSpeakersAndDropsEcho() async throws {
        let rate = 16_000
        // FLEURS clips peak near -40 dBFS; a call plays at about -6 dBFS.
        let uk = Self.normalized(try Self.samples(Self.bench.appendingPathComponent("uk_ua/1664.wav")))
        let en = Self.normalized(try Self.samples(Self.bench.appendingPathComponent("en_us/1665.wav")))
        let ru = Self.normalized(try Self.samples(Self.bench.appendingPathComponent("ru_ru/1661.wav")))
        func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }

        // System track: far end, Ukrainian then English.
        let system = silence(0.5) + uk + silence(1.5) + en + silence(1.5 + Double(ru.count) / Double(rate) + 1)
        // Mic track: the speakers heard 0.2 s late at -10 dB plus room noise, then the owner in Russian.
        var mic = silence(0.2) + system.map { $0 * 0.3 }
        mic = Array(mic.prefix(system.count))
        let ruStart = Int((0.5 + 1.5 + 1.5) * Double(rate)) + uk.count + en.count
        for (i, s) in ru.enumerated() where ruStart + i < mic.count { mic[ruStart + i] += s }
        var noise = SystemRandomNumberGenerator()
        for i in mic.indices { mic[i] += Float.random(in: -0.003...0.003, using: &noise) }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("granula-t1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let micURL = dir.appendingPathComponent(MeetingFile.micRaw)
        let systemURL = dir.appendingPathComponent(MeetingFile.systemRaw)
        try Self.writeCAF(mic, to: micURL)
        try Self.writeCAF(system, to: systemURL)

        let transcript = try await TranscriptPipeline.build(mic: micURL, system: systemURL)
        let them = transcript.segments.filter { $0.speaker == .them }.map(\.text).joined(separator: " ")
        let me = transcript.segments.filter { $0.speaker == .me }.map(\.text).joined(separator: " ")
        let themWER = Self.wer(reference: Self.ukRef + " " + Self.enRef, hypothesis: them)
        let meWER = Self.wer(reference: Self.ruRef, hypothesis: me)
        print("them WER \(themWER), me WER \(meWER), echoes dropped \(transcript.droppedEchoes)")

        XCTAssertLessThanOrEqual(themWER, 0.15, "far-end lines must be recognized")
        XCTAssertGreaterThanOrEqual(transcript.droppedEchoes, 1, "the echo was recognized and must be dropped")
        // Only the Russian sentence may stay on the "Я" side: a kept echo would add Ukrainian/English words.
        XCTAssertLessThanOrEqual(meWER, 0.2, "the owner's Russian line must be labeled Я, without echo")
    }

    // MARK: - Helpers

    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func normalized(_ samples: [Float], peak: Float = 0.5) -> [Float] {
        let current = samples.map(abs).max() ?? 0
        return current > 0 ? samples.map { $0 * peak / current } : samples
    }

    static func writeCAF(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = max(-1, min(1, s)) }
        try file.write(from: buffer)
    }

    /// Same normalization as bench/scripts/score.py: lowercase, ё→е, no apostrophes, punctuation → space.
    static func normalize(_ s: String) -> [String] {
        var out = ""
        for ch in s.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: "ё", with: "е") {
            if "'’ʼ`´‘".contains(ch) { continue }
            out.append(ch.isLetter || ch.isNumber ? ch : " ")
        }
        return out.split(separator: " ").map(String.init)
    }

    static func wer(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var curr = [i] + [Int](repeating: 0, count: h.count)
            for j in 1...max(h.count, 1) where j <= h.count {
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = curr
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
