public import MatterMacModels
public import MattermostRealtime

/// Manually driven `RealtimeConnection` for Core tests: the test pushes deliveries,
/// the session's single consumer receives them in order.
public actor FakeRealtimeConnection: RealtimeConnection {
    private var queue: [RealtimeDelivery] = []
    private var waiter: CheckedContinuation<RealtimeDelivery?, Never>?
    private var stopped = false
    public private(set) var started = false
    public private(set) var reconnectRequests: [ReconnectReason] = []
    public private(set) var typingSent: [(ChannelID, PostID?)] = []
    public private(set) var activityReports: [Bool] = []

    public init() {}

    public func start() async { started = true }

    public func stop() async {
        stopped = true
        waiter?.resume(returning: nil)
        waiter = nil
        queue.removeAll()
    }

    public func requestReconnect(_ reason: ReconnectReason) async { reconnectRequests.append(reason) }
    public func sendTyping(channel: ChannelID, parent: PostID?) async { typingSent.append((channel, parent)) }
    public func reportUserActivity(isActive: Bool) async { activityReports.append(isActive) }

    public func nextDelivery() async -> RealtimeDelivery? {
        if stopped { return nil }
        if !queue.isEmpty { return queue.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    public func push(_ delivery: RealtimeDelivery) {
        guard !stopped else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: delivery)
        } else {
            queue.append(delivery)
        }
    }

    public func push(_ event: RealtimeEvent) { push(.event(event)) }

    public var isStopped: Bool { stopped }
    public var queuedCount: Int { queue.count }
}
