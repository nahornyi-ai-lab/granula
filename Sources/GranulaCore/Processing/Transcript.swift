import FluidAudio
import Foundation

public enum Speaker: String, Codable, Sendable {
    // not localized: stored in transcript.json; the app shows Speaker.label
    case me = "Я"  // not localized
    case them = "Собеседник"  // not localized
}

/// One line of the transcript.
public struct Segment: Codable, Equatable, Sendable {
    public var speaker: Speaker
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var segments: [Segment]
    public var droppedEchoes: Int

    public init(segments: [Segment], droppedEchoes: Int = 0) {
        self.segments = segments
        self.droppedEchoes = droppedEchoes
    }

    public static func load(from url: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// `[мм:сс] Я: …` lines.
    public var markdown: String {
        segments.map { "[\(Self.clock($0.start))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n\n") + "\n"
    }

    public static func clock(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Words → lines: a new line on a pause of 0.8 s or more, or when a line
/// would grow past 30 s.
public enum Segmenter {
    static let pause: TimeInterval = 0.8
    static let maxLength: TimeInterval = 30

    public static func segments(from words: [WordTiming], speaker: Speaker) -> [Segment] {
        var result: [Segment] = []
        var current: [WordTiming] = []

        func flush() {
            let text = cleanUnknown(current.map(\.word).joined(separator: " "))
            if let first = current.first, let last = current.last, !text.isEmpty {
                result.append(Segment(speaker: speaker, start: first.startTime, end: last.endTime, text: text))
            }
            current.removeAll()
        }

        for word in words {
            if let last = current.last, let first = current.first,
               word.startTime - last.endTime >= pause || word.endTime - first.startTime > maxLength {
                flush()
            }
            current.append(word)
        }
        flush()
        return result
    }

    /// The model has no token for "ё" (and a few symbols) and emits `<unk>`.
    /// Between two Cyrillic letters it is almost always "ё"; elsewhere it is dropped.
    static func cleanUnknown(_ text: String) -> String {
        guard text.contains("<unk>") else { return text }
        let cyrillic = Set("абвгдежзийклмнопрстуфхцчшщъыьэюяіїєґАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯІЇЄҐ")  // not localized: letters
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: "<unk>") {
            let before = rest[..<range.lowerBound]
            let after = rest[range.upperBound...]
            result += before
            let prev = (result.last).map { cyrillic.contains($0) } ?? false
            let next = after.first.map { cyrillic.contains($0) } ?? false
            if prev && next { result += (result.last!.isUppercase && (after.first!.isUppercase)) ? "Ё" : "ё" }  // not localized
            rest = after
        }
        result += rest
        return result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Both tracks merged by start time.
    public static func merge(_ a: [Segment], _ b: [Segment]) -> [Segment] {
        (a + b).sorted { $0.start == $1.start ? $0.speaker == .them : $0.start < $1.start }
    }
}

/// Audio files → finished transcript: recognize each track, cut into lines,
/// merge by time, drop echoes of the far end heard by the microphone.
public enum TranscriptPipeline {
    public static func build(mic: URL?, system: URL?) async throws -> Transcript {
        var mine: [Segment] = []
        var theirs: [Segment] = []
        if let mic {
            mine = Segmenter.segments(from: try await Transcriber.shared.words(in: mic), speaker: .me)
        }
        if let system {
            theirs = Segmenter.segments(from: try await Transcriber.shared.words(in: system), speaker: .them)
        }
        let filtered = EchoFilter.dropEchoes(Segmenter.merge(mine, theirs))
        return Transcript(segments: filtered.kept, droppedEchoes: filtered.dropped)
    }
}
