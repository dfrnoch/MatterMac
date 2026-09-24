import Testing
@testable import MatterMacCore
import MatterMacModels

@Suite("CostLRU")
struct CostLRUTests {
    @Test func enforcesCountLimitEvictingLeastRecentlyUsed() {
        var lru = CostLRU<Int, String>(countLimit: 3, costLimit: 1_000)
        lru.set("a", for: 1, cost: 1)
        lru.set("b", for: 2, cost: 1)
        lru.set("c", for: 3, cost: 1)
        _ = lru.value(for: 1) // 1 becomes most recent
        let evicted = lru.set("d", for: 4, cost: 1)
        #expect(evicted?.map(\.key) == [2])
        #expect(lru.count == 3)
        #expect(lru.keysByRecency == [4, 1, 3])
    }

    @Test func enforcesCostLimitStrictly() {
        var lru = CostLRU<Int, Int>(countLimit: 100, costLimit: 10)
        for i in 0..<10 { lru.set(i, for: i, cost: 3) }
        #expect(lru.totalCost <= 10)
        #expect(lru.count == 3)
        #expect(lru.keysByRecency == [9, 8, 7])
    }

    @Test func rejectsSingleOversizedItemAndRemovesPreviousValue() {
        var lru = CostLRU<String, Int>(countLimit: 10, costLimit: 10)
        lru.set(1, for: "k", cost: 5)
        let result = lru.set(2, for: "k", cost: 11)
        #expect(result == nil)
        #expect(lru.peek("k") == nil)
        #expect(lru.totalCost == 0)
    }

    @Test func replacingValueUpdatesCost() {
        var lru = CostLRU<String, Int>(countLimit: 10, costLimit: 100)
        lru.set(1, for: "k", cost: 50)
        lru.set(2, for: "k", cost: 10)
        #expect(lru.totalCost == 10)
        #expect(lru.count == 1)
        #expect(lru.peek("k") == 2)
    }

    @Test func trimAndRemoveAllReleaseStorage() {
        var lru = CostLRU<Int, Int>(countLimit: 1_000, costLimit: 1_000_000)
        for i in 0..<500 { lru.set(i, for: i, cost: 100) }
        lru.trim(toCost: 1_000)
        #expect(lru.count == 10)
        #expect(lru.totalCost == 1_000)
        lru.removeAll { key, _ in key % 2 == 0 }
        #expect(lru.count == 5)
        while lru.removeLeastRecentlyUsed() != nil {}
        #expect(lru.isEmpty && lru.totalCost == 0)
    }

    @Test func updateLimitsEvictsImmediately() {
        var lru = CostLRU<Int, Int>(countLimit: 10, costLimit: 100)
        for i in 0..<10 { lru.set(i, for: i, cost: 10) }
        lru.updateLimits(countLimit: 4, costLimit: 100)
        #expect(lru.count == 4)
    }
}

@Suite("UnsentWorkLedger")
struct UnsentWorkLedgerTests {
    func ledger(bytes: Int = 100, operations: Int = 3) -> UnsentWorkLedger {
        var budget = ResourceBudget()
        budget.unsentText = .init(count: operations, bytes: bytes)
        return UnsentWorkLedger(budget: budget)
    }

    func key(_ n: Int) -> DraftKey {
        DraftKey(scope: AccountScope(server: ServerSlotID(1), user: UserID(unchecked: "u")),
                 channelID: ChannelID(unchecked: "c\(n)"), rootID: nil)
    }

