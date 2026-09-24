import Foundation
import MatterMacModels
import os

/// Composition of the per-session request path:
///
///     coalescing (GET only) → retry (safe methods only) → admission → transport
///
/// - Coalescing is outermost so joiners share the whole (possibly retried) read.
/// - Admission is acquired per attempt, so a backoff sleep never holds a slot.
/// - Non-2xx responses are mapped to `APIError` here (the retry loop needs them).
struct RequestPipeline: Sendable {
    struct CoalescingKey: Hashable, Sendable {
        let url: URL
        let credential: BearerCredential?
        let accept: String?
        let limits: ResponseLimits
        let priority: RequestPriority
        let allowsRedirects: Bool
    }

    let transport: any HTTPTransport
    let requestAdmission: AdmissionController
    let transferAdmission: AdmissionController
    let lane: AdmissionController.Lane
    let retryPolicy: RetryPolicy
    let clock: any Clock<Duration>
    let coalescer: RequestCoalescer<CoalescingKey, HTTPResponse>
    let diagnostics: DiagnosticRingProxy
    private let open = OSAllocatedUnfairLock(initialState: true)

    init(transport: any HTTPTransport, requestAdmission: AdmissionController, transferAdmission: AdmissionController,
         retryPolicy: RetryPolicy, clock: any Clock<Duration>, budget: ResourceBudget, diagnostics: DiagnosticRing?) {
        self.transport = transport
        self.requestAdmission = requestAdmission
        self.transferAdmission = transferAdmission
        self.lane = requestAdmission.makeLane()
        self.retryPolicy = retryPolicy
        self.clock = clock
        // Every coalesced read either runs or waits in admission, so the number of
        // distinct in-flight reads never usefully exceeds running + queued requests.
        self.coalescer = RequestCoalescer(
            maximumEntries: budget.requestsPerServer + 2 * budget.requestWaitersPerServer,
            maximumJoinersPerEntry: max(8, budget.requestWaitersPerServer))
        self.diagnostics = DiagnosticRingProxy(ring: diagnostics)
    }

    var isOpen: Bool { open.withLock { $0 } }

    /// Returns a 2xx response or throws.
    func execute(_ request: HTTPRequest, priority: RequestPriority, limits: ResponseLimits) async throws(APIError)
        -> HTTPResponse {
        guard isOpen else { throw .cancelled }
        guard request.method == .get else {
            return try await attempts(request, priority: priority, limits: limits)
        }
        let key = CoalescingKey(url: request.url, credential: request.credential, accept: request.headers["Accept"],
                                limits: limits, priority: priority, allowsRedirects: request.allowsRedirects)
        let pipeline = self
        return try await coalescer.run(key: key) { () async -> Result<HTTPResponse, APIError> in
            do throws(APIError) {
                return .success(try await pipeline.attempts(request, priority: priority, limits: limits))
            } catch {
                return .failure(error)
            }
        }
    }

    private func attempts(_ request: HTTPRequest, priority: RequestPriority, limits: ResponseLimits) async throws(APIError)
        -> HTTPResponse {
        let transport = self.transport
        let admission = self.requestAdmission
        let lane = self.lane
        let diagnostics = self.diagnostics
        let clock = self.clock
        return try await retryPolicy.run(isSafe: request.method.isSafe, clock: clock, onRetry: { error, _ in
            diagnostics.record(.http, .info, "retrying safe read", code: Self.diagnosticCode(error))
        }) { () async throws(APIError) -> HTTPResponse in
            let started = ContinuousClock.now
            let response = try await admission.withPermit(lane: lane, priority: priority) {
                () async throws(APIError) -> HTTPResponse in
                try await transport.send(request, limits: limits)
            }
            let elapsed = ContinuousClock.now - started
            diagnostics.record(.http, response.isSuccess ? .debug : .info, "response", code: Int64(response.statusCode),
                               durationMicroseconds: Self.microseconds(elapsed))
            if let error = HTTPStatusMapping.error(for: response) { throw error }
            return response
        }
    }

    /// Runs an attachment transfer under the transfer limiter (never retried, never
    /// coalesced; uploads/downloads do not consume normal API request slots).
    func transfer<T: Sendable>(_ body: @Sendable () async throws(APIError) -> T) async throws(APIError) -> T {
        guard isOpen else { throw .cancelled }
        return try await transferAdmission.withPermit(lane: lane, priority: .interactive, body)
    }

    /// Rejects new work, resumes this session's queued waiters with `.cancelled` and
    /// shuts the transport down (cancelling in-flight tasks).
    func shutdown() async {
        open.withLock { $0 = false }
        await requestAdmission.cancelWaiters(lane: lane)
        await transferAdmission.cancelWaiters(lane: lane)
        await transport.shutdown()
    }

    static func microseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds &* 1_000_000 &+ attoseconds / 1_000_000_000_000
    }

    static func diagnosticCode(_ error: APIError) -> Int64 {
        switch error {
        case .rateLimited: 429
        case .server(let info): Int64(info.statusCode)
        case .notSent: 1
        case .outcomeUnknown: 2
        default: 0
        }
    }
}
