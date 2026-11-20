import Foundation

/// One finished line of the live transcript, shown while the meeting goes on.
/// The transcript built after the meeting from the full recording replaces it.
public struct LiveLine: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var speaker: Speaker
    /// Seconds from the recording start, on the same timeline as the audio files.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Detected language of `text` ("ru", "en" …), set once translation looked at it.
    public var language: String?
    /// `text` in `target`; nil while pending, when not needed or when it failed.
    public var translation: String?
    public var target: String?
    /// The microphone heard the far end through the speakers: not shown.
    public var echo: Bool
    /// When the line was finished and translated, seconds from the recording start.
    public var finishedAt: TimeInterval?
    public var translatedAt: TimeInterval?

    public init(id: Int, speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.echo = false
    }

    public var segment: Segment { Segment(speaker: speaker, start: start, end: end, text: text) }
}

/// The phrase being spoken right now; its words may still change.
public struct LivePartial: Equatable, Sendable {
    public var speaker: Speaker
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var translation: String?
    /// Looks like the far end heard by the microphone: not shown.
    public var echo: Bool

    public init(speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String,
                translation: String? = nil, echo: Bool = false) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.translation = translation
        self.echo = echo
    }
}

/// What the screen shows: finished lines and the phrases in progress.
public struct LiveSnapshot: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case loadingModel
        case running
        /// The speech model is not downloaded; live text is off for this meeting.
        case noModel
        case failed(String)
    }

    public enum TranslationState: Equatable, Sendable {
        case off
        case on
        /// Needs macOS 26 or later.
        case unavailableOS
        /// Language packs to download first (source languages, `target` is the snapshot's).
        case missingLanguages([String])
    }

    public var status: Status
    public var lines: [LiveLine]
    public var partials: [LivePartial]
    public var target: String?
    public var translation: TranslationState
    /// Lines waiting for their translation.
    public var pending: Set<Int>

    public init(status: Status = .loadingModel, lines: [LiveLine] = [], partials: [LivePartial] = [],
                target: String? = nil, translation: TranslationState = .off, pending: Set<Int> = []) {
        self.status = status
        self.lines = lines
        self.partials = partials
        self.target = target
        self.translation = translation
        self.pending = pending
    }

    /// Lines to show: everything except echoes, in time order.
    public var visibleLines: [LiveLine] { lines.filter { !$0.echo } }
    public var visiblePartials: [LivePartial] {
        partials.filter { !$0.echo && !$0.text.isEmpty }.sorted { $0.start < $1.start }
    }
}

/// `live.jsonl` in the meeting folder: one JSON object per line change, appended
/// as it happens, so a crash loses nothing. Reading keeps the last version of each line.
public final class LiveLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(url: URL) {
        self.url = url
    }

    public func append(_ line: LiveLine) {
        guard var data = try? Self.encoder.encode(line) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            Log.error("live.log_write_failed", error)
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    /// The lines of a meeting folder, in time order; nil when there is no live log.
    public static func load(from url: URL) -> [LiveLine]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var byID: [Int: LiveLine] = [:]
        let decoder = JSONDecoder()
        for row in data.split(separator: 0x0A) where !row.isEmpty {
            // A line cut by a crash mid-write is skipped.
            if let line = try? decoder.decode(LiveLine.self, from: Data(row)) { byID[line.id] = line }
        }
        return byID.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
