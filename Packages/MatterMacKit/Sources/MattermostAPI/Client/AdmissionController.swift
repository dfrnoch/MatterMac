public import MatterMacModels
import os

/// Client-side admission control for HTTP work (SPEC §9, §15).
///
/// One instance is owned by the service factory and shared by every server
/// session ("lanes"), so the global limit is enforced across servers while each
/// lane has its own per-server limit and waiter queues.
///
/// Policy:
/// - A lane runs at most `perLane` operations; `.background` work may occupy at most
///   `perLane - reservedInteractivePerLane` of them, so reserved slots are usable only
///   by `.interactive` work. The same split applies globally
///   (`global`, `reservedInteractiveGlobal`).
/// - When no slot is available the caller waits in a per-lane FIFO for its priority.
///   Waiting interactive work is always granted before waiting background work;
///   among lanes, the oldest eligible waiter of the highest priority goes first, and
///   a lane blocked by its own limit never blocks another lane.
/// - Queues are bounded: when a lane's background queue is full, new background work
///   fails fast with `.overloaded`; interactive work has its own (separate) bound and
///   also fails with `.overloaded` only when that is full.
/// - Cancelling a waiting task removes it from the queue and resumes it with
///   `.cancelled`; every continuation is removed from the queue before it is resumed,
///   so none is resumed twice. A permit granted to an already-cancelled task is
///   returned by `withPermit` as soon as the body observes cancellation.
public actor AdmissionController {
    public struct Limits: Sendable, Hashable {
        public var perLane: Int
        public var reservedInteractivePerLane: Int
        public var global: Int
        public var reservedInteractiveGlobal: Int
        public var backgroundWaitersPerLane: Int
        public var interactiveWaitersPerLane: Int

        /// Values are sanitized so background work always has at least one slot.
        public init(perLane: Int, reservedInteractivePerLane: Int, global: Int, reservedInteractiveGlobal: Int,
                    backgroundWaitersPerLane: Int, interactiveWaitersPerLane: Int) {
            self.perLane = max(1, perLane)
            self.reservedInteractivePerLane = min(max(0, reservedInteractivePerLane), self.perLane - 1)
            self.global = max(1, global)
            self.reservedInteractiveGlobal = min(max(0, reservedInteractiveGlobal), self.global - 1)
            self.backgroundWaitersPerLane = max(0, backgroundWaitersPerLane)
            self.interactiveWaitersPerLane = max(0, interactiveWaitersPerLane)
        }

        /// Normal API requests: 6 per server (2 reserved for interactive), 10 globally
        /// (2 reserved), `requestWaitersPerServer` waiters per priority per server.
        public static func requests(_ budget: ResourceBudget) -> Limits {
            Limits(perLane: budget.requestsPerServer, reservedInteractivePerLane: budget.interactiveReservedPerServer,
                   global: budget.requestsGlobal, reservedInteractiveGlobal: budget.interactiveReservedPerServer,
                   backgroundWaitersPerLane: budget.requestWaitersPerServer,
                   interactiveWaitersPerLane: budget.requestWaitersPerServer)
        }

        /// Attachment transfers: `attachmentTransfersGlobal` (2) in total, no
        /// reservation, 16 waiters per priority per server.
        public static func transfers(_ budget: ResourceBudget) -> Limits {
            Limits(perLane: budget.attachmentTransfersGlobal, reservedInteractivePerLane: 0,
                   global: budget.attachmentTransfersGlobal, reservedInteractiveGlobal: 0,
                   backgroundWaitersPerLane: 16, interactiveWaitersPerLane: 16)
        }
    }

    /// One server session's share of the controller.
    public struct Lane: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: UInt64
        public var description: String { "lane-\(rawValue)" }
    }

    /// Proof of an admitted operation; return it with `release(_:)`.
    public struct Permit: Hashable, Sendable {
        public let lane: Lane
        public let priority: RequestPriority
        fileprivate let id: UInt64
    }

    public struct Snapshot: Sendable, Hashable {
        public var activeInteractive: Int
        public var activeBackground: Int
        public var waitingInteractive: Int
        public var waitingBackground: Int
        public var lanes: Int
        public var active: Int { activeInteractive + activeBackground }
        public var waiting: Int { waitingInteractive + waitingBackground }
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Result<Permit, APIError>, Never>
    }

    private struct LaneState {
        var activeInteractive = 0
        var activeBackground = 0
        var interactive: [Waiter] = []
        var background: [Waiter] = []
        var active: Int { activeInteractive + activeBackground }
        var isIdle: Bool { active == 0 && interactive.isEmpty && background.isEmpty }
    }

    public nonisolated let limits: Limits
    private nonisolated let laneCounter = OSAllocatedUnfairLock(initialState: UInt64(0))
    private nonisolated let diagnostics: DiagnosticRing?
    private var lanes: [Lane: LaneState] = [:]
    private var globalInteractive = 0
    private var globalBackground = 0
    private var nextID: UInt64 = 0
    private var outstanding: Set<UInt64> = []

    public init(limits: Limits, diagnostics: DiagnosticRing? = nil) {
        self.limits = limits
        self.diagnostics = diagnostics
    }

    /// Allocates a lane identifier (synchronous; lane state is created lazily and
    /// dropped whenever the lane is idle, so abandoned lanes retain nothing).
    public nonisolated func makeLane() -> Lane {
        Lane(rawValue: laneCounter.withLock { value -> UInt64 in
            value &+= 1
            return value
        })
    }

    public var snapshot: Snapshot {
        Snapshot(activeInteractive: globalInteractive, activeBackground: globalBackground,
                 waitingInteractive: lanes.values.reduce(0) { $0 + $1.interactive.count },
                 waitingBackground: lanes.values.reduce(0) { $0 + $1.background.count },
                 lanes: lanes.count)
    }

    public func snapshot(of lane: Lane) -> Snapshot {
        let state = lanes[lane] ?? LaneState()
        return Snapshot(activeInteractive: state.activeInteractive, activeBackground: state.activeBackground,
                        waitingInteractive: state.interactive.count, waitingBackground: state.background.count,
                        lanes: lanes[lane] == nil ? 0 : 1)
    }

    /// Runs `body` while holding a permit; the permit is released when `body` returns
    /// or throws. `body` runs off this actor.
    public func withPermit<T: Sendable>(lane: Lane, priority: RequestPriority,
                                        _ body: @Sendable () async throws(APIError) -> T) async throws(APIError) -> T {
        let permit = try await acquire(lane: lane, priority: priority)
        defer { release(permit) }
        if Task.isCancelled { throw .cancelled }
        return try await body()
    }

    public func acquire(lane: Lane, priority: RequestPriority) async throws(APIError) -> Permit {
        if Task.isCancelled { throw .cancelled }
        if isEligible(lane: lane, priority: priority) {
            return grant(lane: lane, priority: priority)
        }
        let state = lanes[lane] ?? LaneState()
        switch priority {
        case .interactive:
            guard state.interactive.count < limits.interactiveWaitersPerLane else {
                diagnostics?.record(.budget, .warning, "interactive request queue full", code: Int64(state.interactive.count))
                throw .overloaded
            }
        case .background:
            guard state.background.count < limits.backgroundWaitersPerLane else {
                diagnostics?.record(.budget, .warning, "background request queue full", code: Int64(state.background.count))
                throw .overloaded
            }
        }
        nextID &+= 1
        let id = nextID
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Permit, APIError>, Never>) in
                enqueue(Waiter(id: id, continuation: continuation), lane: lane, priority: priority)
            }
        } onCancel: {
            // Runs concurrently; hop onto the actor. If the waiter was already granted
            // (or not yet enqueued, which cannot happen because enqueueing is
            // synchronous with the suspension), this is a no-op.
            Task { await self.cancelWaiter(id: id, lane: lane) }
        }
        return try result.get()
    }

    /// Returns a permit. Releasing the same permit twice has no effect.
    public func release(_ permit: Permit) {
        guard outstanding.remove(permit.id) != nil else { return }
        var state = lanes[permit.lane] ?? LaneState()
        switch permit.priority {
        case .interactive:
            state.activeInteractive -= 1
            globalInteractive -= 1
        case .background:
            state.activeBackground -= 1
            globalBackground -= 1
        }
        store(state, for: permit.lane)
        pump()
    }

    /// Resumes every waiter of `lane` with `.cancelled` (used at session teardown).
    /// Running operations keep their permits until they finish.
    public func cancelWaiters(lane: Lane) {
        guard var state = lanes[lane] else { return }
        let waiters = state.interactive + state.background
        state.interactive.removeAll()
        state.background.removeAll()
        store(state, for: lane)
        for waiter in waiters { waiter.continuation.resume(returning: .failure(.cancelled)) }
        pump()
    }

    // MARK: Internals

    private func isEligible(lane: Lane, priority: RequestPriority) -> Bool {
        let state = lanes[lane] ?? LaneState()
        let globalActive = globalInteractive + globalBackground
        guard state.active < limits.perLane, globalActive < limits.global else { return false }
        switch priority {
        case .interactive:
            return true
        case .background:
            return state.activeBackground < limits.perLane - limits.reservedInteractivePerLane
                && globalBackground < limits.global - limits.reservedInteractiveGlobal
        }
    }

    private func grant(lane: Lane, priority: RequestPriority) -> Permit {
        nextID &+= 1
        let permit = Permit(lane: lane, priority: priority, id: nextID)
        outstanding.insert(permit.id)
        var state = lanes[lane] ?? LaneState()
        switch priority {
        case .interactive:
            state.activeInteractive += 1
            globalInteractive += 1
        case .background:
            state.activeBackground += 1
            globalBackground += 1
        }
        lanes[lane] = state
        return permit
    }

    private func enqueue(_ waiter: Waiter, lane: Lane, priority: RequestPriority) {
        var state = lanes[lane] ?? LaneState()
        switch priority {
        case .interactive: state.interactive.append(waiter)
        case .background: state.background.append(waiter)
        }
        lanes[lane] = state
    }

    private func cancelWaiter(id: UInt64, lane: Lane) {
        guard var state = lanes[lane] else { return }
        var removed: Waiter?
        if let index = state.interactive.firstIndex(where: { $0.id == id }) {
            removed = state.interactive.remove(at: index)
        } else if let index = state.background.firstIndex(where: { $0.id == id }) {
            removed = state.background.remove(at: index)
        }
        guard let removed else { return }
        store(state, for: lane)
        removed.continuation.resume(returning: .failure(.cancelled))
    }

    private func store(_ state: LaneState, for lane: Lane) {
        lanes[lane] = state.isIdle ? nil : state
    }

    /// Grants waiters while capacity allows: interactive (oldest first across lanes)
    /// before background.
    private func pump() {
        while let (lane, priority) = nextEligibleWaiter() {
            guard var state = lanes[lane] else { return }
            let waiter = priority == .interactive ? state.interactive.removeFirst() : state.background.removeFirst()
            lanes[lane] = state
            let permit = grant(lane: lane, priority: priority)
            waiter.continuation.resume(returning: .success(permit))
        }
    }

    private func nextEligibleWaiter() -> (Lane, RequestPriority)? {
        for priority in [RequestPriority.interactive, .background] {
            var best: (lane: Lane, id: UInt64)?
            for (lane, state) in lanes {
                guard let head = priority == .interactive ? state.interactive.first : state.background.first,
                      isEligible(lane: lane, priority: priority)
                else { continue }
                if let current = best, current.id < head.id { continue }
                best = (lane, head.id)
            }
            if let best { return (best.lane, priority) }
        }
        return nil
    }
}
