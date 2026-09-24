/// A test clock: sleeps shorter than `parkThreshold` complete immediately (after a
/// yield), longer sleeps park until the task is cancelled. Lets retry/dwell logic run
/// without real waiting while periodic pollers stay idle.
public struct ImmediateClock: Clock {
    public typealias Instant = ContinuousClock.Instant
    public typealias Duration = Swift.Duration

    public let parkThreshold: Duration

    public init(parkThreshold: Duration = .seconds(30)) {
        self.parkThreshold = parkThreshold
    }

    public var now: Instant { ContinuousClock.now }
    public var minimumResolution: Duration { .nanoseconds(1) }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let duration = deadline - ContinuousClock.now
        if duration >= parkThreshold {
            // Park until cancelled.
            while true {
                try Task.checkCancellation()
                try await ContinuousClock().sleep(for: .milliseconds(50))
            }
        }
        await Task.yield()
        try Task.checkCancellation()
    }
}
