public import Foundation
public import MattermostRealtime
import os

/// A scripted `WebSocketTransport`. Every `connect` is recorded as an `Attempt`; the
/// next scripted behaviour (default `.accept`) decides whether it opens a
/// `FakeWebSocketChannel`, fails (e.g. handshake 401), or hangs until cancelled.
public final class FakeWebSocketTransport: WebSocketTransport, Sendable {
    public enum Behavior: Sendable {
        case accept
        case reject(WebSocketTransportError)
        /// Never completes; the attempt fails with `.cancelled` when its task is cancelled.
        case hang
    }

    public struct Attempt: Sendable {
        public let index: Int
        public let url: URL
        public let headers: [String: String]
        public let maximumMessageSize: Int
        /// The opened channel, for `.accept` attempts.
        public let channel: FakeWebSocketChannel?

        public var queryItems: [URLQueryItem] {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        }

        public func query(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        public var isResume: Bool { query("connection_id") != nil }
    }

    private struct State {
        var attempts: [Attempt] = []
        var script: [Behavior] = []
        var defaultBehavior: Behavior
        var autoReplyPings = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(defaultBehavior: Behavior = .accept) {
        state = OSAllocatedUnfairLock(initialState: State(defaultBehavior: defaultBehavior))
    }

    /// Queues behaviours for the next attempts (FIFO).
    public func script(_ behaviors: Behavior...) {
        state.withLock { $0.script.append(contentsOf: behaviors) }
    }

    /// When set, channels opened afterwards answer `ping` actions with OK replies.
    public func setAutoReplyPings(_ enabled: Bool) {
        state.withLock { $0.autoReplyPings = enabled }
    }

    public var attempts: [Attempt] { state.withLock { $0.attempts } }
    public var attemptCount: Int { state.withLock { $0.attempts.count } }

    /// Waits (real time, bounded) until at least `number` attempts were made and
    /// returns attempt `number` (1-based).
    public func attempt(_ number: Int, timeout: Duration = .seconds(5)) async -> Attempt? {
        let reached = await RealtimeTestWait.until(timeout: timeout) { [self] in attemptCount >= number }
        guard reached else { return nil }
        return state.withLock { $0.attempts[number - 1] }
    }

    public func connect(url: URL, headers: [String: String], maximumMessageSize: Int)
        async throws(WebSocketTransportError) -> any WebSocketChannel
    {
        let (behavior, attempt): (Behavior, Attempt) = state.withLock { state in
            let behavior = state.script.isEmpty ? state.defaultBehavior : state.script.removeFirst()
            var channel: FakeWebSocketChannel?
            if case .accept = behavior {
                channel = FakeWebSocketChannel(maximumMessageSize: maximumMessageSize,
                                               autoReplyPings: state.autoReplyPings)
            }
            let attempt = Attempt(index: state.attempts.count + 1, url: url, headers: headers,
                                  maximumMessageSize: maximumMessageSize, channel: channel)
            state.attempts.append(attempt)
            return (behavior, attempt)
        }
        switch behavior {
        case .accept:
            guard let channel = attempt.channel else { throw .cancelled }
            if Task.isCancelled {
                channel.close()
                throw .cancelled
            }
            return channel
        case .reject(let error):
            throw error
        case .hang:
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
            }
            throw .cancelled
        }
    }
}

/// One fake socket. The test plays the server: `emit` frames, `reply` to actions,
/// `serverClose`/`fail` the socket, and inspect `sentActions`.
public final class FakeWebSocketChannel: WebSocketChannel, Sendable {
    /// A client action parsed from a sent text frame.
    public struct SentAction: Sendable, Hashable {
        public let seq: Int64
        public let action: String
        /// Scalar `data` fields rendered as strings (`true`/`false` for booleans).
        public let data: [String: String]
        public let byteCount: Int
    }

    private enum Inbound {
        case frame(WebSocketFrame)
        case failure(WebSocketTransportError)
    }

