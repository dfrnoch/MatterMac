public import Foundation
public import MatterMacModels
public import MattermostAPI
import Network
import os

/// A minimal HTTP/1.1 server on 127.0.0.1 (ephemeral port) for exercising the real
/// `URLSessionTransport` in tests: bounded reading, decompression, redirects,
/// cookies, uploads and downloads. Test-only; never linked into the app.
///
/// Every response is sent with `Connection: close`. Request bodies are counted in
/// full but only the first `bodyCaptureLimit` bytes are retained.
public final class LocalHTTPServer: Sendable {
    public struct Request: Sendable {
        public let method: String
        /// Raw request target (percent-encoded path plus optional `?query`).
        public let target: String
        public let headers: HTTPHeaders
        public let bodyLength: Int
        /// Up to `bodyCaptureLimit` leading body bytes.
        public let body: Data

        public var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
        public var query: [URLQueryItem] {
            URLComponents(string: "http://h" + target)?.queryItems ?? []
        }
        public func queryValue(_ name: String) -> String? { query.first { $0.name == name }?.value }
    }

    public struct Response: Sendable {
        public enum Body: Sendable {
            case data(Data)
            /// `count` zero bytes produced on the fly in `chunk`-sized writes (with a
            /// Content-Length header).
            case generated(count: Int, chunk: Int)
            /// Chunked transfer encoding (no Content-Length), optional pause between chunks.
            case chunked([Data], pause: Duration?)
            /// Sends the head, then waits `Duration` before sending the body.
            indirect case delayed(Duration, Body)
            /// Reads the request but never answers (until the client gives up).
            case hang
        }

        public var status: Int
        public var headers: HTTPHeaders
        public var body: Body

        public init(status: Int, headers: HTTPHeaders = HTTPHeaders(), body: Body = .data(Data())) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func json(_ text: String, status: Int = 200, headers: HTTPHeaders = HTTPHeaders()) -> Response {
            var headers = headers
            if !headers.contains("Content-Type") { headers.set("Content-Type", "application/json") }
            return Response(status: status, headers: headers, body: .data(Data(text.utf8)))
        }

        public static func redirect(_ status: Int = 302, to location: String) -> Response {
            Response(status: status, headers: ["Location": location])
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    private struct State: Sendable {
        var requests: [Request] = []
        var connections: [NWConnection] = []
        var readThrottle: (bytes: Int, pause: Duration)?
        var stopped = false
    }

    public static let bodyCaptureLimit = 256 * 1_024
    public static let maximumRecordedRequests = 1_000

    public let port: UInt16
    private let listener: NWListener
    private let handler: Handler
    private let queue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue, handler: @escaping Handler) {
        self.listener = listener
        self.port = port
        self.queue = queue
        self.handler = handler
    }

