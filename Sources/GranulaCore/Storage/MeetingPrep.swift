import CryptoKit
import Foundation

/// What the owner prepared for an upcoming calendar meeting: `prep.json` with the choices,
/// `context.md` with the text. Kept in `<meetings folder>/_upcoming/<hash of the key>/`.
public struct MeetingPrep: Codable, Equatable, Sendable {
    /// `CalendarMeeting.prepKey`.
    public var key: String
    /// The event as it was when prepared — only to tell what a folder is for.
    public var title: String
    public var start: Date
    /// Hints and translation for this meeting; nil: the default when the recording starts.
    public var hints: Bool?
    public var translate: Bool?

    public init(key: String, title: String, start: Date, hints: Bool? = nil, translate: Bool? = nil) {
        self.key = key
        self.title = title
        self.start = start
        self.hints = hints
        self.translate = translate
    }
}

extension MeetingStore {
    static let prepFile = "prep.json"

    /// Preps of upcoming meetings; the "_" keeps the folder out of the meeting list.
    public var upcomingFolder: URL { root.appendingPathComponent("_upcoming", isDirectory: true) }

    /// The folder of one prep: the first 16 hex digits of the key's SHA-256 (the key itself
    /// may hold characters a file name cannot).
    public func prepFolder(key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return upcomingFolder.appendingPathComponent(String(hash.prefix(16)), isDirectory: true)
    }

    /// The prep and its context text; nil when nothing was prepared for this key.
    public func loadPrep(key: String) -> (prep: MeetingPrep, context: String)? {
        let folder = prepFolder(key: key)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.prepFile)),
              let prep = try? Self.decoder.decode(MeetingPrep.self, from: data), prep.key == key else { return nil }
        let context = (try? String(contentsOf: folder.appendingPathComponent(MeetingFile.context), encoding: .utf8)) ?? ""
        return (prep, context)
    }

    public func savePrep(_ prep: MeetingPrep, context: String) throws {
        let folder = prepFolder(key: prep.key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try context.write(to: folder.appendingPathComponent(MeetingFile.context), atomically: true, encoding: .utf8)
        try Self.encoder.encode(prep).write(to: folder.appendingPathComponent(Self.prepFile), options: .atomic)
    }

    /// After a change of the meetings folder: the preps of the old one that the new one lacks.
    public func copyPreps(from oldRoot: URL) {
        let old = oldRoot.appendingPathComponent("_upcoming", isDirectory: true)
        guard old.standardizedFileURL != upcomingFolder.standardizedFileURL,
              let folders = try? FileManager.default.contentsOfDirectory(
                at: old, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        try? FileManager.default.createDirectory(at: upcomingFolder, withIntermediateDirectories: true)
        for folder in folders {
            let target = upcomingFolder.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.copyItem(at: folder, to: target)
            }
        }
    }
}
