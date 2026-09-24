public import MatterMacModels

/// A bounded, ordered slice of one conversation's history (channel or thread) as
/// retained in memory. Gaps are explicit: `hasOlder`/`hasNewer` mean "the server may
/// have posts beyond this edge that we do not hold" — an evicted range is never
/// presented as an empty range (SPEC §12).
public struct HistoryWindow: Sendable {
    public struct Entry: Hashable, Sendable {
        public let id: PostID
        public let createAt: MattermostTimestamp

        public init(id: PostID, createAt: MattermostTimestamp) {
            self.id = id
            self.createAt = createAt
        }

        static func ordered(_ lhs: Entry, _ rhs: Entry) -> Bool {
            lhs.createAt == rhs.createAt ? lhs.id < rhs.id : lhs.createAt < rhs.createAt
        }
    }

    public enum EdgeState: Hashable, Sendable {
        case idle
        case loading(generation: UInt64)
        case failed(UserFacingError)
    }

    public let target: TimelineTarget
    /// Oldest → newest.
    public private(set) var entries: [Entry] = []
    public var hasOlder = true
    public var hasNewer = false
    public var olderState: EdgeState = .idle
    public var newerState: EdgeState = .idle
    /// Contents may be outdated (reconnect/resync pending).
    public var isStale = false
    /// `true` once an initial page has been loaded.
    public var isLoaded = false
    /// First unread post at the moment the conversation was opened (for the
    /// "New messages" line); not updated by later arrivals.
    public var unreadBoundary: PostID?
    public var initialLoad: EdgeState = .idle
    /// Monotonic per-window request generation; results carrying an older generation
    /// are discarded.
    public private(set) var generation: UInt64 = 0
    /// Posts whose collapsed long message the user expanded (bounded).
    public var expanded: Set<PostID> = []
    public var lastAccess: UInt64 = 0

    private var index: Set<PostID> = []

    public init(target: TimelineTarget) {
        self.target = target
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var ids: [PostID] { entries.map(\.id) }
    public var oldest: Entry? { entries.first }
    public var newest: Entry? { entries.last }
    public func contains(_ id: PostID) -> Bool { index.contains(id) }

    public mutating func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Replaces all entries (initial load or authoritative refresh). Returns
    /// (added, removed) IDs so the caller can adjust store references.
    public mutating func replace(with newEntries: [Entry], hasOlder: Bool, hasNewer: Bool)
        -> (added: [PostID], removed: [PostID])
    {
        let sorted = Self.normalized(newEntries)
        let newIDs = Set(sorted.map(\.id))
        let removed = entries.map(\.id).filter { !newIDs.contains($0) }
        let added = sorted.map(\.id).filter { !index.contains($0) }
        entries = sorted
        index = newIDs
        self.hasOlder = hasOlder
        self.hasNewer = hasNewer
        isLoaded = true
        isStale = false
        return (added, removed)
    }

    /// Merges posts into the window keeping order. Posts outside the currently known
    /// range extend it only on the matching side (`extendsOlder` / `extendsNewer`).
    @discardableResult
    public mutating func merge(_ newEntries: [Entry]) -> [PostID] {
        var added: [PostID] = []
        for entry in newEntries where !index.contains(entry.id) {
            added.append(entry.id)
            index.insert(entry.id)
            entries.append(entry)
        }
        if !added.isEmpty { entries.sort(by: Entry.ordered) }
        return added
    }

    /// Inserts a live post only when the window is at the live edge. Returns `true`
    /// when inserted.
    public mutating func insertLive(_ entry: Entry) -> Bool {
        guard !hasNewer, !index.contains(entry.id) else { return false }
        index.insert(entry.id)
        if let last = entries.last, Entry.ordered(entry, last) {
            entries.append(entry)
            entries.sort(by: Entry.ordered)
        } else {
            entries.append(entry)
        }
        return true
    }

    @discardableResult
    public mutating func remove(_ id: PostID) -> Bool {
        guard index.remove(id) != nil else { return false }
        entries.removeAll { $0.id == id }
        expanded.remove(id)
        return true
    }

    /// Trims the window to `maximum` entries, removing from the side farther from
    /// `anchor` (or the older side when there is no anchor). The trimmed side is marked
    /// as having a gap. Returns removed IDs.
    public mutating func trim(toCount maximum: Int, keepingAround anchor: PostID?) -> [PostID] {
        guard entries.count > maximum else { return [] }
        let excess = entries.count - maximum
        let anchorIndex = anchor.flatMap { id in entries.firstIndex { $0.id == id } } ?? (entries.count - 1)
        let distanceToStart = anchorIndex
        let distanceToEnd = entries.count - 1 - anchorIndex
        var removed: [Entry] = []
        var remaining = excess
        // Trim from the farther side first, then the other side if still needed.
        func trimOlder(_ n: Int) {
            guard n > 0 else { return }
            removed.append(contentsOf: entries.prefix(n))
            entries.removeFirst(n)
            hasOlder = true
        }
        func trimNewer(_ n: Int) {
            guard n > 0 else { return }
            removed.append(contentsOf: entries.suffix(n))
            entries.removeLast(n)
            hasNewer = true
        }
        if distanceToStart >= distanceToEnd {
            let n = min(remaining, max(0, distanceToStart))
            trimOlder(n)
            remaining -= n
            trimNewer(min(remaining, entries.count))
        } else {
            let n = min(remaining, max(0, distanceToEnd))
            trimNewer(n)
            remaining -= n
            trimOlder(min(remaining, entries.count))
        }
        for entry in removed {
            index.remove(entry.id)
            expanded.remove(entry.id)
        }
        return removed.map(\.id)
    }

    /// Removes everything (e.g. purge on revocation or authoritative jump). Returns IDs.
    public mutating func removeAll() -> [PostID] {
        let ids = entries.map(\.id)
        entries.removeAll()
        index.removeAll()
        expanded.removeAll()
        hasOlder = true
        hasNewer = false
        isLoaded = false
        return ids
    }

    static func normalized(_ entries: [Entry]) -> [Entry] {
        var seen = Set<PostID>()
        return entries.filter { seen.insert($0.id).inserted }.sorted(by: Entry.ordered)
    }
}
