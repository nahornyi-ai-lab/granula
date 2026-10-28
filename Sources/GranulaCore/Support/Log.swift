import Foundation
import os

/// App event log: `~/Library/Logs/Granula/granula.log` plus the unified log.
/// E2E scripts read the file, so event lines stay short and stable.
public enum Log {
    private static let logger = Logger(subsystem: "ai.nahornyi.granula", category: "app")
    private static let queue = DispatchQueue(label: "ai.nahornyi.granula.log")

    public static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Granula", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("granula.log")
    }()

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// `event` is a short machine-readable tag ("recording.started"), `detail` free text.
    public static func event(_ event: String, _ detail: String = "") {
        let line = "\(stamp.string(from: Date())) \(event)\(detail.isEmpty ? "" : " " + detail)\n"
        logger.info("\(event, privacy: .public) \(detail, privacy: .public)")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    public static func error(_ event: String, _ error: Error) {
        Self.event(event, "error=\(String(describing: error))")
    }
}
