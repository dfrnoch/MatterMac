public import MatterMacModels
import os

/// The only buffer between the socket and Core (SPEC §10, §15).
///
/// - Capacity: `limits.count` items and `limits.bytes` estimated bytes (default
///   `ResourceBudget.realtimeMailbox`: 512 items / 2 MiB). Item cost is the size of
///   the frame the item was decoded from; control items cost `controlCost`.
/// - Producer: the realtime client actor. `enqueue` never suspends and never blocks
///   the receive loop (a blocked receive loop would stop URLSession from answering
///   server Ping frames and the server would drop the socket after 100 s).
/// - Consumer: exactly one task calling `next()`. A concurrent second call returns
///   `nil` immediately. A cancelled consumer gets `nil` without consuming an item.
/// - Coalescing: `typing` (per user+channel+parent), `statusChanged` (per user), and
///   `.unhandled` (per name) replace a queued item in place; `channelsViewed` merges
///   into a queued one. Adjacent `.state` items collapse to the latest.
/// - Full-queue behaviour: ephemeral items (typing, unhandled) are dropped. A durable
///   item that does not fit triggers an overflow: every queued durable item is
///   dropped, state items are kept, exactly one `.resynchronize(.mailboxOverflow)` is
///   queued after them, and new items are accepted after the marker. Control items
///   (`.state`, `.resynchronize`) are always accepted; `controlReserve` slots are kept
///   free for them.
/// - Cancellation/teardown: `finish(final:)` discards queued items, hands out the
///   optional final item, and then returns `nil` forever. No continuation is leaked
///   or resumed twice (all hand-offs happen under one lock).
public final class RealtimeMailbox: Sendable {
    public struct Counters: Sendable, Hashable {
        public var queuedItems = 0
        public var queuedBytes = 0
        public var peakItems = 0
        public var peakBytes = 0
        public var accepted = 0
        public var coalesced = 0
        public var droppedEphemeral = 0
        public var droppedDurable = 0
        public var overflowMarkers = 0
        public init() {}
    }

    public enum EnqueueOutcome: Sendable, Hashable {
        /// Queued or handed directly to a waiting consumer.
        case accepted
        /// Replaced or merged into a queued item.
        case coalesced
        /// An ephemeral item was dropped because the mailbox is full.
        case droppedEphemeral
        /// The mailbox overflowed: queued durable items were replaced by one
        /// `.resynchronize(.mailboxOverflow)` marker. `accepted` tells whether the
        /// new item itself was queued after the marker.
        case overflowed(accepted: Bool)
        /// The mailbox is finished; nothing is accepted.
        case finished
    }

    /// Estimated cost of `.state` and `.resynchronize` items.
    public static let controlCost = 64
    /// Item slots kept free for control items.
    public static let controlReserve = 4

    private enum Kind: Equatable {
        case state
        case resynchronize
        case durable
        case typing(UserID, ChannelID, PostID?)
        case status(UserID)
        case viewed
        case unhandled(String)

        var isDurableData: Bool {
            switch self {
            case .durable, .status, .viewed: true
            default: false
            }
        }

        var isControl: Bool { self == .state || self == .resynchronize }
    }

    private struct Entry {
        var delivery: RealtimeDelivery
        var cost: Int
        var kind: Kind
    }

    private struct State {
        var entries: [Entry] = []
        var head = 0
        var bytes = 0
        var finished = false
        var waiter: (token: UInt64, continuation: CheckedContinuation<RealtimeDelivery?, Never>)?
        var nextToken: UInt64 = 0
        var counters = Counters()

        var count: Int { entries.count - head }
        var live: ArraySlice<Entry> { entries[head...] }

        mutating func popFront() -> Entry? {
            guard head < entries.count else { return nil }
            let entry = entries[head]
            head += 1
            bytes -= entry.cost
            if head == entries.count {
                entries.removeAll(keepingCapacity: entries.capacity <= 1_024)
                head = 0
            } else if head >= 64, head * 2 >= entries.count {
                entries.removeFirst(head)
                head = 0
            }
            return entry
        }

        mutating func append(_ entry: Entry) {
            entries.append(entry)
            bytes += entry.cost
            counters.peakItems = max(counters.peakItems, count)
            counters.peakBytes = max(counters.peakBytes, bytes)
        }

        mutating func replace(at index: Int, with entry: Entry) {
            bytes += entry.cost - entries[index].cost
            entries[index] = entry
            counters.peakBytes = max(counters.peakBytes, bytes)
        }