    private struct State {
        var inbound: [Inbound] = []
        var waiter: CheckedContinuation<Result<WebSocketFrame, WebSocketTransportError>, Never>?
        var terminal: WebSocketTransportError?
        var closedByClient = false
        var sent: [SentAction] = []
        var sendFailure: WebSocketTransportError?
        var autoReplyPings: Bool
        var lateDelivery = false
    }

    public let maximumMessageSize: Int
    private let state: OSAllocatedUnfairLock<State>

    public init(maximumMessageSize: Int, autoReplyPings: Bool = false) {
        self.maximumMessageSize = maximumMessageSize
        state = OSAllocatedUnfairLock(initialState: State(autoReplyPings: autoReplyPings))
    }

    // MARK: Observation

    public var sentActions: [SentAction] { state.withLock { $0.sent } }
    public var isClosedByClient: Bool { state.withLock { $0.closedByClient } }

    public func sentActions(named name: String) -> [SentAction] {
        sentActions.filter { $0.action == name }
    }

    /// Waits (real time, bounded) for the `occurrence`-th action named `name`.
    public func waitForAction(_ name: String, occurrence: Int = 1,
                              timeout: Duration = .seconds(5)) async -> SentAction? {
        let found = await RealtimeTestWait.until(timeout: timeout) { [self] in
            sentActions(named: name).count >= occurrence
        }
        guard found else { return nil }
        return sentActions(named: name)[occurrence - 1]
    }

    // MARK: Server side

    public func setAutoReplyPings(_ enabled: Bool) {
        state.withLock { $0.autoReplyPings = enabled }
    }

    /// Makes the socket ignore client close/cancellation for a pending `receive`, so
    /// one more emitted frame still reaches the superseded receive loop (simulates a
    /// frame that raced with socket replacement).
    public func setLateDelivery(_ enabled: Bool) {
        state.withLock { $0.lateDelivery = enabled }
    }

    /// Makes subsequent client sends fail with `error`.
    public func failSends(with error: WebSocketTransportError) {
        state.withLock { $0.sendFailure = error }
    }

    /// Delivers one text frame. Frames above `maximumMessageSize` fail the socket
    /// with `.messageTooLarge`, as URLSession does.
    public func emit(_ text: String) {
        if text.utf8.count > maximumMessageSize {
            push(.failure(.messageTooLarge), terminal: .messageTooLarge)
        } else {
            push(.frame(.text(text)), terminal: nil)
        }
    }

    public func emitBinary(_ data: Data) {
        push(.frame(.binary(data)), terminal: nil)
    }

    public func sendHello(connectionID: String = RealtimeFixtures.connectionID,
                          userID: String = RealtimeFixtures.aliceID, seq: Int64 = 0) {
        emit(RealtimeFixtures.hello(connectionID: connectionID, userID: userID, seq: seq))
    }

    public func replyOK(to seq: Int64) {
        emit(RealtimeFixtures.pingReply(seq: seq))
    }

    public func replyFailure(to seq: Int64, statusCode: Int = 401) {
        emit(RealtimeFixtures.failReply(seq: seq, statusCode: statusCode))
    }

    /// Closes from the server side: pending and later receives fail with `.closed`.
    public func serverClose(code: Int? = 1000) {
        push(.failure(.closed(code: code)), terminal: .closed(code: code))
    }

    public func fail(_ error: WebSocketTransportError) {
        push(.failure(error), terminal: error)
    }

    /// Waits for the client's first `ping`, then answers like a server that created a
    /// new connection: `hello` first, then the ping reply.
    @discardableResult
    public func completeNewConnection(connectionID: String = RealtimeFixtures.connectionID,
                                      userID: String = RealtimeFixtures.aliceID) async -> Bool {
        guard let ping = await waitForAction("ping") else { return false }
        sendHello(connectionID: connectionID, userID: userID)
        replyOK(to: ping.seq)
        return true
    }

