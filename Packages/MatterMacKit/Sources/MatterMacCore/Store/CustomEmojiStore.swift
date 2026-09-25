public import Foundation
public import MatterMacModels

/// Session-scoped custom emoji names (SPEC §15): which `:name:` resolves to which
/// server emoji id. In memory only, and bounded twice:
///
/// - `known`: name → emoji, a cost-tracked LRU (`ResourceBudget.customEmojiNames`).
/// - `misses`: names the server did not know (or that failed to resolve), with the
///   time recorded; an LRU (`customEmojiMisses`) whose entries expire on access after
///   `missLifetime`, so a later upload is picked up without scanning timers.
/// - `wanted`: names waiting for the next batched lookup, at most `maximumWanted`;
///   further names are simply asked for again on a later timeline build.
///
/// Owned by one `ServerSession` (actor-isolated value).
public struct CustomEmojiStore: Sendable {
    public enum Resolution: Equatable, Sendable {
        case custom(CustomEmoji)
        /// The server has no such emoji (recently checked).
        case missing
        /// Not looked up yet.
        case unknown
    }

    private var known: CostLRU<String, CustomEmoji>
    private var misses: CostLRU<String, Date>
    public private(set) var wanted: [String] = []
    private var wantedSet: Set<String> = []
    public static let maximumWanted = ResourceBudget.standard.customEmojiQueuedNames
    private let wantedLimit: Int
    /// How long a "not found" answer is trusted before the name is asked for again.
    public static let missLifetime: TimeInterval = 10 * 60

    public init(budget: ResourceBudget) {
        wantedLimit = max(0, budget.customEmojiQueuedNames)
        let names = max(1, budget.customEmojiNames)
        known = CostLRU(countLimit: names, costLimit: names * 256)
        let misses = max(1, budget.customEmojiMisses)
        self.misses = CostLRU(countLimit: misses, costLimit: misses * 128)
    }

    public var knownCount: Int { known.count }
    public var missCount: Int { misses.count }

    /// Looks a (lowercased) name up; expired misses become `.unknown` again.
    public mutating func resolve(_ name: String, now: Date) -> Resolution {
        if let emoji = known.value(for: name) { return .custom(emoji) }
        if let checked = misses.peek(name) {
            if now.timeIntervalSince(checked) < Self.missLifetime { return .missing }
            misses.removeValue(for: name)
        }
        return .unknown
    }

    public func peek(_ name: String) -> CustomEmoji? { known.peek(name) }

    /// `resolve` without side effects (no recency update, no expiry removal), for
    /// pure snapshot builders.
    public func peekResolution(_ name: String, now: Date) -> Resolution {
        if let emoji = known.peek(name) { return .custom(emoji) }
        if let checked = misses.peek(name), now.timeIntervalSince(checked) < Self.missLifetime { return .missing }
        return .unknown
    }

    /// Records emoji the server returned (post metadata, lookups, lists, events).
    public mutating func insert(_ emoji: CustomEmoji) {
        misses.removeValue(for: emoji.name)
        known.set(emoji, for: emoji.name, cost: emoji.estimatedCost)
    }

    public mutating func insert(contentsOf list: some Sequence<CustomEmoji>) {
        for emoji in list { insert(emoji) }
    }

    /// Queues a name for the next batched lookup. Returns `false` when it is already
    /// known, recently missing, queued, or the queue is full.
    @discardableResult
    public mutating func want(_ name: String, now: Date) -> Bool {
        guard resolve(name, now: now) == .unknown, wantedSet.count < wantedLimit,
              wantedSet.insert(name).inserted else { return false }
        wanted.append(name)
        return true
    }

    /// Removes up to `limit` queued names for one request.
    public mutating func takeWanted(limit: Int) -> [String] {
        let batch = Array(wanted.prefix(max(0, limit)))
        wanted.removeFirst(batch.count)
        wantedSet.subtract(batch)
        return batch
    }

    /// Answers a lookup: `found` become known; requested names absent from it are
    /// remembered as missing (and so are all of them after a failed lookup, which
    /// keeps a failing server from being asked on every timeline build).
    public mutating func record(requested: [String], found: [CustomEmoji], now: Date) {
        insert(contentsOf: found)
        let foundNames = Set(found.map(\.name))
        for name in requested where !foundNames.contains(name) {
            misses.set(now, for: name, cost: 32 + name.utf8.count)
        }
    }

    public mutating func removeAll() {
        known.removeAll()
        misses.removeAll()
        wanted.removeAll()
        wantedSet.removeAll()
    }
}
