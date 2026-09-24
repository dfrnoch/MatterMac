public import Foundation
public import MattermostAPI
import os

/// A scripted `HTTPTransport` for tests: captures every request, answers from a
/// responder closure or a FIFO script, supports delays on an injected clock and
/// requests that hang until cancelled, and honours the transport contract (body
/// limits, error-body limit, chunked download writes, cancellation → `.cancelled`,
/// `.cancelled` after `shutdown()`).
public final class FakeHTTPTransport: HTTPTransport {
    public indirect enum Reply: Sendable {
        case response(HTTPResponse)
        case failure(APIError)
        /// Waits `Duration` on the transport's clock, then replies.
        case delayed(Duration, Reply)
        /// Never replies; throws `.cancelled` when the calling task is cancelled.
        case suspendUntilCancelled

        /// A response with a UTF-8 body (JSON by default).
        public static func status(_ code: Int, _ body: String = "", headers: HTTPHeaders = HTTPHeaders()) -> Reply {
            var headers = headers
            if !headers.contains("Content-Type") { headers.set("Content-Type", "application/json") }
            return .response(HTTPResponse(statusCode: code, headers: headers, body: Data(body.utf8)))
        }

        public static func json(_ body: String, status: Int = 200, headers: HTTPHeaders = HTTPHeaders()) -> Reply {
            .status(status, body, headers: headers)
        }

        public static func data(_ body: Data, status: Int = 200, contentType: String) -> Reply {
            .response(HTTPResponse(statusCode: status, headers: ["Content-Type": contentType], body: body))
        }

        /// A Mattermost AppError body.
        public static func appError(_ status: Int, id: String, headers: HTTPHeaders = HTTPHeaders()) -> Reply {
            .status(status, #"{"id":"\#(id)","message":"m","detailed_error":"","request_id":"rid","status_code":\#(status)}"#,
                    headers: headers)
        }
    }

    public enum Kind: Sendable, Hashable { case send, upload, download }

    public struct Captured: Sendable {
        public let kind: Kind
        public let request: HTTPRequest
        public let limits: ResponseLimits
        public let uploadFile: UploadFile?

        public var path: String { request.url.path(percentEncoded: true) }
        public var query: [URLQueryItem] {
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        }
        public func queryValue(_ name: String) -> String? { query.first { $0.name == name }?.value }
        public var bodyJSON: Any? { request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        public var bodyString: String? { request.body.map { String(decoding: $0, as: UTF8.self) } }
    }

    public typealias Responder = @Sendable (HTTPRequest) -> Reply

    private struct State: Sendable {
        var captured: [Captured] = []
        var script: [Reply] = []
        var inFlight = 0
        var maximumInFlight = 0
        var shutDown = false
        var shutdownCalls = 0
    }

    /// Captured requests are retained up to this count (test-only bound).
    public static let maximumCaptured = 10_000

    private let clock: any Clock<Duration>
    private let responder: Responder?
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Answers every request with `responder`.
    public init(clock: any Clock<Duration> = ContinuousClock(), responder: @escaping Responder) {
        self.clock = clock
        self.responder = responder
    }

    /// Answers requests in order from `script`; once exhausted, requests fail with
    /// `.notSent(.cannotConnect)`.
    public init(clock: any Clock<Duration> = ContinuousClock(), script: [Reply]) {
        self.clock = clock
        self.responder = nil
        state.withLock { $0.script = script }
    }

    public func enqueue(_ replies: Reply...) {
        state.withLock { $0.script.append(contentsOf: replies) }
    }

    public var requests: [Captured] { state.withLock { $0.captured } }
    public var requestCount: Int { state.withLock { $0.captured.count } }
    public var inFlight: Int { state.withLock { $0.inFlight } }
    public var maximumInFlight: Int { state.withLock { $0.maximumInFlight } }
    public var isShutDown: Bool { state.withLock { $0.shutDown } }
    public var shutdownCalls: Int { state.withLock { $0.shutdownCalls } }