    /// Waits for the client's first `ping`, emits `replayed` frames, then the ping
    /// reply (the server resumed the connection and replayed its dead queue).
    @discardableResult
    public func completeResume(replaying replayed: [String] = []) async -> Bool {
        guard let ping = await waitForAction("ping") else { return false }
        for frame in replayed { emit(frame) }
        replyOK(to: ping.seq)
        return true
    }

    private typealias Waiter = CheckedContinuation<Result<WebSocketFrame, WebSocketTransportError>, Never>

    private func push(_ item: Inbound, terminal: WebSocketTransportError?) {
        let delivery: (Waiter, Result<WebSocketFrame, WebSocketTransportError>)? = state.withLock { state in
            guard state.terminal == nil else { return nil }
            if let terminal { state.terminal = terminal }
            guard let waiter = state.waiter else {
                state.inbound.append(item)
                return nil
            }
            state.waiter = nil
            if state.lateDelivery && state.closedByClient {
                // The one late frame was delivered; the socket is dead from now on.
                state.lateDelivery = false
                state.terminal = state.terminal ?? .cancelled
            }
            switch item {
            case .frame(let frame): return (waiter, .success(frame))
            case .failure(let error): return (waiter, .failure(error))
            }
        }
        if let (waiter, result) = delivery { waiter.resume(returning: result) }
    }

    // MARK: WebSocketChannel (client side)

    public func send(text: String) async throws(WebSocketTransportError) {
        let (reply, failure): (String?, WebSocketTransportError?) = state.withLock { state in
            if state.closedByClient { return (nil, .cancelled) }
            if let error = state.sendFailure { return (nil, error) }
            if let terminal = state.terminal { return (nil, terminal) }
            guard let action = Self.parse(text) else { return (nil, nil) }
            state.sent.append(action)
            if state.autoReplyPings, action.action == "ping" {
                return (RealtimeFixtures.pingReply(seq: action.seq), nil)
            }
            return (nil, nil)
        }
        if let failure { throw failure }
        if let reply { emit(reply) }
    }

    public func receive() async throws(WebSocketTransportError) -> WebSocketFrame {
        let result: Result<WebSocketFrame, WebSocketTransportError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: Waiter) in
                enum Immediate { case result(Result<WebSocketFrame, WebSocketTransportError>), wait }
                let immediate: Immediate = state.withLock { state in
                    if !state.inbound.isEmpty {
                        switch state.inbound.removeFirst() {
                        case .frame(let frame): return .result(.success(frame))
                        case .failure(let error): return .result(.failure(error))
                        }
                    }
                    if let terminal = state.terminal { return .result(.failure(terminal)) }
                    if (Task.isCancelled && !state.lateDelivery) || state.waiter != nil {
                        return .result(.failure(.cancelled))
                    }
                    state.waiter = continuation
                    return .wait
                }
                if case .result(let result) = immediate { continuation.resume(returning: result) }
            }
        } onCancel: {
            let waiter: Waiter? = state.withLock { state in
                guard !state.lateDelivery else { return nil }
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: .failure(.cancelled))
        }
        return try result.get()
    }

    public func close() {
        let waiter: Waiter? = state.withLock { state in
            state.closedByClient = true
            guard !state.lateDelivery else { return nil }
            state.terminal = state.terminal ?? .cancelled
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: .failure(.cancelled))
    }

    private static func parse(_ text: String) -> SentAction? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let seq = (object["seq"] as? NSNumber)?.int64Value,
              let action = object["action"] as? String
        else { return nil }
        var data: [String: String] = [:]
        if let fields = object["data"] as? [String: Any] {
            for (key, value) in fields {
                if let number = value as? NSNumber {
                    data[key] = CFGetTypeID(number) == CFBooleanGetTypeID()
                        ? (number.boolValue ? "true" : "false") : number.stringValue
                } else if let string = value as? String {
                    data[key] = string
                }
            }
        }
        return SentAction(seq: seq, action: action, data: data, byteCount: text.utf8.count)
    }
}
