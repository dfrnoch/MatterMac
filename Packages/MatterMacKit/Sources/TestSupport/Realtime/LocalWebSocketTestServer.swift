public import Foundation
import Network
import os

/// An in-process loopback WebSocket server (Network.framework) for exercising the
/// real `URLSessionWebSocketTransport` without a Mattermost server: header
/// inspection, text frames, protocol pings (pong counting), oversized messages,
/// server close, and a raw HTTP rejection of the upgrade. Binds 127.0.0.1 only.
public final class LocalWebSocketTestServer: Sendable {
    public enum Mode: Sendable {
        case webSocket
        /// Answers the upgrade request with this HTTP status and closes.
        case rejectUpgrade(status: Int)
        /// Accepts TCP and never answers (handshake hang).
        case silent
    }

    public struct Snapshot: Sendable {
        /// Request header names (lowercased) seen on upgrades.
        public var headerNames: Set<String> = []
        /// `Authorization` values seen (tests only use synthetic credentials).
        public var authorizationValues: [String] = []
        public var receivedTexts: [String] = []
        public var pongs = 0
        public var connections = 0
    }

    private struct State {
        var connections: [NWConnection] = []
        var snapshot = Snapshot()
    }

    public let mode: Mode
    private let queue = DispatchQueue(label: "mattermac.test.websocket-server")
    private let listener: NWListener
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(mode: Mode = .webSocket) throws {
        self.mode = mode
        let parameters: NWParameters
        switch mode {
        case .webSocket:
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        case .rejectUpgrade, .silent:
            parameters = NWParameters.tcp
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        if case .webSocket = mode {
            options(of: parameters)?.setClientRequestHandler(queue) { [state] _, headers in
                state.withLock { state in
                    for header in headers {
                        state.snapshot.headerNames.insert(header.name.lowercased())
                        if header.name.lowercased() == "authorization" {
                            state.snapshot.authorizationValues.append(header.value)
                        }
                    }
                }
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
        }
    }

    private func options(of parameters: NWParameters) -> NWProtocolWebSocket.Options? {
        parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolWebSocket.Options
    }

    /// Starts listening and returns the bound port.
    public func start() async throws -> Int {
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (Result<Int, any Error>) -> Void = { result in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { [listener] newState in
                switch newState {
                case .ready: resumeOnce(.success(Int(listener.port?.rawValue ?? 0)))
                case .failed(let error): resumeOnce(.failure(error))
                case .cancelled: resumeOnce(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
        return port
    }

    public func url(port: Int, path: String = "/api/v4/websocket") -> URL {
        URL(string: "ws://127.0.0.1:\(port)\(path)")!
    }

    public var snapshot: Snapshot { state.withLock { $0.snapshot } }

    /// Sends a text frame to every open connection.
    public func send(text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        for connection in state.withLock({ $0.connections }) {
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }

    /// Sends a protocol Ping frame to every open connection; pongs are counted.
    public func sendPing() {
        for connection in state.withLock({ $0.connections }) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(queue) { [state] error in
                if error == nil { state.withLock { $0.snapshot.pongs += 1 } }
            }
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
            connection.send(content: Data(), contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }

    /// Sends a close frame (code 1000) and cancels every connection.
    public func closeAll() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        for connection in state.withLock({ $0.connections }) {
            connection.send(content: nil, contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    public func stop() {
        let connections = state.withLock { state in
            defer { state.connections.removeAll() }
            return state.connections
        }
        for connection in connections { connection.cancel() }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { state in
            state.connections.append(connection)
            state.snapshot.connections += 1
        }
        connection.start(queue: queue)
        switch mode {
        case .webSocket:
            receive(on: connection)
        case .rejectUpgrade(let status):
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                let response = "HTTP/1.1 \(status) Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        case .silent:
            break
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else { return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .text, let content {
                let text = String(decoding: content, as: UTF8.self)
                state.withLock { $0.snapshot.receivedTexts.append(text) }
            }
            receive(on: connection)
        }
    }
}
