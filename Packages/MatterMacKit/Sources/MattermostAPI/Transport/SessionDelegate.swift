import Foundation
import MatterMacModels
import os

/// The single session-level delegate of one `URLSessionTransport`'s URLSession.
///
/// Routes task events to the task's `TransportTaskHandler` and enforces the
/// redirect policy for the transport's `ServerEndpoint` scope.
///
/// Lifetime (SPEC §6): URLSession retains its delegate strongly until the session is
/// invalidated. This object holds no reference to the session or the transport, so
/// the only cycle is the documented session → delegate edge, which
/// `URLSessionTransport.shutdown()` (or its `deinit`) breaks by invalidating the
/// session. `urlSession(_:didBecomeInvalidWithError:)` resumes shutdown waiters.
final class SessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct Invalidation: Sendable {
        var isInvalidated = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    let scope: ServerEndpoint
    private let handlers = OSAllocatedUnfairLock<[Int: TransportTaskHandler]>(initialState: [:])
    private let invalidation = OSAllocatedUnfairLock(initialState: Invalidation())
    private let diagnostics: DiagnosticRingProxy

    /// Bound on concurrent `shutdown()` waiters; extra callers return immediately.
    static let maximumInvalidationWaiters = 32

    init(scope: ServerEndpoint, diagnostics: DiagnosticRingProxy) {
        self.scope = scope
        self.diagnostics = diagnostics
    }

    func register(_ handler: TransportTaskHandler, for task: URLSessionTask) {
        let id = task.taskIdentifier
        handlers.withLock { $0[id] = handler }
    }

    var activeTaskCount: Int { handlers.withLock { $0.count } }

    private func handler(for task: URLSessionTask) -> TransportTaskHandler? {
        let id = task.taskIdentifier
        return handlers.withLock { $0[id] }
    }

    /// Suspends until the session has been invalidated (immediately if it already was).
    func waitUntilInvalidated() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = invalidation.withLock { state -> Bool in
                if state.isInvalidated || state.waiters.count >= Self.maximumInvalidationWaiters { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var isInvalidated: Bool { invalidation.withLock { $0.isInvalidated } }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let waiters = invalidation.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isInvalidated = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        let orphaned = handlers.withLock { table -> [TransportTaskHandler] in
            let all = Array(table.values)
            table.removeAll()
            return all
        }
        // Every task completes before invalidation; this is defensive only.
        for handler in orphaned { handler.complete(error: URLError(.cancelled)) }
        for waiter in waiters { waiter.resume() }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let handler = handler(for: task)
        let decision = RedirectPolicy.evaluate(
            originalMethod: handler?.method ?? .get,
            originalURL: task.currentRequest?.url ?? task.originalRequest?.url,
            redirectMethod: request.httpMethod,
            redirectURL: request.url,
            scope: scope)
        if decision == .follow, handler?.allowsRedirects == true {
            var redirected = request
            // Foundation may strip Authorization even on a same-origin redirect.
            // Restore it only after validating both origin and base path above.
            redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
                                forHTTPHeaderField: "Authorization")
            completionHandler(redirected)
            return
        }
        diagnostics.record(.http, .warning, "redirect refused", code: Int64(response.statusCode))
        handler?.refuseRedirect()
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        handler(for: task)?.sent(totalBytes: totalBytesSent, expected: totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        handler(for: task)?.metrics(metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        let handler = handlers.withLock { $0.removeValue(forKey: id) }
        handler?.complete(error: error)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let handler = handler(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(handler.receive(response: response))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(for: dataTask) else {
            dataTask.cancel()
            return
        }
        handler.receive(data: data, task: dataTask)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        // No URLCache is configured; refuse caching defensively.
        completionHandler(nil)
    }
}
