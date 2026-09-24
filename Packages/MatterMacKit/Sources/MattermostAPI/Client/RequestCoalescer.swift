import os

/// In-flight deduplication of identical safe reads (SPEC §9).
///
/// Callers presenting the same key while an operation is in flight join it instead
/// of starting another network request. The shared operation runs in one
/// unstructured task owned by the entry; each joiner waits on its own continuation.
///
/// Cancellation: a cancelled joiner is removed and resumed with `.cancelled`
/// immediately; the shared operation keeps running while at least one joiner
/// remains, and is cancelled when the last joiner leaves. A later caller with the
/// same key then starts a fresh operation (the abandoned one's result is ignored).
///
/// Bounds: at most `maximumEntries` distinct operations and `maximumJoinersPerEntry`
/// joiners each; beyond that callers fail fast with `.overloaded` (consistent with
/// admission control, which would refuse the extra work anyway).
final class RequestCoalescer<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    typealias Outcome = Result<Value, APIError>

    private struct Entry: Sendable {
        let generation: UInt64
        var joiners: [UInt64: CheckedContinuation<Outcome, Never>]
        var task: Task<Void, Never>?
    }

    private enum JoinerState: Sendable {
        case pending
        case cancelledEarly
        case registered(Key)
    }

    private struct State: Sendable {
        var entries: [Key: Entry] = [:]
        var joiners: [UInt64: JoinerState] = [:]
        var nextID: UInt64 = 0
    }

    let maximumEntries: Int
    let maximumJoinersPerEntry: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(maximumEntries: Int, maximumJoinersPerEntry: Int) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumJoinersPerEntry = max(1, maximumJoinersPerEntry)
    }

    /// Number of distinct in-flight operations (for tests and debug counters).
    var inFlightCount: Int { state.withLock { $0.entries.count } }
    var joinerCount: Int { state.withLock { $0.joiners.count } }

    func run(key: Key, operation: @escaping @Sendable () async -> Outcome) async throws(APIError) -> Value {
        if Task.isCancelled { throw .cancelled }
        let joinerID = state.withLock { state -> UInt64 in
            state.nextID &+= 1
            state.joiners[state.nextID] = .pending
            return state.nextID
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                register(joinerID, key: key, continuation: continuation, operation: operation)
            }
        } onCancel: {
            cancel(joinerID)
        }
        return try outcome.get()
    }

    private enum Decision: Sendable {
        case cancelled
        case overloaded
        case joined
        case lead(UInt64)
    }

    private func register(_ joinerID: UInt64, key: Key, continuation: CheckedContinuation<Outcome, Never>,
                          operation: @escaping @Sendable () async -> Outcome) {
        let maximumEntries = self.maximumEntries
        let maximumJoiners = self.maximumJoinersPerEntry
        let decision = state.withLock { state -> Decision in
            if case .cancelledEarly = state.joiners[joinerID] {
                state.joiners[joinerID] = nil
                return .cancelled
            }
            if var entry = state.entries[key] {
                guard entry.joiners.count < maximumJoiners else {
                    state.joiners[joinerID] = nil
                    return .overloaded
                }
                entry.joiners[joinerID] = continuation
                state.entries[key] = entry
                state.joiners[joinerID] = .registered(key)
                return .joined
            }
            guard state.entries.count < maximumEntries else {
                state.joiners[joinerID] = nil
                return .overloaded
            }
            state.nextID &+= 1
            let generation = state.nextID
            state.entries[key] = Entry(generation: generation, joiners: [joinerID: continuation], task: nil)
            state.joiners[joinerID] = .registered(key)
            return .lead(generation)
        }
        switch decision {
        case .cancelled:
            continuation.resume(returning: .failure(.cancelled))
        case .overloaded:
            continuation.resume(returning: .failure(.overloaded))
        case .joined:
            break
        case .lead(let generation):
            let task = Task { [self] in
                let outcome = await operation()
                finish(key: key, generation: generation, outcome: outcome)
            }
            let abandoned = state.withLock { state -> Bool in
                guard var entry = state.entries[key], entry.generation == generation else { return true }
                entry.task = task
                state.entries[key] = entry
                return false
            }
            // Every joiner left (or the operation already finished) before the task
            // handle was stored: cancelling a finished task is harmless.
            if abandoned { task.cancel() }
        }
    }

    private enum CancelAction: Sendable {
        case none
        case resume(CheckedContinuation<Outcome, Never>, cancelShared: Task<Void, Never>?)
    }

    private func cancel(_ joinerID: UInt64) {
        let action = state.withLock { state -> CancelAction in
            switch state.joiners[joinerID] {
            case .none, .cancelledEarly:
                return .none
            case .pending:
                state.joiners[joinerID] = .cancelledEarly
                return .none
            case .registered(let key):
                state.joiners[joinerID] = nil
                guard var entry = state.entries[key], let continuation = entry.joiners.removeValue(forKey: joinerID) else {
                    return .none
                }
                if entry.joiners.isEmpty {
                    state.entries[key] = nil
                    return .resume(continuation, cancelShared: entry.task)
                }
                state.entries[key] = entry
                return .resume(continuation, cancelShared: nil)
            }
        }
        if case .resume(let continuation, let shared) = action {
            shared?.cancel()
            continuation.resume(returning: .failure(.cancelled))
        }
    }

    private func finish(key: Key, generation: UInt64, outcome: Outcome) {
        let joiners = state.withLock { state -> [CheckedContinuation<Outcome, Never>] in
            guard let entry = state.entries[key], entry.generation == generation else { return [] }
            state.entries[key] = nil
            for id in entry.joiners.keys { state.joiners[id] = nil }
            return Array(entry.joiners.values)
        }
        for continuation in joiners { continuation.resume(returning: outcome) }
    }
}
