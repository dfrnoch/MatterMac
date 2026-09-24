/// A deterministic, cost-tracked LRU cache with strict count and byte limits.
///
/// Unlike `NSCache`, limits are enforced synchronously on every insert: after
/// `set` returns, `count <= countLimit` and `totalCost <= costLimit` always hold (a
/// single item larger than `costLimit` is rejected). O(1) get/set/remove using an
/// index-linked list over a contiguous node array, so there is no per-entry class
/// allocation. Not thread-safe: owned by exactly one actor or the main actor.
public struct CostLRU<Key: Hashable, Value> {
    fileprivate struct Node {
        var key: Key
        var value: Value
        var cost: Int
        var previous: Int
        var next: Int
    }

    public private(set) var countLimit: Int
    public private(set) var costLimit: Int
    public private(set) var totalCost = 0

    private var nodes: [Node?] = []
    private var freeList: [Int] = []
    private var index: [Key: Int] = [:]
    /// Most recently used.
    private var head = -1
    /// Least recently used.
    private var tail = -1

    public init(countLimit: Int, costLimit: Int) {
        precondition(countLimit > 0 && costLimit > 0)
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    public var count: Int { index.count }
    public var isEmpty: Bool { index.isEmpty }

    /// Returns the value and marks it most recently used.
    public mutating func value(for key: Key) -> Value? {
        guard let slot = index[key] else { return nil }
        moveToFront(slot)
        return nodes[slot]!.value
    }

    /// Returns the value without affecting recency.
    public func peek(_ key: Key) -> Value? {
        guard let slot = index[key] else { return nil }
        return nodes[slot]!.value
    }

    public func contains(_ key: Key) -> Bool { index[key] != nil }

    /// Inserts or replaces a value. Returns the evicted entries (oldest first) so owners
    /// can release associated resources. Returns `nil` if the item alone exceeds the
    /// cost limit and was not stored (any previous value for the key is removed).
    @discardableResult
    public mutating func set(_ value: Value, for key: Key, cost: Int) -> [(key: Key, value: Value)]? {
        let cost = max(cost, 0)
        if let slot = index[key] {
            totalCost -= nodes[slot]!.cost
            index[key] = nil
            unlink(slot)
            release(slot)
        }
        guard cost <= costLimit else { return nil }
        var evicted: [(key: Key, value: Value)] = []
        while !index.isEmpty && (index.count + 1 > countLimit || totalCost + cost > costLimit) {
            if let removed = removeLeastRecentlyUsed() { evicted.append(removed) }
        }
        let slot = allocate(Node(key: key, value: value, cost: cost, previous: -1, next: -1))
        index[key] = slot
        totalCost += cost
        linkFront(slot)
        return evicted
    }

    @discardableResult
    public mutating func removeValue(for key: Key) -> Value? {
        guard let slot = index[key] else { return nil }
        let node = nodes[slot]!
        totalCost -= node.cost
        index[key] = nil
        unlink(slot)
        release(slot)
        return node.value
    }

    @discardableResult
    public mutating func removeLeastRecentlyUsed() -> (key: Key, value: Value)? {
        guard tail >= 0 else { return nil }
        let slot = tail
        let node = nodes[slot]!
        totalCost -= node.cost
        index[node.key] = nil
        unlink(slot)
        release(slot)
        return (node.key, node.value)
    }

    /// Evicts least-recently-used entries until cost is at most `targetCost`.
    @discardableResult
    public mutating func trim(toCost targetCost: Int) -> [(key: Key, value: Value)] {
        var evicted: [(key: Key, value: Value)] = []
        while totalCost > targetCost, let removed = removeLeastRecentlyUsed() { evicted.append(removed) }
        return evicted
    }

    /// Removes every entry matching `predicate` (O(n); for purges, not hot paths).
    public mutating func removeAll(where predicate: (Key, Value) -> Bool) {
        for (key, slot) in index where predicate(key, nodes[slot]!.value) {
            _ = removeValue(for: key)
        }
    }

    public mutating func removeAll() {
        nodes.removeAll()
        freeList.removeAll()
        index.removeAll()
        head = -1
        tail = -1
        totalCost = 0
    }

    public mutating func updateLimits(countLimit: Int, costLimit: Int) {
        precondition(countLimit > 0 && costLimit > 0)
        self.countLimit = countLimit
        self.costLimit = costLimit
        while index.count > countLimit || totalCost > costLimit { _ = removeLeastRecentlyUsed() }
    }

    /// Keys from most to least recently used (for tests and diagnostics).
    public var keysByRecency: [Key] {
        var keys: [Key] = []
        var cursor = head
        while cursor >= 0 {
            keys.append(nodes[cursor]!.key)
            cursor = nodes[cursor]!.next
        }
        return keys
    }

    // MARK: - Linked list

    private mutating func allocate(_ node: Node) -> Int {
        if let slot = freeList.popLast() {
            nodes[slot] = node
            return slot
        }
        nodes.append(node)
        return nodes.count - 1
    }

    /// Call after the key was removed from `index` and the slot unlinked.
    private mutating func release(_ slot: Int) {
        nodes[slot] = nil
        if index.isEmpty {
            // Drop storage entirely so a past burst does not pin node capacity.
            nodes.removeAll()
            freeList.removeAll()
            head = -1
            tail = -1
        } else {
            freeList.append(slot)
        }
    }

    private mutating func linkFront(_ slot: Int) {
        nodes[slot]!.previous = -1
        nodes[slot]!.next = head
        if head >= 0 { nodes[head]!.previous = slot }
        head = slot
        if tail < 0 { tail = slot }
    }

    private mutating func unlink(_ slot: Int) {
        let previous = nodes[slot]!.previous
        let next = nodes[slot]!.next
        if previous >= 0 { nodes[previous]!.next = next } else { head = next }
        if next >= 0 { nodes[next]!.previous = previous } else { tail = previous }
        nodes[slot]!.previous = -1
        nodes[slot]!.next = -1
    }

    private mutating func moveToFront(_ slot: Int) {
        guard head != slot else { return }
        unlink(slot)
        linkFront(slot)
    }
}


extension CostLRU: Sendable where Key: Sendable, Value: Sendable {}
extension CostLRU.Node: Sendable where Key: Sendable, Value: Sendable {}
