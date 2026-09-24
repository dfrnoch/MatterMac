public import Foundation
public import MattermostAPI

/// One received WebSocket data frame.
public enum WebSocketFrame: Sendable {
    case text(String)
    /// Mattermost servers never send binary frames to clients; they are counted and
    /// discarded by the client.
    case binary(Data)

    /// Size used for budget accounting (UTF-8 bytes for text).
    public var byteCount: Int {
        switch self {
        case .text(let text): text.utf8.count
        case .binary(let data): data.count
        }
    }
}

/// Transport-level WebSocket failure. Never carries URLs, headers, or payload text.
public enum WebSocketTransportError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The HTTP upgrade was answered with a non-101 status (e.g. 401, 403). Redirects
    /// are refused and surface here with their 3xx status.
    case handshakeRejected(statusCode: Int)
    /// A received message exceeded `maximumMessageSize`. The socket is unusable.
    case messageTooLarge
    /// The peer closed the socket (close frame or TCP close). `code` is the WebSocket
    /// close code when one was received.
    case closed(code: Int?)
    /// Network-level failure (offline, DNS, TLS, reset, timeout).
    case network(TransportFailure)
    /// The operation was cancelled locally (task cancellation or `close()`).
    case cancelled

    public var description: String {
        switch self {
        case .handshakeRejected(let status): "handshakeRejected(\(status))"
        case .messageTooLarge: "messageTooLarge"
        case .closed(let code): "closed(\(code.map(String.init) ?? "-"))"
        case .network(let failure): "network(\(failure))"
        case .cancelled: "cancelled"
        }
    }
}

/// An open WebSocket. Owned by exactly one socket task of the realtime client.
///
/// Lifetime: the channel owns its underlying resources (for the URLSession
/// implementation: one `URLSession`, its delegate, and one task). `close()` releases
/// them; it is idempotent and also invoked from `deinit` of the concrete type.
public protocol WebSocketChannel: AnyObject, Sendable {
    /// Sends one text frame. Suspends until the frame is handed to the connection.
    func send(text: String) async throws(WebSocketTransportError)
    /// Receives the next data frame. Throws once the socket is closed or failed.
    /// Protocol control frames (ping/pong/close) are handled by the transport.
    func receive() async throws(WebSocketTransportError) -> WebSocketFrame
    /// Closes the socket and releases transport resources. Pending `receive`/`send`
    /// calls fail. Idempotent.
    func close()
}

/// Opens authenticated WebSocket connections. Injected into the realtime client so
/// protocol and recovery logic can be tested with a scripted server.
public protocol WebSocketTransport: Sendable {
    /// Performs the HTTP upgrade and returns once the socket is open.
    ///
    /// - Parameters:
    ///   - url: `ws`/`wss` URL (already contains any resume query items).
    ///   - headers: request headers (e.g. `Authorization`). Implementations must not
    ///     log, persist, or forward them across origins, and must not add cookies.
    ///   - maximumMessageSize: receive ceiling for a single message in bytes.
    func connect(url: URL, headers: [String: String], maximumMessageSize: Int)
        async throws(WebSocketTransportError) -> any WebSocketChannel
}