        mutating func compact(keeping keep: (Entry) -> Bool) -> Int {
            let before = count
            let kept = entries[head...].filter(keep)
            entries = Array(kept)
            head = 0
            bytes = entries.reduce(0) { $0 + $1.cost }
            return before - count
        }
    }

    public let countLimit: Int
    public let byteLimit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(limits: ResourceBudget.CountAndBytes) {
        countLimit = max(limits.count, Self.controlReserve + 2)
        byteLimit = max(limits.bytes, (Self.controlReserve + 2) * Self.controlCost)
    }

    public convenience init(budget: ResourceBudget = .standard) {
        self.init(limits: budget.realtimeMailbox)
    }

    public var counters: Counters {
        state.withLock { state in
            var counters = state.counters
            counters.queuedItems = state.count
            counters.queuedBytes = state.bytes
            return counters
        }
    }

    public var isFinished: Bool { state.withLock { $0.finished } }

    /// Offers one item. Never suspends. `cost` is the estimated retained size (for
    /// events: the byte size of the frame); control items use `controlCost`.
    @discardableResult
    public func enqueue(_ delivery: RealtimeDelivery, cost: Int) -> EnqueueOutcome {
        let kind = Self.kind(of: delivery)
        let entry = Entry(delivery: delivery, cost: kind.isControl ? Self.controlCost : max(0, cost), kind: kind)
        let (outcome, handoff): (EnqueueOutcome, CheckedContinuation<RealtimeDelivery?, Never>?) = state.withLock { state in
            if state.finished { return (.finished, nil) }
            if let waiter = state.waiter {
                // The queue is empty whenever a consumer is waiting: hand off directly.
                state.waiter = nil
                state.counters.accepted += 1
                return (.accepted, waiter.continuation)
            }
            return (insert(entry, into: &state), nil)
        }
        handoff?.resume(returning: delivery)
        return outcome
    }

    /// Awaits the next item. Returns `nil` when finished, when the calling task is
    /// cancelled (no item is consumed), or for a concurrent second consumer.
    public func next() async -> RealtimeDelivery? {
        if Task.isCancelled { return nil }
        let token: UInt64 = state.withLock { state in
            state.nextToken &+= 1
            return state.nextToken
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RealtimeDelivery?, Never>) in
                enum Immediate { case item(RealtimeDelivery), none, wait }
                let immediate: Immediate = state.withLock { state in
                    if let entry = state.popFront() { return .item(entry.delivery) }
                    if state.finished || Task.isCancelled || state.waiter != nil { return .none }
                    state.waiter = (token, continuation)
                    return .wait
                }
                switch immediate {
                case .item(let delivery): continuation.resume(returning: delivery)
                case .none: continuation.resume(returning: nil)
                case .wait: break
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<RealtimeDelivery?, Never>? = state.withLock { state in
                guard let waiter = state.waiter, waiter.token == token else { return nil }
                state.waiter = nil
                return waiter.continuation
            }
            waiter?.resume(returning: nil)
        }
    }