    // MARK: HTTPTransport

    public func send(_ request: HTTPRequest, limits: ResponseLimits) async throws(APIError) -> HTTPResponse {
        let response = try await reply(for: Captured(kind: .send, request: request, limits: limits, uploadFile: nil))
        return try Self.bounded(response, limits: limits)
    }

    public func upload(_ request: HTTPRequest, file: UploadFile, limits: ResponseLimits,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> HTTPResponse {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value
        guard size == file.expectedLength else { throw .localFileUnavailable }
        let response = try await reply(for: Captured(kind: .upload, request: request, limits: limits, uploadFile: file))
        progress(TransferProgress(completedBytes: file.expectedLength, totalBytes: file.expectedLength))
        return try Self.bounded(response, limits: limits)
    }

    public func download(_ request: HTTPRequest, to handle: FileHandle, limits: ResponseLimits,
                         progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> HTTPResponse {
        let response = try Self.bounded(
            try await reply(for: Captured(kind: .download, request: request, limits: limits, uploadFile: nil)),
            limits: limits)
        guard response.isSuccess else { return response }
        let chunk = URLSessionTransport.maximumWriteChunkBytes
        var offset = 0
        while offset < response.body.count {
            let end = min(offset + chunk, response.body.count)
            do {
                try handle.write(contentsOf: response.body[response.body.startIndex + offset..<response.body.startIndex + end])
            } catch {
                throw .localFileUnavailable
            }
            offset = end
            progress(TransferProgress(completedBytes: Int64(offset), totalBytes: Int64(response.body.count)))
        }
        return HTTPResponse(statusCode: response.statusCode, headers: response.headers)
    }

    public func shutdown() async {
        state.withLock {
            $0.shutDown = true
            $0.shutdownCalls += 1
        }
    }

    // MARK: Internals

    private func reply(for captured: Captured) async throws(APIError) -> HTTPResponse {
        if Task.isCancelled { throw .cancelled }
        let scripted: Reply? = state.withLock { state in
            guard !state.shutDown else { return .failure(.cancelled) }
            if state.captured.count < Self.maximumCaptured { state.captured.append(captured) }
            state.inFlight += 1
            state.maximumInFlight = max(state.maximumInFlight, state.inFlight)
            if responder != nil { return nil }
            return state.script.isEmpty ? .failure(.notSent(.cannotConnect)) : state.script.removeFirst()
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        let reply = scripted ?? responder?(captured.request) ?? .failure(.notSent(.cannotConnect))
        return try await resolve(reply)
    }

    private func resolve(_ reply: Reply) async throws(APIError) -> HTTPResponse {
        switch reply {
        case .response(let response):
            if Task.isCancelled { throw .cancelled }
            return response
        case .failure(let error):
            throw error
        case .delayed(let duration, let next):
            do {
                try await clock.sleep(for: duration)
            } catch {
                throw .cancelled
            }
            return try await resolve(next)
        case .suspendUntilCancelled:
            do {
                // Sleeps "forever" on a real clock; cancellation ends it.
                try await ContinuousClock().sleep(for: .seconds(86_400 * 365))
            } catch {
                throw .cancelled
            }
            throw .cancelled
        }
    }

    /// Applies the transport's size contract to a scripted response.
    static func bounded(_ response: HTTPResponse, limits: ResponseLimits) throws(APIError) -> HTTPResponse {
        if response.isSuccess {
            guard Int64(response.body.count) <= limits.maximumBodyBytes else {
                throw .responseTooLarge(limitBytes: Int(clamping: limits.maximumBodyBytes))
            }
            return response
        }
        guard response.body.count <= limits.maximumErrorBodyBytes else {
            return HTTPResponse(statusCode: response.statusCode, headers: response.headers, body: Data(), bodyDiscarded: true)
        }
        return response
    }
}
