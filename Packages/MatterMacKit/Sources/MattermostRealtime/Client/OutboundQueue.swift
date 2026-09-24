import os

/// Bounded queue of encoded client actions for one socket's writer task.
///
/// Capacity: `limit` messages (each < 8 KiB, the server read limit). Producer: the
/// client actor (`offer` never suspends; returns `false` when full or finished).
/// Consumer: the socket's single writer task. `finish()` wakes the writer with `nil`.
final class OutboundQueue: Sendable {
    private struct State {
        var buffer: [String] = []
        var finished = false
        var waiter: CheckedContinuation<String?, Never>?
    }

    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func offer(_ message: String) -> Bool {
        let (accepted, waiter): (Bool, CheckedContinuation<String?, Never>?) = state.withLock { state in
            guard !state.finished else { return (false, nil) }
            if let waiter = state.waiter {
                state.waiter = nil
                return (true, waiter)
            }
            guard state.buffer.count < limit else { return (false, nil) }
            state.buffer.append(message)
            return (true, nil)
        }
        waiter?.resume(returning: message)
        return accepted
    }

    /// Next message, or `nil` once finished (or when the writer task is cancelled).
    func next() async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                enum Immediate { case message(String), none, wait }
                let immediate: Immediate = state.withLock { state in
                    if !state.buffer.isEmpty { return .message(state.buffer.removeFirst()) }
                    if state.finished || Task.isCancelled || state.waiter != nil { return .none }
                    state.waiter = continuation
                    return .wait
                }
                switch immediate {
                case .message(let message): continuation.resume(returning: message)
                case .none: continuation.resume(returning: nil)
                case .wait: break
                }
            }
        } onCancel: {
            finish()
        }
    }

    func finish() {
        let waiter: CheckedContinuation<String?, Never>? = state.withLock { state in
            state.finished = true
            state.buffer.removeAll()
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }
}