    /// Discards queued items and finishes. The consumer receives `final` (if any) and
    /// then `nil` forever. Idempotent; later `enqueue` calls return `.finished`.
    public func finish(final: RealtimeDelivery? = nil) {
        let waiter: CheckedContinuation<RealtimeDelivery?, Never>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            state.entries.removeAll()
            state.head = 0
            state.bytes = 0
            let waiter = state.waiter?.continuation
            state.waiter = nil
            if waiter == nil, let final {
                state.entries.append(Entry(delivery: final, cost: Self.controlCost, kind: .state))
                state.bytes = Self.controlCost
            }
            return waiter
        }
        waiter?.resume(returning: final)
    }

    // MARK: - Policy

    private func insert(_ entry: Entry, into state: inout State) -> EnqueueOutcome {
        switch entry.kind {
        case .state:
            if let last = state.live.last, last.kind == .state {
                state.replace(at: state.entries.count - 1, with: entry)
                state.counters.coalesced += 1
                return .coalesced
            }
            return appendControl(entry, into: &state)
        case .resynchronize:
            supersedeResynchronization(with: entry, in: &state)
            return appendControl(entry, into: &state)
        case .typing, .unhandled:
            if let index = state.live.lastIndex(where: { $0.kind == entry.kind }) {
                state.replace(at: index, with: entry)
                state.counters.coalesced += 1
                return .coalesced
            }
            guard fitsData(entry.cost, state) else {
                state.counters.droppedEphemeral += 1
                return .droppedEphemeral
            }
            state.append(entry)
            state.counters.accepted += 1
            return .accepted
        case .status:
            if let index = state.live.lastIndex(where: { $0.kind == entry.kind }) {
                state.replace(at: index, with: entry)
                state.counters.coalesced += 1
                return .coalesced
            }
            return admitDurable(entry, into: &state)
        case .viewed:
            if let index = state.live.lastIndex(where: { $0.kind == .viewed }),
               case .event(.channelsViewed(let queued)) = state.entries[index].delivery,
               case .event(.channelsViewed(let incoming)) = entry.delivery {
                let merged = queued.merging(incoming) { _, new in new }
                if merged.count <= RealtimeFrameDecoder.maximumViewedChannels {
                    let added = merged.count - queued.count
                    let cost = max(state.entries[index].cost, entry.cost) + 48 * added
                    if state.bytes - state.entries[index].cost + cost <= byteLimit - Self.controlReserve * Self.controlCost {
                        state.replace(at: index, with: Entry(delivery: .event(.channelsViewed(merged)), cost: cost,
                                                             kind: .viewed))
                        state.counters.coalesced += 1
                        return .coalesced
                    }
                }
            }
            return admitDurable(entry, into: &state)
        case .durable:
            return admitDurable(entry, into: &state)
        }
    }

    private func fitsData(_ cost: Int, _ state: State) -> Bool {
        state.count + 1 <= countLimit - Self.controlReserve
            && state.bytes + cost <= byteLimit - Self.controlReserve * Self.controlCost
    }

    private func admitDurable(_ entry: Entry, into state: inout State) -> EnqueueOutcome {
        if fitsData(entry.cost, state) {
            state.append(entry)
            state.counters.accepted += 1
            return .accepted
        }
        overflow(&state)
        guard fitsData(entry.cost, state) else {
            state.counters.droppedDurable += 1
            return .overflowed(accepted: false)
        }
        state.append(entry)
        state.counters.accepted += 1
        return .overflowed(accepted: true)
    }

    private func appendControl(_ entry: Entry, into state: inout State) -> EnqueueOutcome {
        if state.count + 1 > countLimit || state.bytes + entry.cost > byteLimit {
            overflow(&state)
        }
        state.append(entry)
        state.counters.accepted += 1
        return .accepted
    }

    /// Drops every queued durable item and appends exactly one overflow marker.
    /// Older resynchronization markers other than `.initialConnection` are subsumed;
    /// adjacent state items collapse to the latest.
    private func overflow(_ state: inout State) {
        let durable = state.live.reduce(0) { $0 + ($1.kind.isDurableData ? 1 : 0) }
        _ = state.compact { entry in
            switch entry.kind {
            case .durable, .status, .viewed:
                return false
            case .resynchronize:
                if case .resynchronize(.initialConnection) = entry.delivery { return true }
                return false
            default:
                return true
            }
        }
        var collapsed: [Entry] = []
        collapsed.reserveCapacity(state.count)
        for entry in state.live {
            if entry.kind == .state, let last = collapsed.last, last.kind == .state {
                collapsed[collapsed.count - 1] = entry
            } else {
                collapsed.append(entry)
            }
        }
        state.entries = collapsed
        state.head = 0
        state.bytes = collapsed.reduce(0) { $0 + $1.cost }
        state.counters.droppedDurable += durable
        state.counters.overflowMarkers += 1
        state.append(Entry(delivery: .resynchronize(.mailboxOverflow), cost: Self.controlCost, kind: .resynchronize))
    }

    /// A new marker supersedes the most recent queued marker when no durable data was
    /// queued after it: Core would reconcile at the later position anyway. A queued
    /// `.initialConnection` marker is never removed.
    private func supersedeResynchronization(with entry: Entry, in state: inout State) {
        guard let index = state.live.lastIndex(where: { $0.kind == .resynchronize }) else { return }
        if case .resynchronize(.initialConnection) = state.entries[index].delivery { return }
        let dataAfter = state.entries[(index + 1)...].contains { $0.kind.isDurableData }
        guard !dataAfter else { return }
        state.entries.remove(at: index)
        state.bytes -= Self.controlCost
        state.counters.coalesced += 1
    }

    private static func kind(of delivery: RealtimeDelivery) -> Kind {
        switch delivery {
        case .state: .state
        case .resynchronize: .resynchronize
        case .event(let event):
            switch event {
            case .typing(let user, let channel, let parent): .typing(user, channel, parent)
            case .statusChanged(let user, _): .status(user)
            case .channelsViewed: .viewed
            case .unhandled(let name): .unhandled(name)
            default: .durable
            }
        }
    }
}
