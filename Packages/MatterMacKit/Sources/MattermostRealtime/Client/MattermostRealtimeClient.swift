import Foundation
public import MatterMacModels
import MattermostAPI

/// Result of the optional credential probe the client runs when sockets open but are
/// closed by the server before any `hello` (the server upgrades requests with an
/// invalid token *unauthenticated* and closes them after its 5 s auth deadline, so no
/// HTTP 401 is ever seen). Core typically maps `GET /api/v4/users/me`: 401 →
/// `.rejected`, success → `.valid`, anything else → `.indeterminate`.
public enum CredentialProbeResult: Sendable, Hashable {
    case valid
    case rejected
    case indeterminate
}

/// Resume identity of the current or most recent connection.
public struct RealtimeConnectionInfo: Sendable, Hashable {
    public let connectionID: String?
    /// The next server event sequence number the client expects.
    public let nextExpectedSequence: Int64
    public let serverVersion: String?
}

/// Debug counters (SPEC §15). Content-free.
public struct RealtimeCounters: Sendable, Hashable {
    public var connectAttempts = 0
    public var resumedConnections = 0
    public var newConnections = 0
    public var sequenceGaps = 0
    public var duplicatesDropped = 0
    public var pingTimeouts = 0
    public var oversizedFrames = 0
    public var malformedDurable = 0
    public var malformedEphemeral = 0
    public var unreadableFrames = 0
    public var binaryFrames = 0
    public var staleCallbacksIgnored = 0
    public var outboundDropped = 0
    public var typingThrottled = 0
    public var credentialProbes = 0
    public init() {}
}

