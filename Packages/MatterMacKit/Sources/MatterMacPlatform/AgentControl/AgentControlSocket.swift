public import Foundation
import os

/// Local control channel for command-line agents: a Unix domain socket inside the
/// app's own container, readable and writable by the user only. One JSON request per
/// connection (the client closes its sending side), one JSON response back. Nothing
/// listens unless the user turned agent control on.
public enum AgentControl {
    /// In the sandbox this is the container's data folder, the shortest stable path
    /// both the app and its `agent` command-line mode resolve the same way.
    public static var socketPath: String { NSHomeDirectory() + "/agent.sock" }
    public static let maximumRequestBytes = 256 * 1_024
    public static let maximumResponseBytes = 4 * 1_048_576

    public enum ClientError: Error, Hashable, Sendable {
        /// No app is listening (not running, or agent control is off).
        case notRunning
        case pathTooLong
        case failed
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return address
    }

    static func connected(to path: String) -> Result<Int32, ClientError> {
        guard var address = address(path) else { return .failure(.pathTooLong) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(.failed) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            return .failure(code == ENOENT || code == ECONNREFUSED ? .notRunning : .failed)
        }
        guard configure(descriptor, receiveSeconds: 0, sendSeconds: 10) else {
            close(descriptor)
            return .failure(.failed)
        }
        return .success(descriptor)
    }

    /// No SIGPIPE on a vanished peer; bounded waits (0: wait indefinitely). `false`
    /// when the peer is already gone (macOS then refuses socket options): the caller
    /// must not write to such a socket.
    @discardableResult
    static func configure(_ descriptor: Int32, receiveSeconds: Int, sendSeconds: Int) -> Bool {
        var on: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }
        var receive = timeval(tv_sec: receiveSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))
        var send = timeval(tv_sec: sendSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
        return true
    }

    /// Reads until the peer closes its sending side; `nil` on error, timeout or overflow.
    static func readAll(_ descriptor: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(buffer, count: count)
            if data.count > limit { return nil }
        }
    }

    @discardableResult
    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
    }

    /// One request to the running app. Blocks until the response is complete.
    public static func request(_ data: Data, path: String = socketPath) -> Result<Data, ClientError> {
        guard data.count <= maximumRequestBytes else { return .failure(.failed) }
        let descriptor: Int32
        switch connected(to: path) {
        case .success(let value): descriptor = value
        case .failure(let error): return .failure(error)
        }
        defer { close(descriptor) }
        guard writeAll(descriptor, data), shutdown(descriptor, SHUT_WR) == 0,
              let response = readAll(descriptor, limit: maximumResponseBytes), !response.isEmpty else {
            return .failure(.failed)
        }
        return .success(response)
    }
}

/// The app's side of the socket. Accepts on its own thread; each request is answered
/// by `handler` (which hops to the main actor) and the connection closed.
public final class AgentControlServer: Sendable {
    public enum StartError: Error, Hashable, Sendable {
        case pathTooLong
        /// Another running copy of the app already answers on this socket.
        case inUse
        case system(Int32)
    }

    public typealias Handler = @Sendable (Data) async -> Data
    static let maximumConnections = 8

    private let path: String
    private let handler: Handler
    private let listener = OSAllocatedUnfairLock<Int32?>(initialState: nil)
    private let connections = OSAllocatedUnfairLock(initialState: 0)

    public init(path: String = AgentControl.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool { listener.withLock { $0 != nil } }

    public func start() throws(StartError) {
        guard !isRunning else { return }
        guard var address = AgentControl.address(path) else { throw .pathTooLong }
        if case .success(let other) = AgentControl.connected(to: path) {
            close(other)
            throw .inUse
        }
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .system(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw .system(code)
        }
        listener.withLock { $0 = descriptor }
        let handler = handler, listener = listener, connections = connections
        let thread = Thread { Self.acceptLoop(descriptor, listener: listener, connections: connections, handler: handler) }
        thread.name = "MatterMac agent control"
        thread.start()
    }

    public func stop() {
        guard listener.withLock({ state -> Bool in
            defer { state = nil }
            return state != nil
        }) else { return }
        // Wake the accept loop; it sees the cleared state and closes the listener.
        if case .success(let wake) = AgentControl.connected(to: path) { close(wake) }
        unlink(path)
    }

    private static func acceptLoop(_ descriptor: Int32, listener: OSAllocatedUnfairLock<Int32?>,
                                   connections: OSAllocatedUnfairLock<Int>, handler: @escaping Handler) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard listener.withLock({ $0 }) == descriptor else {
                if client >= 0 { close(client) }
                close(descriptor)
                return
            }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                listener.withLock { $0 = nil }
                close(descriptor)
                return
            }
            var user: uid_t = 0
            var group: gid_t = 0
            let admitted = AgentControl.configure(client, receiveSeconds: 2, sendSeconds: 10)
                && getpeereid(client, &user, &group) == 0 && user == getuid() && connections.withLock { count in
                guard count < maximumConnections else { return false }
                count += 1
                return true
            }
            guard admitted else {
                close(client)
                continue
            }
            guard let request = AgentControl.readAll(client, limit: AgentControl.maximumRequestBytes) else {
                close(client)
                connections.withLock { $0 -= 1 }
                continue
            }
            Task {
                let response = await handler(request)
                AgentControl.writeAll(client, response)
                close(client)
                connections.withLock { $0 -= 1 }
            }
        }
    }
}
