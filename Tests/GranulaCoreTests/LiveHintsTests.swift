import Foundation
import Testing
@testable import GranulaCore

/// The critical path of live hints: a turn of the other side, then quiet, reaches the judge;
/// on yes the answer model gets the whole conversation, the notes and "About me", and its
/// streamed pieces become the card's text. Without it no hint ever reaches the Live window.
@Suite(.serialized) struct LiveHintsTests {
    @Test func aTurnThatExpectsAReplyBecomesAStreamedHint() async throws {
        OpenRouterStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenRouterStub.self]
        let client = OpenRouterClient(session: URLSession(configuration: config),
                                      baseURL: URL(string: "https://openrouter.stub/api")!)
        let context = HintContext(title: "Migration sync", attendees: ["Dana"],
                                  notes: "Ask about the staging database.")
        // The recording started 100 s ago; the turn ended at 60 s: long quiet already.
        let hints = LiveHints(client: client,
                              settings: HintSettings(aboutMe: "The migration is planned for March."),
                              startedAt: Date().addingTimeInterval(-100),
                              key: { .found("test-key") }, context: { context }, translator: nil, quiet: 0.05)
        let seen = Seen()
        await hints.setOnChange { seen.add($0) }

        let lines = [
            LiveLine(id: 1, speaker: .me, start: 1, end: 3, text: "Hi, thanks for joining."),
            LiveLine(id: 2, speaker: .them, start: 40, end: 44, text: "Thanks for having me."),
            LiveLine(id: 3, speaker: .me, start: 45, end: 50, text: "Let's start with the plan."),
            LiveLine(id: 4, speaker: .them, start: 52, end: 60, text: "Tell me about your timeline for the migration."),
        ]
        await hints.update(LiveSnapshot(status: .running, lines: lines))

        let hint = try #require(await seen.waitFor { $0.hints.first?.state == .done }?.hints.first)
        #expect(hint.text == "We plan it for March, in two phases.")
        #expect(hint.lineIDs == [2, 4])

        let requests = OpenRouterStub.requests
        #expect(requests.map(\.path) == ["/api/alpha/decisions", "/api/v1/chat/completions"])
        #expect(requests.allSatisfy { $0.auth == "Bearer test-key" })

        let judge = requests[0].body
        #expect(judge["model"] as? String == HintSettings.defaultJudgeModel)
        let state = try #require(judge["state"] as? String)
        #expect(state.contains("Me: Hi, thanks for joining."))
        #expect(state.contains("They just said:\nThanks for having me. Tell me about your timeline for the migration."))

        let answer = requests[1].body
        #expect(answer["model"] as? String == HintSettings.haiku)
        #expect(answer["stream"] as? Bool == true)
        #expect((answer["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        let messages = try #require(answer["messages"] as? [[String: Any]])
        let prompt = try #require(messages.last?["content"] as? String)
        #expect(prompt.contains("The migration is planned for March."))
        #expect(prompt.contains("Meeting: Migration sync"))
        #expect(prompt.contains("Ask about the staging database."))
        #expect(prompt.contains("[00:01] Me: Hi, thanks for joining."))
        #expect(prompt.contains("[00:52] Them: Tell me about your timeline for the migration."))
        #expect(prompt.hasSuffix("They just said: Thanks for having me. Tell me about your timeline for the migration."))
    }
}

/// Every snapshot the hints published.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [HintsSnapshot] = []

    func add(_ snapshot: HintsSnapshot) { lock.withLock { all.append(snapshot) } }

    /// The first snapshot that matches, waiting up to 5 s.
    func waitFor(_ match: (HintsSnapshot) -> Bool) async -> HintsSnapshot? {
        for _ in 0..<100 {
            if let found = lock.withLock({ all.first(where: match) }) { return found }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

/// OpenRouter on this Mac: the judge says yes (0.9), the answer streams in three pieces
/// with a keep-alive comment between them, as the real API does.
final class OpenRouterStub: URLProtocol, @unchecked Sendable {
    struct Request {
        var path: String
        var auth: String?
        var body: [String: Any]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Request] = []
    static var requests: [Request] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = (try? JSONSerialization.jsonObject(with: Self.body(of: request))) as? [String: Any] ?? [:]
        Self.lock.withLock {
            Self.recorded.append(Request(path: path, auth: request.value(forHTTPHeaderField: "Authorization"), body: body))
        }
        if path.hasSuffix("alpha/decisions") {
            respond(#"{"model":"baseten/bison-1","answers":{"reply":{"type":"noul","noul":0.9}}}"#, type: "application/json")
        } else {
            let pieces = ["We plan it", " for March,", " in two phases."].map { piece in
                let chunk = ["choices": [["delta": ["content": piece]]]]
                return "data: " + String(data: try! JSONSerialization.data(withJSONObject: chunk), encoding: .utf8)! + "\n\n"
            }
            respond(pieces[0] + ": OPENROUTER PROCESSING\n\n" + pieces[1] + pieces[2] + "data: [DONE]\n\n",
                    type: "text/event-stream")
        }
    }

    private func respond(_ text: String, type: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Inside a URLProtocol the body comes as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
