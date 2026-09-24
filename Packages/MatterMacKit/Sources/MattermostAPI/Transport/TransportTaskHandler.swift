import Foundation
import MatterMacModels
import os

/// Per-task state for one URLSession task: bounded body accumulation (or streaming
/// to a file), size enforcement, redirect refusal, progress, and exactly-once
/// completion of the awaiting continuation.
///
/// Threading: URLSession invokes the `receive…`/`sent`/`complete` entry points on
/// the session's serial delegate queue. `install`, `attach` and `fail` may be called
/// from any thread. All mutable state lives in one lock; file I/O and progress
/// callbacks run outside it.
///
/// Lifetime: registered in `SessionDelegate` from task creation until
/// `didCompleteWithError`, then released. The handler → task reference is dropped at
/// completion, which breaks the transient task → session → delegate → handler cycle.
final class TransportTaskHandler: Sendable {
    enum Sink: Sendable {
        case memory
        case file(FileHandle)
    }

    typealias Outcome = Result<HTTPResponse, APIError>

    private struct State: Sendable {
        var continuation: CheckedContinuation<Outcome, Never>?
        var pendingOutcome: Outcome?
        var delivered = false
        var task: URLSessionTask?

        var status: Int?
        var headers = HTTPHeaders()
        var isSuccess = false
        var body = Data()
        var receivedBytes: Int64 = 0
        var expectedBytes: Int64?
        var errorBodyDiscarded = false
        var terminalFailure: APIError?
        var redirectRefused = false
        var requestTransmitted: Bool?
        var lastReportedProgress: Int64 = -1
    }

    let method: HTTPMethod
    let allowsRedirects: Bool
    private let limits: ResponseLimits
    private let sink: Sink
    private let progress: (@Sendable (TransferProgress) -> Void)?
    private let diagnostics: DiagnosticRingProxy
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Progress is reported at most once per this many bytes (plus the final value).
    static let progressGranularity: Int64 = 64 * 1_024

    init(method: HTTPMethod, allowsRedirects: Bool = true, limits: ResponseLimits, sink: Sink, progress: (@Sendable (TransferProgress) -> Void)?,
         diagnostics: DiagnosticRingProxy) {
        self.method = method
        self.allowsRedirects = allowsRedirects
        self.limits = limits
        self.sink = sink
        self.progress = progress
        self.diagnostics = diagnostics
    }

    // MARK: Awaiting side

    func attach(_ task: URLSessionTask) {
        state.withLock { $0.task = task }
    }

