import os

/// A manually advanced `Clock` for deterministic realtime tests. Sleepers resume only
/// when `advance(by:)` moves time past their deadline; cancellation resumes them with
/// `CancellationError` and removes them.
public final class RealtimeTestClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Sendable, Hashable, Comparable {
        public let offset: Duration

        public init(offset: Duration) { self.offset = offset }

        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UInt64: Sleeper] = [:]
        var nextID: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    /// Number of tasks currently sleeping on this clock.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Deadlines of current sleepers, relative to `now`, ascending.
    public var pendingDelays: [Duration] {
        state.withLock { state in state.sleepers.values.map { state.now.duration(to: $0.deadline) }.sorted() }
    }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id: UInt64 = state.withLock { state in
            state.nextID &+= 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Immediate { case resume, cancel, wait }
                let immediate: Immediate = state.withLock { state in
                    if deadline <= state.now { return .resume }
                    if Task.isCancelled { return .cancel }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch immediate {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has passed, in
    /// deadline order.
    public func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let dueIDs = state.sleepers.filter { $0.value.deadline <= now }.sorted { $0.value.deadline < $1.value.deadline }
            return dueIDs.compactMap { state.sleepers.removeValue(forKey: $0.key) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Advances exactly to the earliest pending deadline (if any) and returns the
    /// amount advanced.
    @discardableResult
    public func advanceToNextDeadline() -> Duration? {
        guard let next = pendingDelays.first else { return nil }
        advance(by: max(next, .zero))
        return next
    }
}

/// Real-time polling helper for tests: the realtime logic runs on the test clock,
/// while this bounds how long a test waits for asynchronous effects.
public enum RealtimeTestWait {
    public static func until(timeout: Duration = .seconds(5),
                             _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}