/// The realtime connection for one authenticated server session (SPEC §10, §15, §17).
///
/// Ownership and bounds:
/// - one socket task per live socket (connect, then two child tasks: the receive loop
///   and the writer draining a bounded `OutboundQueue`);
/// - one liveness task per open socket (a `ping` action every `pingInterval`);
/// - one timer task (backoff delay or connect timeout) and at most one credential
///   probe task;
/// - one `RealtimeMailbox` (bounded by `budget.realtimeMailbox`) and one consumer.
///
/// All tasks hold the client only weakly (`WeakClient`) so dropping the last strong
/// reference deinitializes the client, which cancels everything. `stop()` cancels
/// and awaits the tasks, closes the socket, and finishes the mailbox.
///
/// Every socket has a generation; frames and callbacks from superseded sockets are
/// ignored (`staleCallbacksIgnored`).
public actor MattermostRealtimeClient: RealtimeConnection {
    private enum Phase: Equatable {
        case idle
        case connecting
        /// Socket open; awaiting `hello` (new connection) or the handshake ping reply
        /// (resume succeeded). Reported as `.authenticating`.
        case handshaking
        case connected
        case backingOff
        case authenticationRequired
        case stopped
    }

    private enum ReplyPurpose: Sendable {
        case ping
        case typing
        case activity
    }

    private enum AttemptCause {
        case other
        case sequenceGap
    }

    private enum TimerPurpose: Sendable {
        case backoff
        case connectTimeout(generation: UInt64)
    }

    private struct Socket: Sendable {
        let generation: UInt64
        let outbox: OutboundQueue
        let task: Task<Void, Never>
        let resuming: Bool
        var channel: (any WebSocketChannel)?
        var handshakePingSeq: Int64?
        var outstandingPing: Int64?
        var sawHello = false
        var established = false
        /// Set after an unreadable frame: the next event may skip one sequence number.
        var tolerateOneSkippedSequence = false
    }

    private struct TypingKey: Hashable {
        let channel: ChannelID
        let parent: PostID?
    }

    // MARK: Dependencies (immutable)

    private let endpoint: ServerEndpoint
    private let credential: BearerCredential
    private let currentUserID: UserID
    private let transport: any WebSocketTransport
    private let budget: ResourceBudget
    private let configuration: RealtimeConfiguration
    private let clock: ClockBox
    private let randomUnit: @Sendable () -> Double
    private let credentialProbe: (@Sendable () async -> CredentialProbeResult)?
    private let diagnostics: DiagnosticRing?
    private let decoder: RealtimeFrameDecoder
    private let mailbox: RealtimeMailbox

    // MARK: State

    private var phase: Phase = .idle
    public private(set) var state: RealtimeState = .disconnected
    private var ownerBox: WeakClient?
    private var socket: Socket?
    private var generation: UInt64 = 0
    private var livenessTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var timerToken: UInt64 = 0
    private var probeTask: Task<Void, Never>?
    private var lastProbeAt: Duration?

    private var connectionID: String?
    /// Next expected server event `seq`; 0 until the first `hello`.
    private var expectedSequence: Int64 = 0
    private var serverVersion: String?
    private var hasEstablishedOnce = false
    private var attemptCause: AttemptCause = .other

    private var consecutiveFailures = 0
    private var immediateGapRetries = 0

    /// Client action sequence: monotonic for the life of the client, never reset on
    /// reconnect (a resumed server queue can still carry replies to old actions).
    private var nextActionSeq: Int64 = 1
    private var pendingReplies: [Int64: ReplyPurpose] = [:]
    private var pendingReplyOrder: [Int64] = []
    private var typingSentAt: [TypingKey: Duration] = [:]
    private var lastActivity: (isActive: Bool, at: Duration)?
    private var counterValues = RealtimeCounters()

    /// - Parameters:
    ///   - endpoint: the normalized server; the socket URL is
    ///     `endpoint.webSocketURL(path: ["api", "v4", "websocket"])`.
    ///   - credential: sent only as `Authorization: Bearer` on the upgrade request.
    ///   - currentUserID: the authenticated user (mention detection, hello check).
    ///   - clock: drives liveness, backoff, throttles (inject a test clock in tests).
    ///   - randomUnit: jitter source returning values in `0..<1`.
    ///   - credentialProbe: optional REST check used when sockets close before any
    ///     `hello` (see `CredentialProbeResult`).
    public init(endpoint: ServerEndpoint,
                credential: BearerCredential,
                currentUserID: UserID,
                transport: any WebSocketTransport = URLSessionWebSocketTransport(),
                budget: ResourceBudget = .standard,
                configuration: RealtimeConfiguration = .standard,
                clock: any Clock<Duration> = ContinuousClock(),
                randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                credentialProbe: (@Sendable () async -> CredentialProbeResult)? = nil,
                diagnostics: DiagnosticRing? = nil) {
        self.endpoint = endpoint
        self.credential = credential
        self.currentUserID = currentUserID
        self.transport = transport
        self.budget = budget
        self.configuration = configuration
        self.clock = ClockBox(clock)
        self.randomUnit = randomUnit
        self.credentialProbe = credentialProbe
        self.diagnostics = diagnostics
        self.decoder = RealtimeFrameDecoder(currentUserID: currentUserID,
                                            maximumFrameBytes: budget.webSocketMessageBytes)
        self.mailbox = RealtimeMailbox(limits: budget.realtimeMailbox)
    }

    deinit {
        socket?.outbox.finish()
        socket?.channel?.close()
        socket?.task.cancel()
        livenessTask?.cancel()
        timerTask?.cancel()
        probeTask?.cancel()
        mailbox.finish(final: nil)
    }

    // MARK: RealtimeConnection

    public func start() {
        guard phase == .idle else { return }
        record(.info, "realtime start")
        beginConnecting()
    }

    public func stop() async {
        guard phase != .stopped else { return }
        let tasks = [socket?.task, livenessTask, timerTask, probeTask].compactMap { $0 }
        phase = .stopped
        retireSocket()
        cancelTimer()
        probeTask?.cancel()
        probeTask = nil
        pendingReplies.removeAll()
        pendingReplyOrder.removeAll()
        typingSentAt.removeAll()
        state = .stopped
        mailbox.finish(final: .state(.stopped))
        record(.info, "realtime stopped")
        for task in tasks {
            await task.value
        }
    }

    public func requestReconnect(_ reason: ReconnectReason) {
        switch phase {
        case .idle, .stopped, .authenticationRequired, .connecting, .handshaking:
            // Not started, terminal, or an attempt is already in flight: coalesced.
            return
        case .backingOff:
            record(.info, "reconnect requested during backoff", code: Int64(reason.diagnosticCode))
            cancelTimer()
            beginConnecting()
        case .connected:
            record(.info, "reconnect requested while connected", code: Int64(reason.diagnosticCode))
            retireSocket()
            deliverState(.disconnected)
            beginConnecting()
        }
    }

    public func sendTyping(channel: ChannelID, parent: PostID?) {
        guard phase == .connected else { return }
        let key = TypingKey(channel: channel, parent: parent)
        let now = clock.elapsed()
        if let last = typingSentAt[key], now - last < configuration.typingThrottle {
            counterValues.typingThrottled += 1
            return
        }
        guard sendAction(.typing(channel: channel, parent: parent), purpose: .typing) != nil else { return }
        typingSentAt[key] = now
        if typingSentAt.count > configuration.typingThrottleEntries {
            let throttle = configuration.typingThrottle
            typingSentAt = typingSentAt.filter { now - $0.value < throttle }
            while typingSentAt.count > configuration.typingThrottleEntries,
                  let oldest = typingSentAt.min(by: { $0.value < $1.value }) {
                typingSentAt.removeValue(forKey: oldest.key)
            }
        }
    }

    public func reportUserActivity(isActive: Bool) {
        guard phase == .connected else { return }
        let now = clock.elapsed()
        if let last = lastActivity, last.isActive == isActive {
            // Unchanged: only a repeated `true` is refreshed, at most once per interval.
            guard isActive, now - last.at >= configuration.activityRefreshInterval else { return }
        }
        guard sendAction(.activity(isActive: isActive), purpose: .activity) != nil else { return }
        lastActivity = (isActive, now)
    }

    public nonisolated func nextDelivery() async -> RealtimeDelivery? {
        await mailbox.next()
    }

    // MARK: Introspection

    public func connectionInfo() -> RealtimeConnectionInfo {
        RealtimeConnectionInfo(connectionID: connectionID, nextExpectedSequence: expectedSequence,
                               serverVersion: serverVersion)
    }

    public func counters() -> RealtimeCounters { counterValues }

    public nonisolated var mailboxCounters: RealtimeMailbox.Counters { mailbox.counters }

    // MARK: Connecting

    private var owner: WeakClient {
        if let ownerBox { return ownerBox }
        let box = WeakClient(self)
        ownerBox = box
        return box
    }

    private func resumeQuery() -> [URLQueryItem] {
        // Never send a non-empty connection_id with sequence_number 0: the server would
        // restart numbering without a hello and corrupt its replay ring.
        guard let connectionID, !connectionID.isEmpty, expectedSequence >= 1 else { return [] }
        return [URLQueryItem(name: "connection_id", value: connectionID),
                URLQueryItem(name: "sequence_number", value: String(expectedSequence))]
    }

    private func beginConnecting() {
        cancelTimer()
        generation &+= 1
        let current = generation
        let query = resumeQuery()
        let url = endpoint.webSocketURL(path: ["api", "v4", "websocket"], query: query)
        let headers = ["Authorization": credential.authorizationHeaderValue]
        let outbox = OutboundQueue(limit: configuration.outboundQueueLimit)
        let task = Task { [owner, transport, decoder, budget] in
            await Self.runSocket(owner: owner, generation: current, transport: transport, url: url,
                                 headers: headers, maximumMessageSize: budget.webSocketMessageBytes,
                                 decoder: decoder, outbox: outbox)
        }
        socket = Socket(generation: current, outbox: outbox, task: task, resuming: !query.isEmpty)
        counterValues.connectAttempts += 1
        phase = .connecting
        deliverState(.connecting)
        scheduleTimer(after: configuration.connectTimeout, purpose: .connectTimeout(generation: current))
    }

    private enum SocketEnd: Sendable {
        case receiveFailed(WebSocketTransportError)
        case sendFailed(WebSocketTransportError)
        case finished
    }

    private static func runSocket(owner: WeakClient, generation: UInt64, transport: any WebSocketTransport,
                                  url: URL, headers: [String: String], maximumMessageSize: Int,
                                  decoder: RealtimeFrameDecoder, outbox: OutboundQueue) async {
        let channel: any WebSocketChannel
        do {
            channel = try await transport.connect(url: url, headers: headers, maximumMessageSize: maximumMessageSize)
        } catch {
            await owner.value?.socketFailedToOpen(generation: generation, error: error)
            return
        }
        guard await owner.value?.socketOpened(generation: generation, channel: channel) == true else {
            channel.close()
            outbox.finish()
            return
        }
        let end = await withTaskGroup(of: SocketEnd.self) { group in
            group.addTask {
                await receiveLoop(channel: channel, decoder: decoder, owner: owner, generation: generation)
            }
            group.addTask {
                await writeLoop(channel: channel, outbox: outbox)
            }
            let first = await group.next() ?? .finished
            channel.close()
            outbox.finish()
            group.cancelAll()
            return first
        }
        await owner.value?.socketEnded(generation: generation, end: end)
    }

    private static func receiveLoop(channel: any WebSocketChannel, decoder: RealtimeFrameDecoder,
                                    owner: WeakClient, generation: UInt64) async -> SocketEnd {
        while true {
            let frame: WebSocketFrame
            do {
                frame = try await channel.receive()
            } catch {
                return .receiveFailed(error)
            }
            // Decoding runs here, off the actor. The loop never waits for the consumer:
            // `process` only enqueues into the mailbox, so a receive is always pending
            // and URLSession keeps answering the server's protocol pings.
            let bytes = frame.byteCount
            let inbound = decoder.decode(frame)
            guard let client = owner.value else { return .finished }
            guard await client.process(inbound, bytes: bytes, generation: generation) else { return .finished }
        }
    }

    private static func writeLoop(channel: any WebSocketChannel, outbox: OutboundQueue) async -> SocketEnd {
        while let message = await outbox.next() {
            do {
                try await channel.send(text: message)
            } catch {
                return .sendFailed(error)
            }
        }
        return .finished
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        guard let socket, socket.generation == generation else {
            counterValues.staleCallbacksIgnored += 1
            return false
        }
        return true
    }

    private func socketFailedToOpen(generation: UInt64, error: WebSocketTransportError) {
        guard isCurrent(generation), phase == .connecting else { return }
        cancelTimer()
        socket = nil
        if case .handshakeRejected(let status) = error {
            record(.warning, "websocket upgrade rejected", code: Int64(status))
            if status == 401 {
                enterAuthenticationRequired()
                return
            }
        } else {
            record(.info, "websocket connect failed")
        }
        consecutiveFailures += 1
        scheduleBackoff()
    }

    private func socketOpened(generation: UInt64, channel: any WebSocketChannel) -> Bool {
        guard isCurrent(generation), phase == .connecting else { return false }
        cancelTimer()
        socket?.channel = channel
        phase = .handshaking
        deliverState(.authenticating)
        // Resume detection: `hello` before this reply → new connection; this reply
        // before any `hello` → the server resumed our connection id.
        let seq = sendAction(.ping, purpose: .ping)
        socket?.handshakePingSeq = seq
        socket?.outstandingPing = seq
        startLiveness(generation: generation)
        record(.info, "websocket open", code: socket?.resuming == true ? 1 : 0)
        return true
    }

    private func socketEnded(generation: UInt64, end: SocketEnd) {
        guard isCurrent(generation) else { return }
        switch end {
        case .receiveFailed(.messageTooLarge):
            handleOversizedFrame()
        case .receiveFailed(let error), .sendFailed(let error):
            record(.info, "websocket closed", code: Int64(Self.code(for: error)))
            socketLost(serverClosedBeforeHandshake: socket?.sawHello == false && socket?.established == false)
        case .finished:
            socketLost(serverClosedBeforeHandshake: false)
        }
    }

    // MARK: Inbound

    /// Handles one decoded frame of socket `generation`. Returns `false` when the
    /// socket is no longer current and its receive loop must stop.
    func process(_ frame: InboundFrame, bytes: Int, generation: UInt64) -> Bool {
        guard isCurrent(generation), phase == .handshaking || phase == .connected else { return false }
        switch frame {
        case .hello(let hello, let seq):
            handleHello(hello, seq: seq)
        case .event(let event, let seq):
            sequenced(seq) { deliver(.event(event), cost: bytes) }
        case .malformedEvent(let seq, let durable):
            sequenced(seq) {
                if durable {
                    counterValues.malformedDurable += 1
                    record(.warning, "malformed durable event")
                    deliver(.resynchronize(.malformedEvent), cost: 0)
                } else {
                    counterValues.malformedEphemeral += 1
                }
            }
        case .response(let response):
            handleResponse(response)
        case .unreadable:
            counterValues.unreadableFrames += 1
            record(.warning, "unreadable frame")
            // Its content (possibly a durable event) is unknown: reconcile, and let the
            // next event skip the one sequence number the frame may have consumed.
            deliver(.resynchronize(.malformedEvent), cost: 0)
            socket?.tolerateOneSkippedSequence = true
        case .binary:
            counterValues.binaryFrames += 1
        case .oversized:
            handleOversizedFrame()
        }
        return socket?.generation == generation
    }

    private func sequenced(_ seq: Int64?, _ body: () -> Void) {
        guard var current = socket else { return }
        guard let seq else {
            // Events always carry seq; without it ordering is unknown.
            counterValues.unreadableFrames += 1
            deliver(.resynchronize(.malformedEvent), cost: 0)
            return
        }
        if !current.sawHello && !current.resuming {
            // Before the hello of a fresh connection numbering is undefined; the hello
            // that follows triggers a full resynchronization anyway.
            return
        }
        let tolerated = current.tolerateOneSkippedSequence && seq == expectedSequence + 1
        if seq == expectedSequence || tolerated {
            expectedSequence = seq + 1
            current.tolerateOneSkippedSequence = false
            socket = current
            immediateGapRetries = 0
            body()
        } else if seq > expectedSequence {
            handleSequenceGap(received: seq)
        } else {
            counterValues.duplicatesDropped += 1
        }
    }

    private func handleHello(_ hello: RealtimeHello, seq: Int64?) {
        if let user = hello.userID, user != currentUserID {
            record(.error, "hello for a different user")
            enterAuthenticationRequired()
            return
        }
        let reason: ResynchronizationReason = if !hasEstablishedOnce {
            .initialConnection
        } else if attemptCause == .sequenceGap {
            .sequenceGap
        } else {
            .newConnection
        }
        connectionID = hello.connectionID
        serverVersion = hello.serverVersion
        expectedSequence = max(0, seq ?? 0) + 1
        socket?.sawHello = true
        socket?.established = true
        socket?.tolerateOneSkippedSequence = false
        hasEstablishedOnce = true
        consecutiveFailures = 0
        immediateGapRetries = 0
        attemptCause = .other
        phase = .connected
        counterValues.newConnections += 1
        record(.info, "new realtime connection")
        deliver(.resynchronize(reason), cost: 0)
        deliverState(.connected(resumed: false))
    }

    private func handleResponse(_ response: ActionResponse) {
        guard let seqReply = response.seqReply else { return }
        let purpose = pendingReplies.removeValue(forKey: seqReply)
        if !response.isOK, response.statusCode == 401 {
            record(.warning, "action rejected: not authenticated", code: 401)
            enterAuthenticationRequired()
            return
        }
        guard var current = socket else { return }
        let isHandshake = seqReply == current.handshakePingSeq
        if seqReply == current.outstandingPing { current.outstandingPing = nil }
        if isHandshake { current.handshakePingSeq = nil }
        socket = current
        if isHandshake, !current.sawHello {
            guard current.resuming, response.isOK else {
                // A fresh connection must start with hello; anything else is a
                // protocol failure. Reconnect with backoff.
                record(.warning, "handshake reply without hello", code: Int64(response.statusCode ?? 0))
                socketLost(serverClosedBeforeHandshake: false)
                return
            }
            socket?.established = true
            consecutiveFailures = 0
            immediateGapRetries = 0
            attemptCause = .other
            phase = .connected
            counterValues.resumedConnections += 1
            record(.info, "realtime connection resumed")
            deliverState(.connected(resumed: true))
            return
        }
        if purpose != nil, !response.isOK {
            record(.info, "action failed", code: Int64(response.statusCode ?? 0))
        }
    }

    private func handleSequenceGap(received seq: Int64) {
        counterValues.sequenceGaps += 1
        record(.warning, "event sequence gap", code: seq - expectedSequence)
        attemptCause = .sequenceGap
        retireSocket()
        deliverState(.disconnected)
        if immediateGapRetries == 0 {
            // Resume right away from the missing seq; the server replays from its
            // dead queue or answers with a new connection (→ `.sequenceGap`).
            immediateGapRetries += 1
            beginConnecting()
        } else {
            consecutiveFailures += 1
            scheduleBackoff()
        }
    }

    private func handleOversizedFrame() {
        counterValues.oversizedFrames += 1
        record(.warning, "oversized realtime frame", code: Int64(budget.webSocketMessageBytes))
        deliver(.resynchronize(.oversizedEvent), cost: 0)
        // Do not resume: the server would replay the same oversized event forever.
        connectionID = nil
        expectedSequence = 0
        attemptCause = .other
        socketLost(serverClosedBeforeHandshake: false)
    }

    // MARK: Liveness, loss, backoff

    private func startLiveness(generation: UInt64) {
        livenessTask?.cancel()
        let interval = configuration.pingInterval
        livenessTask = Task { [owner, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(interval)
                } catch {
                    return
                }
                guard let client = owner.value, await client.livenessTick(generation: generation) else { return }
            }
        }
    }

    private func livenessTick(generation: UInt64) -> Bool {
        guard isCurrent(generation), phase == .handshaking || phase == .connected else { return false }
        if socket?.outstandingPing != nil {
            counterValues.pingTimeouts += 1
            record(.warning, "ping unanswered; reconnecting")
            socketLost(serverClosedBeforeHandshake: false)
            return false
        }
        socket?.outstandingPing = sendAction(.ping, purpose: .ping)
        return true
    }

    /// The current socket is gone (server close, transport failure, ping timeout,
    /// protocol failure). Schedules the next attempt with backoff.
    private func socketLost(serverClosedBeforeHandshake: Bool) {
        let wasOpen = socket?.channel != nil
        retireSocket()
        if wasOpen { deliverState(.disconnected) }
        consecutiveFailures += 1
        if serverClosedBeforeHandshake && wasOpen {
            probeCredentialIfDue()
        }
        scheduleBackoff()
    }

    private func scheduleBackoff() {
        let delay = configuration.backoff.delay(afterFailures: consecutiveFailures, jitter: randomUnit())
        phase = .backingOff
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        deliverState(.backingOff(seconds: Int(seconds.rounded(.up))))
        scheduleTimer(after: delay, purpose: .backoff)
    }

    private func enterAuthenticationRequired() {
        guard phase != .stopped, phase != .authenticationRequired else { return }
        retireSocket()
        cancelTimer()
        probeTask?.cancel()
        probeTask = nil
        phase = .authenticationRequired
        record(.warning, "realtime authentication required")
        deliverState(.authenticationRequired)
    }

    private func probeCredentialIfDue() {
        guard let credentialProbe, probeTask == nil else { return }
        let now = clock.elapsed()
        if let lastProbeAt, now - lastProbeAt < configuration.credentialProbeInterval { return }
        lastProbeAt = now
        counterValues.credentialProbes += 1
        probeTask = Task { [owner] in
            let result = await credentialProbe()
            await owner.value?.credentialProbeFinished(result)
        }
    }

    private func credentialProbeFinished(_ result: CredentialProbeResult) {
        probeTask = nil
        guard phase != .stopped else { return }
        if result == .rejected {
            record(.warning, "credential probe rejected")
            enterAuthenticationRequired()
        }
    }

    private func retireSocket() {
        guard let retired = socket else { return }
        socket = nil
        retired.outbox.finish()
        retired.channel?.close()
        retired.task.cancel()
        livenessTask?.cancel()
        livenessTask = nil
    }

    private func scheduleTimer(after delay: Duration, purpose: TimerPurpose) {
        timerTask?.cancel()
        timerToken &+= 1
        let token = timerToken
        timerTask = Task { [owner, clock] in
            do {
                try await clock.sleep(delay)
            } catch {
                return
            }
            await owner.value?.timerFired(token: token, purpose: purpose)
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerToken &+= 1
    }

    private func timerFired(token: UInt64, purpose: TimerPurpose) {
        guard token == timerToken else { return }
        timerTask = nil
        switch purpose {
        case .backoff:
            guard phase == .backingOff else { return }
            beginConnecting()
        case .connectTimeout(let timedOut):
            guard phase == .connecting, socket?.generation == timedOut else { return }
            record(.warning, "websocket connect timed out")
            retireSocket()
            consecutiveFailures += 1
            scheduleBackoff()
        }
    }

    // MARK: Outbound

    private func sendAction(_ action: OutboundAction, purpose: ReplyPurpose) -> Int64? {
        guard let socket, socket.channel != nil else { return nil }
        let seq = nextActionSeq
        guard let text = action.encoded(seq: seq) else {
            counterValues.outboundDropped += 1
            return nil
        }
        nextActionSeq += 1
        guard socket.outbox.offer(text) else {
            counterValues.outboundDropped += 1
            return nil
        }
        pendingReplies[seq] = purpose
        pendingReplyOrder.append(seq)
        while pendingReplies.count > configuration.pendingReplyLimit, !pendingReplyOrder.isEmpty {
            pendingReplies.removeValue(forKey: pendingReplyOrder.removeFirst())
        }
        if pendingReplyOrder.count > configuration.pendingReplyLimit * 2 {
            pendingReplyOrder.removeAll { pendingReplies[$0] == nil }
        }
        return seq
    }

    // MARK: Delivery

    private func deliverState(_ newState: RealtimeState) {
        state = newState
        mailbox.enqueue(.state(newState), cost: RealtimeMailbox.controlCost)
    }

    private func deliver(_ delivery: RealtimeDelivery, cost: Int) {
        mailbox.enqueue(delivery, cost: cost)
    }

    private func record(_ level: DiagnosticEvent.Level, _ detail: StaticString, code: Int64 = 0) {
        diagnostics?.record(.realtime, level, detail, code: code)
    }

    private static func code(for error: WebSocketTransportError) -> Int {
        switch error {
        case .handshakeRejected(let status): status
        case .messageTooLarge: 1009
        case .closed(let code): code ?? 1006
        case .network: -1
        case .cancelled: -999
        }
    }
}

/// Weak, Sendable handle to the client for its own tasks (no retain cycle).
final class WeakClient: Sendable {
    weak let value: MattermostRealtimeClient?
    init(_ value: MattermostRealtimeClient) { self.value = value }
}

extension ReconnectReason {
    var diagnosticCode: Int {
        switch self {
        case .systemWake: 1
        case .networkPathChanged: 2
        case .userRequested: 3
        }
    }
}
