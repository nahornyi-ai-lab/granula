import Foundation

/// AI notes through the installed Claude Code CLI on the owner's subscription.
/// Called as a plain completion: no tools, no settings, no MCP servers, no
/// saved session — the transcript is other people's words and must not be
/// able to steer anything. No timeout; the user can cancel.
public final class SummaryGenerator: @unchecked Sendable {
    public enum SummaryError: Error, CustomStringConvertible {
        case claudeNotFound
        case failed(Int32, String)
        case empty
        case cancelled

        public var description: String {
            switch self {
            case .claudeNotFound: return String(localized: "не найден Claude Code (команда claude)")
            case .failed(let code, let output): return String(localized: "claude завершился с кодом \(code): \(output)")
            case .empty: return String(localized: "claude вернул пустой ответ")
            case .cancelled: return String(localized: "отменено")
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false

    public init() {}

    static let arguments = [
        "-p",
        "--model", "sonnet",
        "--output-format", "text",
        "--tools", "",
        "--strict-mcp-config",
        "--mcp-config", #"{"mcpServers":{}}"#,
        "--setting-sources", "",
        "--disable-slash-commands",
        "--no-session-persistence",
    ]

    /// Where `claude` lives. GUI apps do not inherit the shell PATH.
    public static func locateClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Last resort: ask the login shell.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public func generate(system: String, prompt: String) async throws -> String {
        guard let claude = Self.locateClaude() else { throw SummaryError.claudeNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = Self.arguments + ["--system-prompt", system]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(URL(fileURLWithPath: claude).deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        lock.withLock {
            self.process = process
            self.wasCancelled = false
        }
        let started = Date()
        Log.event("summary.started", "chars=\(prompt.count)")

        // Drain both pipes while claude runs: a full pipe would block it forever.
        let reads = DispatchGroup()
        var outData = Data(), errData = Data()
        reads.enter()
        DispatchQueue.global().async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global().async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            reads.leave()
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            // Writing on a background queue: a long transcript can exceed the
            // pipe buffer while claude has not started reading yet.
            // If claude exits before reading everything, the write fails
            // instead of killing Granula with SIGPIPE.
            signal(SIGPIPE, SIG_IGN)
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try? stdin.fileHandleForWriting.close()
            }
        }
        await withCheckedContinuation { done in reads.notify(queue: .global()) { done.resume() } }
        let out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self)
        let cancelled = lock.withLock { () -> Bool in
            self.process = nil
            return wasCancelled
        }
        if cancelled { throw SummaryError.cancelled }
        guard status == 0 else {
            Log.event("summary.failed", "code=\(status)")
            throw SummaryError.failed(status, String((err + out).suffix(600)))
        }
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummaryError.empty }
        Log.event("summary.done", String(format: "seconds=%.1f chars=%d", Date().timeIntervalSince(started), text.count))
        return text
    }

    public func cancel() {
        lock.withLock {
            wasCancelled = true
            process?.terminate()
        }
    }
}
