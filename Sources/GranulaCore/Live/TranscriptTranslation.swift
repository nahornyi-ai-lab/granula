import Foundation

/// The finished transcript in another language: one entry per transcript line,
/// nil where the line is already in that language or could not be translated.
/// Saved as `transcript.translation.json` next to `transcript.json`.
public struct TranscriptTranslation: Codable, Equatable, Sendable {
    public var target: String
    public var lines: [String?]

    public init(target: String, lines: [String?]) {
        self.target = target
        self.lines = lines
    }

    public static func load(from url: URL) -> TranscriptTranslation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptTranslation.self, from: data)
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// The line's text in `target`: the translation, or the original when none was needed.
    public func text(at index: Int, of transcript: Transcript) -> String {
        (index < lines.count ? lines[index] : nil) ?? transcript.segments[index].text
    }

    /// `[mm:ss] Me: …` lines in the target language, like `transcript.md`.
    public func markdown(for transcript: Transcript) -> String {
        transcript.segments.indices.map { i in
            let segment = transcript.segments[i]
            return "[\(Transcript.clock(segment.start))] \(segment.speaker.rawValue): \(text(at: i, of: transcript))"
        }
        .joined(separator: "\n\n") + "\n"
    }

    public struct Outcome: Sendable {
        /// Nil when nothing could be translated (language packs missing).
        public var translation: TranscriptTranslation?
        /// Source languages whose pack into the target is not downloaded.
        public var missing: [String]
    }

    /// Translates every line, detecting each line's language among `languages`.
    public static func build(_ transcript: Transcript, to target: String, languages: [String],
                             translator: LineTranslating) async -> Outcome {
        var lines: [String?] = []
        var missing: Set<String> = []
        var translated = 0
        var failed = 0
        var previous: [Speaker: String] = [:]
        for segment in transcript.segments {
            let language = LanguageDetector.detect(segment.text, among: languages, previous: previous[segment.speaker])
            if let language { previous[segment.speaker] = language }
            guard let language else {
                lines.append(nil)
                continue
            }
            switch await translator.translate(segment.text, from: language, to: target) {
            case .translated(let text):
                lines.append(text)
                translated += 1
            case .missingLanguage(let source):
                missing.insert(source)
                lines.append(nil)
            case .sameLanguage:
                lines.append(nil)
            case .unsupported, .failed:
                failed += 1
                lines.append(nil)
            }
        }
        Log.event("translation.transcript", "target=\(target) lines=\(lines.count) translated=\(translated) failed=\(failed) missing=\(missing.sorted().joined(separator: ","))")
        let usable = translated > 0 || (missing.isEmpty && failed == 0)
        return Outcome(translation: usable ? TranscriptTranslation(target: target, lines: lines) : nil,
                       missing: missing.sorted())
    }
}
