import Foundation
import MatterMacCore

/// Row changes between two consecutive snapshots of the same timeline, keyed by
/// `TimelineItemID` and `revision`.
///
/// Application order (NSTableView semantics inside `beginUpdates`/`endUpdates`):
/// 1. `removed` — indexes in the old list.
/// 2. `moves` — sequential `moveRow(at:to:)` in the intermediate list (old minus removed).
/// 3. `inserted` — indexes in the new list.
/// 4. `changed` — indexes in the new list of rows whose revision changed; reloaded after
///    `endUpdates` together with their height.
nonisolated struct TimelineDiff: Equatable, Sendable {
    struct Move: Equatable, Sendable {
        let from: Int
        let to: Int
    }

    var removed = IndexSet()
    var inserted = IndexSet()
    var moves: [Move] = []
    var changed = IndexSet()
    /// True when applying row operations would be more expensive than one bounded
    /// replacement: more than half of the rows change, or too many moves.
    var isLarge = false

    var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && moves.isEmpty && changed.isEmpty }
    var operationCount: Int { removed.count + inserted.count + moves.count + changed.count }

    /// Moves beyond this count make the diff "large" (each move is O(n) to plan).
    static let maximumMoves = 64
    /// Tables smaller than this are always updated incrementally.
    static let minimumRowsForReplacement = 32

    static func compute(old: [TimelineItem], new: [TimelineItem]) -> TimelineDiff {
        var diff = TimelineDiff()
        var oldIndex: [TimelineItemID: Int] = [:]
        oldIndex.reserveCapacity(old.count)
        for (index, item) in old.enumerated() where oldIndex[item.id] == nil { oldIndex[item.id] = index }
        var newIndex: [TimelineItemID: Int] = [:]
        newIndex.reserveCapacity(new.count)
        for (index, item) in new.enumerated() where newIndex[item.id] == nil { newIndex[item.id] = index }

        for (index, item) in old.enumerated() where newIndex[item.id] == nil { diff.removed.insert(index) }
        for (index, item) in new.enumerated() {
            if let previous = oldIndex[item.id] {
                if old[previous].revision != item.revision { diff.changed.insert(index) }
            } else {
                diff.inserted.insert(index)
            }
        }

        // Common items in old order and in new order.
        let oldCommon = old.filter { newIndex[$0.id] != nil }.map(\.id)
        let newCommon = new.filter { oldIndex[$0.id] != nil }.map(\.id)
        if oldCommon != newCommon {
            diff.moves = planMoves(from: oldCommon, to: newCommon)
            if diff.moves.count > maximumMoves { diff.isLarge = true }
        }

        let rows = max(old.count, new.count)
        if rows >= minimumRowsForReplacement, diff.operationCount * 2 > rows { diff.isLarge = true }
        return diff
    }

    /// Minimal sequential moves: items on a longest increasing subsequence (by old
    /// position) stay; every other item is moved directly after its new predecessor.
    static func planMoves(from source: [TimelineItemID], to target: [TimelineItemID]) -> [Move] {
        var sourcePosition: [TimelineItemID: Int] = [:]
        for (index, id) in source.enumerated() { sourcePosition[id] = index }
        let sequence = target.map { sourcePosition[$0] ?? 0 }
        let stable = longestIncreasingSubsequence(sequence)

        var current = source
        var moves: [Move] = []
        for (targetIndex, id) in target.enumerated() where !stable.contains(targetIndex) {
            guard let from = current.firstIndex(of: id) else { continue }
            current.remove(at: from)
            let to: Int
            if targetIndex == 0 {
                to = 0
            } else if let predecessor = current.firstIndex(of: target[targetIndex - 1]) {
                to = predecessor + 1
            } else {
                to = min(from, current.count)
            }
            current.insert(id, at: to)
            if from != to { moves.append(Move(from: from, to: to)) }
            if moves.count > maximumMoves { break }
        }
        return moves
    }

    /// Indexes (into `sequence`) of one longest strictly increasing subsequence.
    static func longestIncreasingSubsequence(_ sequence: [Int]) -> Set<Int> {
        guard !sequence.isEmpty else { return [] }
        var tailIndexes: [Int] = []
        var predecessors = Array(repeating: -1, count: sequence.count)
        for (index, value) in sequence.enumerated() {
            var low = 0
            var high = tailIndexes.count
            while low < high {
                let mid = (low + high) / 2
                if sequence[tailIndexes[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { predecessors[index] = tailIndexes[low - 1] }
            if low == tailIndexes.count { tailIndexes.append(index) } else { tailIndexes[low] = index }
        }
        var result = Set<Int>()
        var cursor = tailIndexes.last ?? -1
        while cursor >= 0 {
            result.insert(cursor)
            cursor = predecessors[cursor]
        }
        return result
    }
}
