import os

/// A manually advanced `Clock` for deterministic tests of backoff, delays and
/// timeouts. Time only moves when `advance(by:)` is called.
///
/// `waitForSleepers(_:)` lets a test wait until the code under test has actually
/// reached a sleep before advancing time (no real sleeps, no polling).
public final class TestClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Hashable, Sendable {
        public var offset: Duration
        public init(offset: Duration) { self.offset = offset }
        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper: Sendable {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum SleepState: Sendable {
        case pending
        case cancelledEarly
        case sleeping(Sleeper)
    }

    private struct SleeperWaiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var now = Instant(offset: .zero)
        var sleepers: [UInt64: SleepState] = [:]
        var nextID: UInt64 = 0
        var waiters: [SleeperWaiter] = []
        var requested: [Duration] = []
        var activeSleepers: Int {
            sleepers.values.reduce(0) { count, state in
                if case .sleeping = state { return count + 1 }
                return count
            }
        }
    }

    /// Requested sleep durations are retained up to this count.
    public static let maximumRecordedSleeps = 10_000

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    /// Durations passed to `sleep` (deadline − now at the time of the call), in order.
    public var recordedSleeps: [Duration] { state.withLock { $0.requested } }

    public var sleeperCount: Int { state.withLock { $0.activeSleepers } }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id: UInt64? = state.withLock { state in
            if state.requested.count < Self.maximumRecordedSleeps {
                state.requested.append(state.now.duration(to: deadline))
            }
            guard deadline > state.now else { return nil }
            state.nextID &+= 1
            state.sleepers[state.nextID] = .pending
            return state.nextID
        }
        guard let id else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (cancelled, ready) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if case .cancelledEarly = state.sleepers[id] {
                        state.sleepers[id] = nil
                        return (true, [])
                    }
                    state.sleepers[id] = .sleeping(Sleeper(deadline: deadline, continuation: continuation))
                    let count = state.activeSleepers
                    let ready = state.waiters.filter { $0.count <= count }.map(\.continuation)
                    state.waiters.removeAll { $0.count <= count }
                    return (false, ready)
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                for waiter in ready { waiter.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                switch state.sleepers[id] {
                case .pending:
                    state.sleepers[id] = .cancelledEarly
                    return nil
                case .sleeping(let sleeper):
                    state.sleepers[id] = nil
                    return sleeper
                case .cancelledEarly, .none:
                    return nil
                }
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed, in
    /// deadline order.
    public func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            var due: [(UInt64, Sleeper)] = []
            for (id, entry) in state.sleepers {
                if case .sleeping(let sleeper) = entry, sleeper.deadline <= state.now { due.append((id, sleeper)) }
            }
            for (id, _) in due { state.sleepers[id] = nil }
            return due.sorted { $0.1.deadline < $1.1.deadline }.map(\.1)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Suspends until at least `count` tasks are sleeping on this clock.
    public func waitForSleepers(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.activeSleepers >= count { return true }
                state.waiters.append(SleeperWaiter(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