    @Test func refusesGrowthBeyondBudgetButKeepsExistingDrafts() throws {
        let ledger = ledger()
        try ledger.updateDraft(key(1), bytes: 60)
        #expect(throws: UnsentWorkLedger.Refusal.textBudgetExceeded(limitBytes: 100)) {
            try ledger.updateDraft(key(2), bytes: 50)
        }
        // The first draft is untouched: nothing is ever evicted to make room.
        #expect(ledger.usage.draftBytes == 60)
        #expect(ledger.remainingBytes(forDraft: key(2)) == 40)
        // Shrinking always succeeds.
        try ledger.updateDraft(key(1), bytes: 10)
        #expect(ledger.usage.draftBytes == 10)
    }

    @Test func convertingDraftToPendingMovesBytesAtomically() throws {
        let ledger = ledger()
        try ledger.updateDraft(key(1), bytes: 90)
        let reservation = try ledger.convertDraftToPending(key(1), bytes: 90)
        #expect(ledger.usage.draftBytes == 0)
        #expect(ledger.usage.pendingBytes == 90)
        #expect(ledger.usage.pendingOperations == 1)
        ledger.release(reservation)
        #expect(ledger.usage.totalBytes == 0)
    }

    @Test func pendingOperationLimitIsEnforced() throws {
        let ledger = ledger(bytes: 1_000, operations: 2)
        _ = try ledger.convertDraftToPending(nil, bytes: 1)
        _ = try ledger.convertDraftToPending(nil, bytes: 1)
        #expect(throws: UnsentWorkLedger.Refusal.tooManyPendingOperations(limit: 2)) {
            _ = try ledger.convertDraftToPending(nil, bytes: 1)
        }
    }

    @MainActor @Test func draftStoreNeverEvictsAndRestoresSelection() throws {
        let ledger = ledger(bytes: 20)
        let store = DraftStore(ledger: ledger)
        try store.save(Draft(text: "hello", selectedRange: .init(location: 2, length: 1)), for: key(1))
        #expect(throws: UnsentWorkLedger.Refusal.self) {
            try store.save(Draft(text: String(repeating: "x", count: 30)), for: key(2))
        }
        #expect(store.draft(for: key(1))?.text == "hello")
        #expect(store.draft(for: key(1))?.selectedRange.location == 2)
        #expect(store.draft(for: key(2)) == nil)
        try store.save(Draft(text: ""), for: key(1))
        #expect(store.draft(for: key(1)) == nil)
        #expect(ledger.usage.draftBytes == 0)
    }

    @MainActor @Test func rejectedAdmissionRestoresPinnedDraftAtFullBudget() throws {
        let ledger = ledger(bytes: 20)
        let store = DraftStore(ledger: ledger)
        let draft = Draft(text: "pending edit", selectedRange: .init(location: 2, length: 1),
                          editingPost: PostID(unchecked: "p"))
        try store.save(draft, for: key(1))
        let reservation = try store.takeForSending(key(1))
        try store.save(Draft(text: "1234567"), for: key(2))
        #expect(ledger.usage.totalBytes == 20)
        #expect(store.draft(for: key(1)) == draft)
        #expect(throws: UnsentWorkLedger.Refusal.draftBeingSubmitted) {
            try store.save(Draft(text: "replacement"), for: key(1))
        }
        store.clear(key(1))
        store.finishSending(key(1), reservation: reservation, accepted: false)
        #expect(store.draft(for: key(1)) == draft)
        #expect(ledger.usage.draftBytes == 20)
        #expect(ledger.usage.pendingOperations == 0)
        let accepted = try store.takeForSending(key(1))
        store.finishSending(key(1), reservation: accepted, accepted: true)
        #expect(store.draft(for: key(1)) == nil)
        #expect(ledger.usage.totalBytes == 20)
        ledger.release(accepted)
        #expect(ledger.usage.totalBytes == 7)
    }

    @MainActor @Test func lateRejectionCannotRestoreSignedOutDraft() throws {
        let ledger = ledger()
        let store = DraftStore(ledger: ledger)
        try store.save(Draft(text: "discard me"), for: key(1))
        let reservation = try store.takeForSending(key(1))
        store.discardAll(for: key(1).scope)
        store.finishSending(key(1), reservation: reservation, accepted: false)
        #expect(store.draft(for: key(1)) == nil)
        #expect(ledger.usage.totalBytes == 0)
    }
}

@Suite("RetentionLedger")
struct RetentionLedgerTests {
    @Test func activeSessionGetsRemainderInactiveCappedAtQuarter() {
        var budget = ResourceBudget()
        budget.retainedPosts = .init(count: 1_000, bytes: 1_000_000)
        let ledger = RetentionLedger(budget: budget)
        let a = ServerSlotID(1), b = ServerSlotID(2)
        ledger.setActive(a)
        ledger.report(b, usage: .init(count: 100, bytes: 100_000))
        let activeAllowance = ledger.allowance(for: a)
        #expect(activeAllowance.count == 900)
        #expect(activeAllowance.bytes == 900_000)
        let inactiveAllowance = ledger.allowance(for: b)
        #expect(inactiveAllowance.count == 250)
        ledger.report(a, usage: .init(count: 900, bytes: 900_000))
        #expect(ledger.allowance(for: b).count == 100)
        ledger.remove(b)
        #expect(ledger.total.count == 900)
    }
}
