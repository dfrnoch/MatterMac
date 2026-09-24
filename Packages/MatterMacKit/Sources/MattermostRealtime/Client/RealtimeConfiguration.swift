/// Tunables of one realtime connection. Defaults follow the official web client and
/// the verified server constants (docs/research/websocket.md §4-§7).
public struct RealtimeConfiguration: Sendable, Hashable {
    /// Liveness `ping` action cadence. If the previous ping is still unanswered at the
    /// next tick, the socket is closed and reconnected (webapp `clientPingInterval`).
    public var pingInterval: Duration = .seconds(30)
    /// Client-side bound on the HTTP upgrade, in addition to the transport's own.
    public var connectTimeout: Duration = .seconds(40)
    /// Minimum spacing of `user_typing` per (channel, parent). Should follow the
    /// server's `TimeBetweenUserTypingUpdatesMilliseconds` (default 5,000 ms).
    public var typingThrottle: Duration = .milliseconds(5_000)
    /// Minimum spacing of repeated `user_update_active_status{true}` refreshes.
    public var activityRefreshInterval: Duration = .seconds(60)
    /// Minimum spacing of credential probes after sockets close unauthenticated.
    public var credentialProbeInterval: Duration = .seconds(60)
    public var backoff = ReconnectBackoff()
    /// Bound on the table of outstanding action replies.
    public var pendingReplyLimit = 64
    /// Bound on per-(channel,parent) typing throttle entries.
    public var typingThrottleEntries = 64
    /// Bound on outbound messages queued for the socket writer.
    public var outboundQueueLimit = 16

    public init() {}

    public static let standard = RealtimeConfiguration()
}

/// Webapp-compatible reconnect delay (`websocket.ts`): 3 s plus 0–2 s jitter; once
/// more than 7 consecutive failures occurred, `3 s × n²` capped at 300 s, plus jitter.
public struct ReconnectBackoff: Sendable, Hashable {
    public var base: Duration = .seconds(3)
    public var jitterRange: Duration = .seconds(2)
    public var maximum: Duration = .seconds(300)
    /// Failures beyond this count switch to quadratic growth.
    public var quadraticAfterFailures = 7

    public init() {}

    /// Delay before the next attempt after `failures` consecutive failures (≥ 1).
    /// `jitter` is a unit random value in `0..<1`.
    public func delay(afterFailures failures: Int, jitter: Double) -> Duration {
        let n = max(1, failures)
        var delay = base
        if n > quadraticAfterFailures {
            let squared = Int64(min(n, 1_000)) * Int64(min(n, 1_000))
            delay = base * squared
            if delay > maximum { delay = maximum }
        }
        let unit = jitter.isFinite ? min(max(jitter, 0), 1) : 0
        return delay + jitterRange * unit
    }
}