    /// Starts listening on 127.0.0.1 with an ephemeral port.
    public static func start(handler: @escaping Handler) async throws -> LocalHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "TestSupport.LocalHTTPServer")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let first: Bool
                switch state {
                case .ready, .failed, .cancelled:
                    first = resumed.withLock { value -> Bool in
                        defer { value = true }
                        return !value
                    }
                default:
                    first = false
                }
                guard first else { return }
                switch state {
                case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                default: continuation.resume(throwing: CancellationError())
                }
            }
            listener.newConnectionHandler = { connection in connection.cancel() }
            listener.start(queue: queue)
        }
        let server = LocalHTTPServer(listener: listener, port: port, queue: queue, handler: handler)
        listener.newConnectionHandler = { [weak server] connection in
            guard let server else {
                connection.cancel()
                return
            }
            server.accept(connection)
        }
        return server
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// A loopback endpoint for this server (plain HTTP; loopback only).
    public func endpoint(pathSegments: [String] = []) -> ServerEndpoint {
        ServerEndpoint(scheme: .http, host: "127.0.0.1", port: Int(port), pathSegments: pathSegments)
    }

    public var requests: [Request] { state.withLock { $0.requests } }

    /// Reads request bodies at most `bytes` at a time with `pause` between reads.
    public func setReadThrottle(bytes: Int, pause: Duration) {
        state.withLock { $0.readThrottle = (max(1, bytes), pause) }
    }

    public func stop() {
        let connections = state.withLock { state -> [NWConnection] in
            state.stopped = true
            defer { state.connections = [] }
            return state.connections
        }
        listener.cancel()
        for connection in connections { connection.cancel() }
    }

    deinit { listener.cancel() }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        let accepted = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.connections.removeAll { $0.state == .cancelled }
            state.connections.append(connection)
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        Task { await self.serve(connection) }
    }

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        var buffer = Data()
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            guard let chunk = await Self.receive(connection, maximum: 64 * 1_024) else { return }
            buffer.append(chunk)
            headEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headEnd == nil, buffer.count > 64 * 1_024 { return }
        }
        guard let headEnd else { return }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var remainder = Data(buffer[headEnd.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return }
        var headers = HTTPHeaders()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.add(String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }

        var captured = Data()
        var total = 0
        let throttle = state.withLock { $0.readThrottle }
        func consume(_ data: Data) {
            total += data.count
            if captured.count < Self.bodyCaptureLimit { captured.append(data.prefix(Self.bodyCaptureLimit - captured.count)) }
        }
        if let lengthText = headers["Content-Length"], let length = Int(lengthText) {
            let initial = remainder.prefix(length)
            consume(initial)
            while total < length {
                if let throttle { try? await Task.sleep(for: throttle.pause) }
                let want = min(length - total, throttle?.bytes ?? 256 * 1_024)
                guard let chunk = await Self.receive(connection, maximum: want) else { break }
                consume(chunk)
            }
        } else if headers["Transfer-Encoding"]?.lowercased().contains("chunked") == true {
            // Minimal chunked decoder.
            while true {
                while remainder.range(of: Data("\r\n".utf8)) == nil {
                    guard let chunk = await Self.receive(connection, maximum: 64 * 1_024) else { return }
                    remainder.append(chunk)
                }
                guard let lineEnd = remainder.range(of: Data("\r\n".utf8)) else { return }
                let sizeLine = String(decoding: remainder[remainder.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                let size = Int(sizeLine.split(separator: ";").first.map(String.init) ?? "", radix: 16) ?? 0
                remainder = Data(remainder[lineEnd.upperBound...])
                while remainder.count < size + 2 {
                    guard let chunk = await Self.receive(connection, maximum: 64 * 1_024) else { return }
                    remainder.append(chunk)
                }
                consume(remainder.prefix(size))
                remainder = Data(remainder.dropFirst(size + 2))
                if size == 0 { break }
            }
        }

        let request = Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers,
                              bodyLength: total, body: captured)
        state.withLock { state in
            if state.requests.count < Self.maximumRecordedRequests { state.requests.append(request) }
        }
        let response = await handler(request)
        await write(response, to: connection)
    }

    private func write(_ response: Response, to connection: NWConnection) async {
        var headers = response.headers
        headers.set("Connection", "close")
        var body = response.body
        var headDelay: Duration?
        if case .delayed(let delay, let inner) = body {
            headDelay = delay
            body = inner
        }
        switch body {
        case .data(let data): headers.set("Content-Length", String(data.count))
        case .generated(let count, _): headers.set("Content-Length", String(count))
        case .chunked: headers.set("Transfer-Encoding", "chunked")
        case .hang:
            try? await Task.sleep(for: .seconds(3_600))
            return
        case .delayed: break
        }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for field in headers { head += "\(field.name): \(field.value)\r\n" }
        head += "\r\n"
        guard await Self.send(connection, Data(head.utf8)) else { return }
        if let headDelay { try? await Task.sleep(for: headDelay) }
        switch body {
        case .data(let data):
            if !data.isEmpty { _ = await Self.send(connection, data) }
        case .generated(let count, let chunkSize):
            let chunk = Data(count: max(1, chunkSize))
            var sent = 0
            while sent < count {
                let piece = min(chunk.count, count - sent)
                guard await Self.send(connection, piece == chunk.count ? chunk : chunk.prefix(piece)) else { return }
                sent += piece
            }
        case .chunked(let parts, let pause):
            for part in parts where !part.isEmpty {
                var frame = Data("\(String(part.count, radix: 16))\r\n".utf8)
                frame.append(part)
                frame.append(Data("\r\n".utf8))
                guard await Self.send(connection, frame) else { return }
                if let pause { try? await Task.sleep(for: pause) }
            }
            _ = await Self.send(connection, Data("0\r\n\r\n".utf8))
        case .hang, .delayed:
            return
        }
        await Self.finish(connection)
    }

    private static func receive(_ connection: NWConnection, maximum: Int) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private static func finish(_ connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    // MARK: Gzip (for decompression-bound tests)

    /// Encodes `data` as a gzip member (RFC 1952) using Foundation's raw DEFLATE.
    public static func gzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
