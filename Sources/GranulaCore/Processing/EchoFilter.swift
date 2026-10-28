import Foundation

// Adapted from amanu (MIT, Copyright (c) 2026 Andrew Jones, Samat Galimov),
// Sources/amanu/Transcription/EchoFilter.swift. Thresholds follow the
// granula v1 spec (80 % in-order containment, ±1.5 s).

/// Drops "Я" lines that are the speakers heard by the microphone: when a call
/// plays through the speakers, the raw mic hears the far end, which would
/// otherwise appear twice — as "Собеседник" and again as "Я".
public enum EchoFilter {
    static let containment = 0.8
    static let pad: TimeInterval = 1.5

    public static func dropEchoes(_ segments: [Segment]) -> (kept: [Segment], dropped: Int) {
        let them = segments.filter { $0.speaker == .them }
        guard !them.isEmpty else { return (segments, 0) }
        var dropped = 0
        let kept = segments.filter { segment in
            guard segment.speaker == .me else { return true }
            let overlapping = them.filter {
                min(segment.end, $0.end + pad) > max(segment.start, $0.start - pad)
            }
            if isEcho(segment, of: overlapping) {
                dropped += 1
                return false
            }
            return true
        }
        return (kept, dropped)
    }

    static func isEcho(_ me: Segment, of overlapping: [Segment]) -> Bool {
        guard !overlapping.isEmpty else { return false }
        let meWords = words(me.text)
        // Nothing to compare: keep. This filter must fail toward keeping speech.
        guard !meWords.isEmpty else { return false }
        let themWords = overlapping.flatMap { words($0.text) }
        let contained = Double(subsequenceLength(of: meWords, in: themWords)) / Double(meWords.count)
        return contained >= containment
    }

    /// Lowercased words without punctuation. Not ASCII-only: restricting to
    /// ASCII would turn every Cyrillic line into zero words.
    static func words(_ text: String) -> [String] {
        var cleaned = ""
        for ch in text.lowercased().replacingOccurrences(of: "ё", with: "е") {
            cleaned.append(ch.isLetter || ch.isNumber || ch == "'" ? ch : " ")
        }
        return cleaned.split(separator: " ").map { String($0) }
    }

    /// Longest common subsequence: how many of `a`'s words appear in `b` in order.
    static func subsequenceLength(of a: [String], in b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var curr = prev
        for i in 1...a.count {
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], curr[j - 1])
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
