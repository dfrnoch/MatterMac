public import Foundation
import MattermostAPI
import os

/// Production `WebSocketTransport` built on `URLSessionWebSocketTask`.
///
/// Privacy (SPEC §7): every connection uses its own ephemeral `URLSession` with the
/// URL cache, cookie storage, cookie handling, and credential storage disabled. A
/// stale `MMAUTHTOKEN` cookie would otherwise take precedence over the
/// `Authorization` header on the upgrade (server `ParseAuthTokenFromRequest`).
/// Redirects on the upgrade are refused, so the credential header is never replayed
/// to another URL.
///
/// Lifetimes: `URLSession` retains its delegate strongly until the session is
/// invalidated. Each channel owns exactly one session, one delegate, and one task;
/// `close()` (also run from `deinit`, and on cancellation of a pending `send` or
/// `receive`) cancels the task and calls `invalidateAndCancel()`, after which the
/// session releases the delegate. The delegate holds no reference to the channel,
/// the session, or the client, so there is no retain cycle.
///
/// Verified behaviour (macOS 27 SDK, see docs/research/websocket.md):
/// - a non-101 upgrade answer fails with `NSURLErrorBadServerResponse` and the task's
///   `response` carries the HTTP status; it is surfaced as `.handshakeRejected`;
/// - a message above `maximumMessageSize` fails `receive()` with POSIX `EMSGSIZE`
///   and the task is dead afterwards; surfaced as `.messageTooLarge`;
/// - `timeoutIntervalForRequest` bounds the handshake only, not idle receives;
/// - protocol Ping frames from the server are answered automatically while a
///   `receive()` is outstanding (the client keeps one outstanding at all times).
public struct URLSessionWebSocketTransport: WebSocketTransport {
    /// Upper bound for the HTTP upgrade (TCP + TLS + 101), in seconds.
    public var handshakeTimeout: TimeInterval

    public init(handshakeTimeout: TimeInterval = 30) {
        self.handshakeTimeout = handshakeTimeout
    }

    /// The hardened session configuration used for every socket.
    public static func makeConfiguration(handshakeTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = handshakeTimeout
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    public func connect(url: URL, headers: [String: String], maximumMessageSize: Int)
        async throws(WebSocketTransportError) -> any WebSocketChannel
    {
        if Task.isCancelled { throw .cancelled }
        let delegate = WebSocketSessionDelegate()
        let session = URLSession(configuration: Self.makeConfiguration(handshakeTimeout: handshakeTimeout),
                                 delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: handshakeTimeout)
        request.httpShouldHandleCookies = false
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = max(1, maximumMessageSize)
        let channel = URLSessionWebSocketChannel(session: session, task: task, delegate: delegate)

        let outcome = await withTaskCancellationHandler {
            await delegate.waitForOpen { task.resume() }
        } onCancel: {
            delegate.finishOpen(.failure(.cancelled))
        }
        switch outcome {
        case .success:
            return channel
        case .failure(let error):
            channel.close()
            throw error
        }
    }
}

/// Session delegate for exactly one WebSocket task. Holds only its own lock-protected
/// open state; never references the session, task, channel, or client.
final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private enum OpenState {
        case idle
        case waiting(CheckedContinuation<Result<Void, WebSocketTransportError>, Never>)
        case finished(Result<Void, WebSocketTransportError>)
    }

    private let openState = OSAllocatedUnfairLock<OpenState>(initialState: .idle)

    /// Registers the waiter, then runs `start` (which resumes the task). Returns when
    /// the socket opened or the handshake failed or was cancelled.
    func waitForOpen(start: @Sendable () -> Void) async -> Result<Void, WebSocketTransportError> {
        await withCheckedContinuation { continuation in
            let earlier: Result<Void, WebSocketTransportError>? = openState.withLock { state in
                switch state {
                case .idle:
                    state = .waiting(continuation)
                    return nil
                case .finished(let result):
                    return result
                case .waiting:
                    return .failure(.cancelled)
                }
            }
            if let earlier {
                continuation.resume(returning: earlier)
            } else {
                start()
            }
        }
    }

