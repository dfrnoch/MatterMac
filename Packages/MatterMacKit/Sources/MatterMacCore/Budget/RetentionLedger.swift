import os
public import MatterMacModels

/// Global accounting of retained post content across all server sessions (SPEC §15
/// "All retained post content: 2,000 posts or 16 MiB", §17 "one shared byte budget
/// across servers, with the active session prioritized").
///
/// Each session reports its usage after every mutation and asks for its current
/// allowance before growing. The active session may use whatever the others leave;
/// an inactive session is capped at a quarter of the global budget. Because sessions
/// are independent actors, two sessions growing at the same moment can overshoot by
/// at most one in-flight page each; the next report corrects it.
public final class RetentionLedger: Sendable {
    public struct Usage: Hashable, Sendable {
        public var count: Int
        public var bytes: Int
        public init(count: Int = 0, bytes: Int = 0) {
            self.count = count
            self.bytes = bytes
        }
    }

    private struct State {
        var usage: [ServerSlotID: Usage] = [:]
        var active: ServerSlotID?
    }

    public let limit: ResourceBudget.CountAndBytes
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(budget: ResourceBudget) {
        self.limit = budget.retainedPosts
    }

    public func setActive(_ slot: ServerSlotID?) {
        state.withLock { $0.active = slot }
    }

    public func report(_ slot: ServerSlotID, usage: Usage) {
        state.withLock { $0.usage[slot] = usage }
    }

    public func remove(_ slot: ServerSlotID) {
        state.withLock { state in
            state.usage[slot] = nil
            if state.active == slot { state.active = nil }
        }
    }

    /// The most this session may retain right now.
    public func allowance(for slot: ServerSlotID) -> ResourceBudget.CountAndBytes {
        let limit = limit
        return state.withLock { state in
            var othersCount = 0
            var othersBytes = 0
            for (other, usage) in state.usage where other != slot {
                othersCount += usage.count
                othersBytes += usage.bytes
            }
            let isActive = state.active == nil || state.active == slot
            let roleCount = isActive ? limit.count : limit.count / 4
            let roleBytes = isActive ? limit.bytes : limit.bytes / 4
            return ResourceBudget.CountAndBytes(
                count: max(0, min(roleCount, limit.count - othersCount)),
                bytes: max(0, min(roleBytes, limit.bytes - othersBytes)))
        }
    }

    public var total: Usage {
        state.withLock { state in
            state.usage.values.reduce(into: Usage()) { total, usage in
                total.count += usage.count
                total.bytes += usage.bytes
            }
        }
    }
}
