import Foundation

/// Secrets in Granula's own folder of Application Support, in files only the owner's account
/// can read (0600). Not the keychain: an ad-hoc signed app looks like a new app to the keychain
/// after every update, and macOS asked for the login password each time. Never in the
/// repository, settings or the log.
public enum KeyFile {
    /// What a read gave: the value, nothing saved, or a file that could not be read.
    public enum Lookup: Equatable, Sendable {
        case found(String)
        case missing
        case refused
    }

    /// `~/Library/Application Support/Granula`.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Granula", isDirectory: true)
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Saves or replaces `value`; false when the file could not be written.
    @discardableResult
    public static func save(_ value: String, name: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        let path = url(name).path
        // Created as 0600 from the start: the value is never readable by others, not even briefly.
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { return false }
        let data = Array(value.utf8)
        return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
    }

    public static func read(name: String) -> Lookup {
        let url = url(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return .refused }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .missing : .found(trimmed)
    }

    public static func exists(name: String) -> Bool {
        if case .found = read(name: name) { return true }
        return false
    }

    public static func delete(name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }
}
