public import Foundation
import os

/// Content-free diagnostic record. Only categories, codes, counters, and durations;
/// never message text, names, URLs, tokens, filenames, search strings, or server
/// error bodies. The type system enforces this: fields are enums and integers, and
/// `detail` accepts only `StaticString`.
public struct DiagnosticEvent: Sendable {
    public enum Category: String, Sendable, CaseIterable {
        case lifecycle, auth, http, realtime, sync, send, history, budget, render, image, file
    }

    public enum Level: UInt8, Sendable { case debug, info, warning, error }

    public let uptimeNanoseconds: UInt64
    public let category: Category
    public let level: Level
    public let detail: StaticString
    /// Non-sensitive numeric code (HTTP status, error enum ordinal, count, ...).
    public let code: Int64
    public let durationMicroseconds: Int64?

    public init(category: Category, level: Level, detail: StaticString, code: Int64 = 0,
                durationMicroseconds: Int64? = nil, uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.category = category
        self.level = level
        self.detail = detail
        self.code = code
        self.durationMicroseconds = durationMicroseconds
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    /// Approximate retained cost used for the ring's byte bound.
    static let approximateCost = 64
}

/// Bounded in-memory diagnostic ring (SPEC §7: 256 KiB, redacted, RAM only). There is
/// no file sink and nothing is written to the unified log. Export happens only through
/// an explicit user action elsewhere.
public final class DiagnosticRing: Sendable {
    private struct Storage {
        var buffer: [DiagnosticEvent?]
        var next = 0
        var total: UInt64 = 0
    }

    private let capacity: Int
    private let storage: OSAllocatedUnfairLock<Storage>

    public init(byteBudget: Int) {
        let capacity = max(16, byteBudget / DiagnosticEvent.approximateCost)
        self.capacity = capacity
        self.storage = OSAllocatedUnfairLock(initialState: Storage(buffer: Array(repeating: nil, count: capacity)))
    }

    public func record(_ event: DiagnosticEvent) {
        storage.withLock { state in
            state.buffer[state.next] = event
            state.next = (state.next + 1) % capacity
            state.total &+= 1
        }
    }

    public func record(_ category: DiagnosticEvent.Category, _ level: DiagnosticEvent.Level = .info,
                       _ detail: StaticString, code: Int64 = 0, durationMicroseconds: Int64? = nil) {
        record(DiagnosticEvent(category: category, level: level, detail: detail, code: code,
                               durationMicroseconds: durationMicroseconds))
    }

    /// Oldest-first snapshot of retained events.
    public func snapshot() -> [DiagnosticEvent] {
        storage.withLock { state in
            let head = state.buffer[state.next..<capacity].compactMap { $0 }
            let tail = state.buffer[0..<state.next].compactMap { $0 }
            return head + tail
        }
    }

    public var totalRecorded: UInt64 { storage.withLock { $0.total } }

    public func clear() {
        storage.withLock { state in
            state.buffer = Array(repeating: nil, count: capacity)
            state.next = 0
        }
    }

    /// Plain-text rendering for an explicit, user-initiated diagnostics export.
    public func renderForExport() -> String {
        var lines = ["MatterMac diagnostics (content-free). Events retained: \(snapshot().count), recorded: \(totalRecorded)"]
        for event in snapshot() {
            var line = "\(event.uptimeNanoseconds / 1_000_000)ms \(event.category.rawValue) \(event.level) \(event.detail) code=\(event.code)"
            if let duration = event.durationMicroseconds { line += " dur=\(duration)us" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
