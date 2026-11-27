import Foundation

/// Why a hint request gave nothing. The app turns each into a line of interface text.
public enum HintError: Error, Equatable, Sendable {
    /// HTTP 401/403.
    case keyRejected
    /// HTTP 402.
    case noCredits
    /// HTTP 404, or 400 about the model.
    case unknownModel(String)
    /// HTTP 429, 5xx, or an answer that could not be read.
    case busy
    /// No network, or the request timed out.
    case offline
    /// The saved key could not be read.
    case keyUnavailable

    /// A short tag for the log.
    public var tag: String {
        switch self {
        case .keyRejected: return "key_rejected"
        case .noCredits: return "no_credits"
        case .unknownModel: return "unknown_model"
        case .busy: return "busy"
        case .offline: return "offline"
        case .keyUnavailable: return "key_unavailable"
        }
    }
}

/// The two requests behind a hint, both to OpenRouter with the owner's key: a decision
/// model's probability of "yes" (the Decisions API) and a streamed chat answer.
public struct OpenRouterClient: Sendable {
    public var session: URLSession
    public var baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = URL(string: "https://openrouter.ai/api")!) {
        self.session = session
        self.baseURL = baseURL
    }

    /// One yes/no question about `state`; returns the probability of "yes" (0…1).
    public func judge(model: String, state: String, instructions: String, yes: String, no: String,
                      key: String) async throws -> Double {
        let body: [String: Any] = [
            "model": model,
            "state": state,
            "questions": ["reply": [
                "type": "noul",
                "instructions": instructions,
                "criteria": ["true": yes, "false": no],
            ]],
        ]
        let request = try self.request("alpha/decisions", body: body, key: key, timeout: 15)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.error(from: error)
        }
        try Self.check(response, body: data, model: model)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any],
              let reply = answers["reply"] as? [String: Any],
              let probability = (reply["noul"] as? NSNumber)?.doubleValue else { throw HintError.busy }
        return probability
    }

    /// A chat answer, piece by piece as the model writes it.
    public func answer(model: String, system: String, user: String, maxTokens: Int = 1024,
                       key: String) -> AsyncThrowingStream<String, Error> {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_completion_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        // A hint must start at once: no thinking where the model allows that, the least otherwise.
        if model.hasPrefix(HintSettings.haiku) {
            body["reasoning"] = ["effort": "none"]
        } else if model.hasPrefix(HintSettings.sonnet) {
            body["reasoning"] = ["effort": "low"]
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.request("v1/chat/completions", body: body, key: key, timeout: 30)
                    let (bytes, response) = try await session.bytes(for: request)
                    if (response as? HTTPURLResponse)?.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count >= 4096 { break }
                        }
                        try Self.check(response, body: data, model: model)
                    }
                    for try await line in bytes.lines {
                        // Comment lines (": OPENROUTER PROCESSING") and blank lines carry nothing.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
                        else { continue }
                        if object["error"] != nil { throw HintError.busy }
                        if let choices = object["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.error(from: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request(_ path: String, body: [String: Any], key: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Throws for every status but 200.
    private static func check(_ response: URLResponse, body: Data, model: String) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw HintError.busy }
        if status != 200 {
            // The status only: error bodies are not logged.
            Log.event("hint.http", "path=\(response.url?.path ?? "") status=\(status)")
        }
        switch status {
        case 200: return
        case 401, 403: throw HintError.keyRejected
        case 402: throw HintError.noCredits
        case 404: throw HintError.unknownModel(model)
        case 400:
            let text = String(data: body, encoding: .utf8)?.lowercased() ?? ""
            throw text.contains("model") ? HintError.unknownModel(model) : HintError.busy
        default: throw HintError.busy
        }
    }

    /// A cancelled request stays a cancellation; the rest become a `HintError`.
    private static func error(from error: Error) -> Error {
        if error is CancellationError { return error }
        if let hint = error as? HintError { return hint }
        if let url = error as? URLError {
            return url.code == .cancelled ? CancellationError() : HintError.offline
        }
        return HintError.busy
    }
}