    /// Completes the open wait exactly once; later calls are ignored.
    func finishOpen(_ result: Result<Void, WebSocketTransportError>) {
        let waiter: CheckedContinuation<Result<Void, WebSocketTransportError>, Never>? = openState.withLock { state in
            switch state {
            case .idle:
                state = .finished(result)
                return nil
            case .waiting(let continuation):
                state = .finished(result)
                return continuation
            case .finished:
                return nil
            }
        }
        waiter?.resume(returning: result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        finishOpen(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Only meaningful before the open; afterwards the pending receive reports it.
        finishOpen(.failure(URLSessionWebSocketChannel.mapHandshake(error: error, response: task.response)))
    }

    /// Redirects on the upgrade are refused: the credential header must not follow.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// One open `URLSessionWebSocketTask` plus the session and delegate that serve it.
final class URLSessionWebSocketChannel: WebSocketChannel {
    let session: URLSession
    let task: URLSessionWebSocketTask
    let delegate: WebSocketSessionDelegate
    private let closedLocally = OSAllocatedUnfairLock(initialState: false)

    init(session: URLSession, task: URLSessionWebSocketTask, delegate: WebSocketSessionDelegate) {
        self.session = session
        self.task = task
        self.delegate = delegate
    }

    deinit {
        close()
    }

    func send(text: String) async throws(WebSocketTransportError) {
        let result: Result<Void, WebSocketTransportError> = await withTaskCancellationHandler {
            do {
                try await task.send(.string(text))
                return .success(())
            } catch {
                return .failure(mapFailure(error))
            }
        } onCancel: {
            close()
        }
        try result.get()
    }

    func receive() async throws(WebSocketTransportError) -> WebSocketFrame {
        let result: Result<WebSocketFrame, WebSocketTransportError> = await withTaskCancellationHandler {
            do {
                switch try await task.receive() {
                case .string(let text): return .success(.text(text))
                case .data(let data): return .success(.binary(data))
                @unknown default: return .failure(.closed(code: nil))
                }
            } catch {
                return .failure(mapFailure(error))
            }
        } onCancel: {
            close()
        }
        return try result.get()
    }

    func close() {
        let first = closedLocally.withLock { closed in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func mapFailure(_ error: any Error) -> WebSocketTransportError {
        if closedLocally.withLock({ $0 }) { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EMSGSIZE) { return .messageTooLarge }
        let closeCode = task.closeCode
        if closeCode != .invalid { return .closed(code: closeCode.rawValue) }
        if nsError.domain == NSPOSIXErrorDomain,
           [Int(ENOTCONN), Int(ECONNRESET), Int(EPIPE), Int(ECONNABORTED)].contains(nsError.code) {
            return .closed(code: nil)
        }
        return Self.mapHandshake(error: error, response: task.response)
    }

    /// Maps a failure that may have happened during the HTTP upgrade.
    static func mapHandshake(error: (any Error)?, response: URLResponse?) -> WebSocketTransportError {
        if let http = response as? HTTPURLResponse, http.statusCode != 101 {
            return .handshakeRejected(statusCode: http.statusCode)
        }
        guard let error else { return .closed(code: nil) }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(truncatingIfNeeded: nsError.code) {
            case EMSGSIZE: return .messageTooLarge
            case ENOTCONN, ECONNRESET, EPIPE, ECONNABORTED: return .closed(code: nil)
            case ETIMEDOUT: return .network(.timedOut)
            case ECONNREFUSED: return .network(.cannotConnect)
            default: return .network(.other(code: nsError.code))
            }
        }
        guard nsError.domain == NSURLErrorDomain else { return .network(.other(code: nsError.code)) }
        switch URLError.Code(rawValue: nsError.code) {
        case .cancelled: return .cancelled
        case .timedOut: return .network(.timedOut)
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .network(.offline)
        case .cannotConnectToHost: return .network(.cannotConnect)
        case .cannotFindHost, .dnsLookupFailed: return .network(.dnsFailure)
        case .networkConnectionLost: return .network(.connectionLost)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .network(.tlsFailure)
        default:
            return .network(.other(code: nsError.code))
        }
    }
}
