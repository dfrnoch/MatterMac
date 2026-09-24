import os
public import Foundation
public import MattermostAPI
public import MatterMacModels

/// Process-wide accounting for text the user has not yet successfully sent: drafts
/// and pending-send operations across all server sessions (SPEC §11, §15).
///
/// This is an *admission* budget, not a cache: nothing is ever evicted. When the
/// budget is reached, new input or new queued operations are refused with an
/// explanation, and existing unsent work stays intact until the user sends,
/// discards, or copies it.
public final class UnsentWorkLedger: Sendable {
    public struct Usage: Sendable, Hashable {
        public var draftBytes: Int
        public var pendingBytes: Int
        public var pendingOperations: Int
        public var imageBytes: Int
        public var totalBytes: Int { draftBytes + pendingBytes }
    }

    public enum Refusal: Error, Sendable, Hashable {
        case imageBudgetExceeded(limitBytes: Int)
        case textBudgetExceeded(limitBytes: Int)
        case tooManyPendingOperations(limit: Int)
        case draftBeingSubmitted
    }

    public struct Reservation: Hashable, Sendable {
        public let id: UInt64
        public let bytes: Int
    }

    private struct State {
        var drafts: [DraftKey: Int] = [:]
        var pending: [UInt64: Int] = [:]
        var imageBytes = 0
        var draftBytes = 0
        var pendingBytes = 0
        var nextID: UInt64 = 1
    }

    public let byteLimit: Int
    public let imageByteLimit: Int
    public let operationLimit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(budget: ResourceBudget) {
        self.byteLimit = budget.unsentText.bytes
        self.imageByteLimit = budget.pastedImageBytes
        self.operationLimit = budget.unsentText.count
    }

    public var usage: Usage {
        state.withLock { Usage(draftBytes: $0.draftBytes, pendingBytes: $0.pendingBytes, pendingOperations: $0.pending.count, imageBytes: $0.imageBytes) }
    }

    /// A lease follows the encoded data through drafts, pending sends and active
    /// requests. Removing a draft cannot release bytes still used by a cancelled upload.
    public func pastedImage(_ data: Data, typeIdentifier: String) throws -> UploadSource {
        let count = data.count
        let admitted = state.withLock { state in
            guard count <= imageByteLimit - state.imageBytes else { return false }
            state.imageBytes += count
            return true
        }
        guard admitted else { throw Refusal.imageBudgetExceeded(limitBytes: imageByteLimit) }
        do {
            return try UploadSource(pastedImage: data, typeIdentifier: typeIdentifier, maximumBytes: imageByteLimit) { [self] in
                state.withLock { $0.imageBytes -= count }
            }
        } catch {
            state.withLock { $0.imageBytes -= count }
            throw error
        }
    }

    /// Bytes still available to a draft that currently occupies `key`'s slot.
    public func remainingBytes(forDraft key: DraftKey) -> Int {
        state.withLock { state in
            let current = state.drafts[key] ?? 0
            if current == 0, state.drafts.count + state.pending.count >= operationLimit { return 0 }
            return byteLimit - (state.draftBytes + state.pendingBytes - current)
        }
    }

    /// Records the size of a draft. Shrinking always succeeds; growing past the budget
    /// is refused and the previous size stays accounted.
    public func updateDraft(_ key: DraftKey, bytes: Int) throws(Refusal) {
        let limit = byteLimit
        let refusal: Refusal? = state.withLock { state in
            let current = state.drafts[key] ?? 0
            if bytes > 0, current == 0, state.drafts.count + state.pending.count >= operationLimit {
                return .tooManyPendingOperations(limit: operationLimit)
            }
            let newTotal = state.draftBytes - current + bytes + state.pendingBytes
            if bytes > current && newTotal > limit { return .textBudgetExceeded(limitBytes: limit) }
            state.draftBytes += bytes - current
            if bytes == 0 { state.drafts[key] = nil } else { state.drafts[key] = bytes }
            return nil
        }
        if let refusal { throw refusal }
    }

    public func removeDraft(_ key: DraftKey) {
        state.withLock { state in
            if let current = state.drafts.removeValue(forKey: key) { state.draftBytes -= current }
        }
    }

    /// Moves a draft's bytes into a new pending operation atomically (sending a draft
    /// never fails for text-budget reasons, only for the operation-count limit).
    public func convertDraftToPending(_ key: DraftKey?, bytes: Int) throws(Refusal) -> Reservation {
        let byteLimit = byteLimit
        let operationLimit = operationLimit
        let result: Result<Reservation, Refusal> = state.withLock { state in
            let sourceExists = key.map { state.drafts[$0] != nil } ?? false
            guard state.drafts.count + state.pending.count - (sourceExists ? 1 : 0) < operationLimit else {
                return .failure(.tooManyPendingOperations(limit: operationLimit))
            }
            let released = key.flatMap { state.drafts[$0] } ?? 0
            let newTotal = state.draftBytes - released + state.pendingBytes + bytes
            if bytes > released && newTotal > byteLimit { return .failure(.textBudgetExceeded(limitBytes: byteLimit)) }
            if let key, let current = state.drafts.removeValue(forKey: key) { state.draftBytes -= current }
            let id = state.nextID
            state.nextID += 1
            state.pending[id] = bytes
            state.pendingBytes += bytes
            return .success(Reservation(id: id, bytes: bytes))
        }
        return try result.get()
    }

    /// Releases a pending operation's reservation (confirmed, or discarded by the user).
    public func release(_ reservation: Reservation) {
        state.withLock { state in
            if let cost = state.pending.removeValue(forKey: reservation.id) { state.pendingBytes -= cost }
        }
    }

    /// Rolls back admission without releasing bytes for another draft to consume.
    func restoreDraft(_ key: DraftKey, from reservation: Reservation) {
        state.withLock { state in
            guard let cost = state.pending.removeValue(forKey: reservation.id) else { return }
            precondition(state.drafts[key] == nil)
            state.pendingBytes -= cost
            state.drafts[key] = cost
            state.draftBytes += cost
        }
    }

    /// Drops everything for a scope on sign-out (after the user confirmed discarding).
    public func removeAll(for scope: AccountScope, pending reservations: [Reservation]) {
        state.withLock { state in
            for key in state.drafts.keys where key.scope == scope {
                if let cost = state.drafts.removeValue(forKey: key) { state.draftBytes -= cost }
            }
            for reservation in reservations {
                if let cost = state.pending.removeValue(forKey: reservation.id) { state.pendingBytes -= cost }
            }
        }
    }
}
