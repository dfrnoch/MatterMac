import Foundation
public import MatterMacCore

/// Claude through the Anthropic API (`POST https://api.anthropic.com/v1/messages`) with
/// the user's own API key. The conversation text of each request is sent to Anthropic;
/// the user opts in by choosing this provider. Same session rules as every other
/// connection: ephemeral, no cache, no cookies, no stored credentials.
public final class ClaudeAPIAssistant: AssistantProvider {
    public enum Model: String, CaseIterable, Identifiable, Sendable {
        case opus = "claude-opus-5-5"
        case sonnet = "claude-sonnet-5-5"
        case haiku = "claude-haiku-5-5"

        public var id: String { rawValue }
        /// Server-side fallback on a safety decline (not offered for Haiku).
        var supportsDefaultFallback: Bool { self != .haiku }
    }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let maximumResponseBytes = 1 * 1_048_576

    /// Far below the model's context; a day of chat fits in one request.
    public let maximumInputCharacters = 400_000
    private let summaryModel: Model
    private let key: KeychainSecret
    private let session: URLSession

    /// Reply suggestions always use Haiku 5.5 (fast, many requests) and learning the
    /// user's writing style uses Sonnet 5.5 (one careful request); `summaryModel` is
    /// the user's choice for thread and day summaries.
    public init(summaryModel: Model, key: KeychainSecret = .claudeAPIKey) {
        self.summaryModel = summaryModel
        self.key = key
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    static func model(for task: AssistantTask, summaryModel: Model) -> Model {
        switch task {
        case .reply: .haiku
        case .style: .sonnet
        case .summary: summaryModel
        }
    }

    /// The request body for a task. Thinking is on for these models and is steered
    /// with `effort`: low for a quick reply, medium for summaries and style notes.
    static func body(for request: AssistantRequest, model: Model) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": request.task == .reply ? 4_000 : 16_000,
            "system": request.instructions,
            "output_config": ["effort": request.task == .reply ? "low" : "medium"],
            "messages": [["role": "user", "content": request.input]],
        ]
        if model.supportsDefaultFallback { body["fallbacks"] = "default" }
        return body
    }

    /// The answer text of a Messages response, or why there is none.
    static func answer(from data: Data) -> Result<String, AssistantError> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.failed(code: 200))
        }
        if object["stop_reason"] as? String == "refusal" { return .failure(.refused) }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? .failure(.failed(code: 200)) : .success(text)
    }

    public func respond(to request: AssistantRequest) async throws(AssistantError) -> String {
        guard let apiKey = key.read() else { throw .notConfigured }
        let model = Self.model(for: request.task, summaryModel: summaryModel)
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if model.supportsDefaultFallback {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        guard let body = try? JSONSerialization.data(withJSONObject: Self.body(for: request, model: model)) else {
            throw .failed(code: 0)
        }
        urlRequest.httpBody = body
        let data: Data
        let status: Int
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw AssistantError.network }
            status = http.statusCode
            var received = Data()
            // Error bodies are never read into the UI; only successful answers are kept.
            if (200..<300).contains(status) {
                for try await byte in bytes {
                    received.append(byte)
                    if received.count > Self.maximumResponseBytes { throw AssistantError.failed(code: 200) }
                }
            }
            data = received
        } catch let error as AssistantError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw .cancelled
            case .timedOut: throw .timedOut
            default: throw .network
            }
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network
        }
        switch status {
        case 200..<300: return try Self.answer(from: data).get()
        case 401, 403: throw .invalidCredentials
        case 413: throw .inputTooLong
        case 429: throw .rateLimited
        default: throw .failed(code: status)
        }
    }
}
