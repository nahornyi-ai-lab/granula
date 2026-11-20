import FluidAudio
import Foundation

/// Decides which recognized words of the live audio window are a finished line.
/// The window holds the audio since the last cut; it is recognized again every
/// half second, and the words come with times inside the window.
///
/// A phrase is finished when a pause of `pause` follows it — the same rule that
/// splits the transcript after the meeting. A window that grows past `forceAfter`
/// without such a pause is cut at its widest gap, so the model always sees
/// less than its 15-second input.
public enum LiveSegmenter {
    public static let pause: TimeInterval = Segmenter.pause
    public static let forceAfter: TimeInterval = 11
    /// A forced cut keeps this much of the window's end: its last words may still change.
    static let keepTail: TimeInterval = 2
    /// Audio without words is dropped down to this much (a word may be starting).
    static let keepSilence: TimeInterval = 1
    static let minSilenceToTrim: TimeInterval = 3

    public struct Cut {
        /// Finished lines, each a run of words, in order.
        public var lines: [[WordTiming]]
        /// Where to cut the window (seconds inside it); nil keeps all audio.
        public var cutAt: TimeInterval?
        /// The words after the cut: the phrase in progress.
        public var partial: [WordTiming]
    }

    /// - Parameters:
    ///   - words: recognized words of the window, times inside it.
    ///   - duration: the window's length in seconds.
    ///   - flush: the recording stopped: whatever is left is finished.
    public static func cut(_ words: [WordTiming], duration: TimeInterval, flush: Bool = false) -> Cut {
        let words = words.filter { !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last = words.last else {
            if flush { return Cut(lines: [], cutAt: duration, partial: []) }
            let trim = duration >= minSilenceToTrim ? duration - keepSilence : nil
            return Cut(lines: [], cutAt: trim, partial: [])
        }

        // Runs of words split by pauses.
        var groups: [[WordTiming]] = [[words[0]]]
        for word in words.dropFirst() {
            if word.startTime - groups[groups.count - 1].last!.endTime >= pause {
                groups.append([word])
            } else {
                groups[groups.count - 1].append(word)
            }
        }

        let tail = duration - last.endTime
        if flush || tail >= pause {
            let cutAt = flush ? duration : last.endTime + tail / 2
            return Cut(lines: groups, cutAt: cutAt, partial: [])
        }
        if groups.count > 1 {
            let finished = Array(groups.dropLast())
            let next = groups[groups.count - 1]
            let cutAt = (finished.last!.last!.endTime + next[0].startTime) / 2
            return Cut(lines: finished, cutAt: cutAt, partial: next)
        }
        guard duration >= forceAfter else {
            return Cut(lines: [], cutAt: nil, partial: words)
        }

        // One long phrase: cut at the widest gap among words that are no longer at the edge.
        let settled = words.indices.filter { words[$0].endTime <= duration - keepTail }
        guard let lastSettled = settled.last else {
            return Cut(lines: [], cutAt: nil, partial: words)
        }
        var best = lastSettled
        var bestGap = -1.0
        for i in settled where i + 1 < words.count {
            let gap = words[i + 1].startTime - words[i].endTime
            if gap >= bestGap {  // ties: the later gap, so the finished line is longer
                bestGap = gap
                best = i
            }
        }
        let finished = Array(words[...best])
        let rest = Array(words[(best + 1)...])
        let cutAt = rest.first.map { (words[best].endTime + $0.startTime) / 2 } ?? words[best].endTime
        return Cut(lines: [finished], cutAt: cutAt, partial: rest)
    }

    /// The text of a run of words, cleaned like the final transcript.
    public static func text(of words: [WordTiming]) -> String {
        Segmenter.cleanUnknown(words.map(\.word).joined(separator: " "))
    }
}
