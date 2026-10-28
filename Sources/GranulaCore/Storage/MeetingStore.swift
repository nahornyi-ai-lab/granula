import Foundation

/// File names inside a meeting folder.
public enum MeetingFile {
    public static let meta = "meeting.json"
    public static let notes = "notes.md"
    public static let summary = "summary.md"
    public static let transcriptMarkdown = "transcript.md"
    public static let transcriptJSON = "transcript.json"
    public static let micRaw = "mic.caf"
    public static let systemRaw = "system.caf"
    public static let micAudio = "mic.m4a"
    public static let systemAudio = "system.m4a"
}

/// A meeting together with the folder it lives in.
public struct MeetingRecord: Identifiable, Equatable, Sendable {
    public var meeting: Meeting
    public var folder: URL
    public var id: String { meeting.id }

    public func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
}

/// One folder per meeting under `~/Documents/Granula/`, plain files only.
public final class MeetingStore: @unchecked Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Granula", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public var templatesFolder: URL { root.appendingPathComponent("_templates", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let folderDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    public func create(title: String, callApp: String? = nil, startedAt: Date = Date()) throws -> MeetingRecord {
        let folder = uniqueFolder(for: title, date: startedAt)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meeting = Meeting(id: UUID().uuidString, title: title, startedAt: startedAt, callApp: callApp)
        let record = MeetingRecord(meeting: meeting, folder: folder)
        try save(record)
        try Data().write(to: record.url(MeetingFile.notes))
        return record
    }

    public func save(_ record: MeetingRecord) throws {
        let data = try Self.encoder.encode(record.meeting)
        try data.write(to: record.url(MeetingFile.meta), options: .atomic)
    }

    public func load(folder: URL) -> MeetingRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(MeetingFile.meta)),
              let meeting = try? Self.decoder.decode(Meeting.self, from: data) else { return nil }
        return MeetingRecord(meeting: meeting, folder: folder)
    }

    /// Every meeting folder, newest first.
    public func loadAll() -> [MeetingRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return folders
            .filter { !$0.lastPathComponent.hasPrefix("_") }
            .compactMap(load(folder:))
            .sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    /// Renames the folder to match a new title. Returns the record at its new place.
    public func rename(_ record: MeetingRecord, to title: String) throws -> MeetingRecord {
        var updated = record
        updated.meeting.title = title
        let target = uniqueFolder(for: title, date: record.meeting.startedAt, excluding: record.folder)
        if target.lastPathComponent != record.folder.lastPathComponent {
            if Self.sameItem(target, record.folder) {
                // Case-only change on a case-insensitive disk: go through a temporary name.
                let temp = root.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.moveItem(at: record.folder, to: temp)
                try FileManager.default.moveItem(at: temp, to: target)
            } else {
                try FileManager.default.moveItem(at: record.folder, to: target)
            }
            updated.folder = target
        }
        try save(updated)
        return updated
    }

    public func read(_ name: String, of record: MeetingRecord) -> String? {
        try? String(contentsOf: record.url(name), encoding: .utf8)
    }

    public func write(_ text: String, _ name: String, of record: MeetingRecord) throws {
        try text.write(to: record.url(name), atomically: true, encoding: .utf8)
    }

    private func uniqueFolder(for title: String, date: Date, excluding current: URL? = nil) -> URL {
        let base = "\(Self.folderDate.string(from: date)) \(Self.sanitize(title))"
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path),
              !(current.map { Self.sameItem(candidate, $0) } ?? false) {
            candidate = root.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Whether a folder already carries this title: "<date> <title>" or "<date> <title> (n)".
    public static func folder(_ folder: URL, matches title: String, date: Date) -> Bool {
        let base = "\(folderDate.string(from: date)) \(sanitize(title))"
        let name = folder.lastPathComponent
        guard name.hasPrefix(base) else { return false }
        let rest = name.dropFirst(base.count)
        return rest.isEmpty || rest.wholeMatch(of: #/ \(\d+\)/#) != nil
    }

    /// Same file on disk (catches paths that differ only in letter case).
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        let ids = [a, b].map { (try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject }
        guard let x = ids[0], let y = ids[1] else { return a.standardizedFileURL == b.standardizedFileURL }
        return x.isEqual(y)
    }

    static func sanitize(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(80))
        return short.isEmpty ? "Встреча" : short  // not localized: folder name
    }
}