    /// Installs the continuation. If the task already finished (e.g. it was
    /// cancelled before it was resumed), the stored outcome is delivered at once.
    func install(_ continuation: CheckedContinuation<Outcome, Never>) {
        let ready: Outcome? = state.withLock { state in
            if let outcome = state.pendingOutcome {
                state.pendingOutcome = nil
                state.delivered = true
                return outcome
            }
            state.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    /// Fails the task with `error` (first failure wins) and cancels it.
    func fail(_ error: APIError) {
        let task: URLSessionTask? = state.withLock { state in
            if state.terminalFailure == nil { state.terminalFailure = error }
            return state.task
        }
        task?.cancel()
    }

    // MARK: Delegate side (serial delegate queue)

    func refuseRedirect() {
        state.withLock { $0.redirectRefused = true }
    }

    func receive(response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            state.withLock { $0.terminalFailure = $0.terminalFailure ?? .malformedResponse }
            return .cancel
        }
        let limits = self.limits
        let isMemorySink: Bool
        if case .memory = sink { isMemorySink = true } else { isMemorySink = false }
        let headers = HTTPHeaders(response: http)
        let status = http.statusCode
        let expected = http.expectedContentLength
        let disposition: URLSession.ResponseDisposition = state.withLock { state in
            state.status = status
            state.headers = headers
            state.isSuccess = (200..<300).contains(status)
            state.expectedBytes = expected >= 0 ? expected : nil
            if state.isSuccess {
                // Pre-check: a declared length above the budget is refused before any
                // body byte is consumed. (Content-Length alone is not trusted: actual
                // decompressed bytes are counted in `receive(data:)`.)
                if expected > limits.maximumBodyBytes {
                    state.terminalFailure = state.terminalFailure ?? .responseTooLarge(limitBytes: Self.clampedLimit(limits))
                    return .cancel
                }
                if isMemorySink, expected > 0 {
                    state.body.reserveCapacity(Int(min(expected, limits.maximumBodyBytes, Int64(8 * Int.mebibyte))))
                }
            } else if expected > Int64(limits.maximumErrorBodyBytes) {
                // Only the machine-readable id is useful; skip an oversized error body.
                state.errorBodyDiscarded = true
                return .cancel
            }
            return .allow
        }
        if disposition == .cancel, state.withLock({ $0.terminalFailure }) != nil {
            diagnostics.record(.http, .warning, "response refused before body", code: Int64(status))
        }
        return disposition
    }

    func receive(data: Data, task: URLSessionTask) {
        let limits = self.limits
        let count = Int64(data.count)
        let isMemorySink: Bool
        if case .memory = sink { isMemorySink = true } else { isMemorySink = false }

        enum Action: Sendable { case none, cancel, write(progress: TransferProgress?), report(TransferProgress?) }
        let action: Action = state.withLock { state in
            if state.terminalFailure != nil || state.errorBodyDiscarded { return .cancel }
            guard state.isSuccess else {
                if state.body.count + data.count > limits.maximumErrorBodyBytes {
                    state.errorBodyDiscarded = true
                    state.body = Data()
                    return .cancel
                }
                state.body.append(data)
                return .none
            }
            state.receivedBytes += count
            if state.receivedBytes > limits.maximumBodyBytes {
                state.terminalFailure = .responseTooLarge(limitBytes: Self.clampedLimit(limits))
                state.body = Data()
                return .cancel
            }
            var report: TransferProgress?
            if state.receivedBytes - state.lastReportedProgress >= Self.progressGranularity
                || state.receivedBytes == state.expectedBytes {
                state.lastReportedProgress = state.receivedBytes
                report = TransferProgress(completedBytes: state.receivedBytes, totalBytes: state.expectedBytes)
            }
            if isMemorySink {
                state.body.append(data)
                return .report(report)
            }
            return .write(progress: report)
        }

        switch action {
        case .none:
            return
        case .cancel:
            diagnostics.record(.http, .warning, "response body limit reached", code: limits.maximumBodyBytes)
            task.cancel()
        case .report(let report):
            if let report { progress?(report) }
        case .write(let report):
            guard case .file(let handle) = sink else { return }
            do {
                try Self.write(data, to: handle)
            } catch {
                diagnostics.record(.file, .error, "download write failed")
                fail(.localFileUnavailable)
                return
            }
            if let report { progress?(report) }
        }
    }

    /// Writes in slices of at most `URLSessionTransport.maximumWriteChunkBytes`.
    static func write(_ data: Data, to handle: FileHandle) throws {
        let chunk = URLSessionTransport.maximumWriteChunkBytes
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: chunk, limitedBy: data.endIndex) ?? data.endIndex
            try handle.write(contentsOf: data[offset..<end])
            offset = end
        }
    }

    func sent(totalBytes: Int64, expected: Int64) {
        let report: TransferProgress? = state.withLock { state in
            let total: Int64? = expected > 0 ? expected : nil
            if totalBytes - state.lastReportedProgress >= Self.progressGranularity || totalBytes == total {
                state.lastReportedProgress = totalBytes
                return TransferProgress(completedBytes: totalBytes, totalBytes: total)
            }
            return nil
        }
        if let report { progress?(report) }
    }

    func metrics(_ metrics: URLSessionTaskMetrics) {
        let transmitted = metrics.transactionMetrics.contains { $0.requestStartDate != nil }
        state.withLock { $0.requestTransmitted = transmitted }
    }

    func complete(error: (any Error)?) {
        let limits = self.limits
        let (continuation, outcome): (CheckedContinuation<Outcome, Never>?, Outcome?) = state.withLock { state in
            guard !state.delivered, state.pendingOutcome == nil else { return (nil, nil) }
            state.task = nil
            let outcome: Outcome
            if let failure = state.terminalFailure {
                outcome = .failure(failure)
            } else if state.redirectRefused {
                outcome = .failure(.redirectRefused)
            } else if state.errorBodyDiscarded, let status = state.status {
                outcome = .success(HTTPResponse(statusCode: status, headers: state.headers, body: Data(), bodyDiscarded: true))
            } else if let error {
                var mapped = TransportErrorMapping.map(error, requestTransmitted: state.requestTransmitted)
                if mapped == .cancelled, !method.isSafe, state.requestTransmitted != false {
                    mapped = .outcomeUnknown(.other(code: URLError.cancelled.rawValue))
                }
                if case .responseTooLarge = mapped { mapped = .responseTooLarge(limitBytes: Self.clampedLimit(limits)) }
                outcome = .failure(mapped)
            } else if let status = state.status {
                outcome = .success(HTTPResponse(statusCode: status, headers: state.headers, body: state.body))
            } else {
                outcome = .failure(.malformedResponse)
            }
            state.body = Data()
            if let continuation = state.continuation {
                state.continuation = nil
                state.delivered = true
                return (continuation, outcome)
            }
            state.pendingOutcome = outcome
            return (nil, nil)
        }
        if let continuation, let outcome { continuation.resume(returning: outcome) }
    }

    static func clampedLimit(_ limits: ResponseLimits) -> Int {
        Int(clamping: limits.maximumBodyBytes)
    }
}

/// Optional diagnostics sink shared by transport components.
struct DiagnosticRingProxy: Sendable {
    let ring: DiagnosticRing?

    func record(_ category: DiagnosticEvent.Category, _ level: DiagnosticEvent.Level, _ detail: StaticString,
                code: Int64 = 0, durationMicroseconds: Int64? = nil) {
        ring?.record(category, level, detail, code: code, durationMicroseconds: durationMicroseconds)
    }
}
