public import Foundation
public import MatterMacModels
import os

/// Production `HTTPTransport` on Foundation `URLSession` (SPEC §7, §9, §15, §18).
///
/// One instance owns exactly one URLSession and one `SessionDelegate`, scoped to
/// one `ServerEndpoint` (and, for authenticated services, one credential lifetime).
///
/// Privacy configuration: `URLSessionConfiguration.ephemeral` with `urlCache = nil`,
/// `httpCookieStorage = nil`, `httpShouldSetCookies = false`, cookie accept policy
/// `.never`, `urlCredentialStorage = nil`, `.reloadIgnoringLocalCacheData`. No
/// background session and no download tasks (downloads are data tasks streamed into
/// a caller-owned file handle, so Foundation creates no temporary file).
///
/// Lifetime: call `shutdown()` when the owning session ends (sign-out, server
/// removal). It cancels in-flight tasks, invalidates the session and waits for
/// `didBecomeInvalidWithError`, after which URLSession has released the delegate.
/// `deinit` invalidates as a safety net if `shutdown()` was never called.
public final class URLSessionTransport: HTTPTransport {
    public let scope: ServerEndpoint
    public let userAgent: String
    private let session: URLSession
    private let delegate: SessionDelegate
    private let lifecycle = OSAllocatedUnfairLock(initialState: true)  // true = open
    private let diagnostics: DiagnosticRingProxy
    private let monitorQueue = DispatchQueue(label: "MatterMac.HTTP.file-monitor", qos: .utility)

    /// Maximum bytes written to a download destination per `write` call.
    public static let maximumWriteChunkBytes = 64 * 1_024

    public init(scope: ServerEndpoint, budget: ResourceBudget = .standard, userAgent: String = UserAgent.standard,
                diagnostics: DiagnosticRing? = nil) {
        self.scope = scope
        self.userAgent = UserAgent.containsMobileToken(userAgent) ? UserAgent.make(version: nil) : userAgent
        self.diagnostics = DiagnosticRingProxy(ring: diagnostics)
        let delegate = SessionDelegate(scope: scope, diagnostics: self.diagnostics)
        self.delegate = delegate
        let queue = OperationQueue()
        queue.name = "MatterMac.HTTP.delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        self.session = URLSession(configuration: Self.makeConfiguration(budget: budget), delegate: delegate,
                                  delegateQueue: queue)
    }

    deinit {
        let wasOpen = lifecycle.withLock { open -> Bool in
            defer { open = false }
            return open
        }
        if wasOpen { session.invalidateAndCancel() }
    }

    /// The hardened configuration. Exposed for tests and audit.
    public static func makeConfiguration(budget: ResourceBudget) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = HTTPRequest.defaultTimeout
        // Resource timeout bounds a whole task including large transfers; idle
        // timeouts are per request (30 s API, 120 s transfers).
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = max(1, budget.requestsPerServer)
        configuration.waitsForConnectivity = false
        configuration.httpShouldUsePipelining = false
        configuration.httpAdditionalHeaders = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.shouldUseExtendedBackgroundIdleMode = false
        return configuration
    }

    /// Diagnostic/test hooks.
    var sessionDelegate: SessionDelegate { delegate }
    var urlSession: URLSession { session }
    public var isShutDown: Bool { !lifecycle.withLock { $0 } }

    // MARK: Request construction

    /// Headers the caller may not set; the transport owns them.
    static let controlledHeaders: Set<String> = [
        "authorization", "cookie", "cookie2", "user-agent", "x-requested-with", "x-csrf-token", "host",
        "content-length", "connection", "proxy-authorization", "transfer-encoding",
    ]

    /// Builds the URLRequest actually sent. Pure; unit-tested.
    ///
    /// - Refuses (`.redirectRefused`) any URL outside `scope`, so neither credentials
    ///   nor requests are ever sent to another origin or outside the subpath.
    /// - Adds `Authorization: Bearer …` only for requests carrying a credential.
    /// - Never sets cookies or `X-Requested-With`.
    public static func makeURLRequest(for request: HTTPRequest, scope: ServerEndpoint, userAgent: String)
        throws(APIError) -> URLRequest {
        guard scope.contains(request.url), !RedirectPolicy.hasDotSegment(request.url) else { throw .redirectRefused }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        for field in request.headers where !controlledHeaders.contains(field.name.lowercased()) {
            urlRequest.addValue(field.value, forHTTPHeaderField: field.name)
        }
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if urlRequest.value(forHTTPHeaderField: "Accept") == nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if let body = request.body {
            urlRequest.httpBody = body
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        if let credential = request.credential {
            urlRequest.setValue(credential.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    // MARK: HTTPTransport

    public func send(_ request: HTTPRequest, limits: ResponseLimits) async throws(APIError) -> HTTPResponse {
        let urlRequest = try Self.makeURLRequest(for: request, scope: scope, userAgent: userAgent)
        let handler = TransportTaskHandler(method: request.method, allowsRedirects: request.allowsRedirects, limits: limits, sink: .memory, progress: nil,
                                           diagnostics: diagnostics)
        return try await run(handler) { session in session.dataTask(with: urlRequest) }
    }

    public func upload(_ request: HTTPRequest, file: UploadFile, limits: ResponseLimits,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> HTTPResponse {
        var urlRequest = try Self.makeURLRequest(for: request, scope: scope, userAgent: userAgent)
        urlRequest.httpBody = nil
        if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
            urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        // Scoped read-only handle for the duration of the upload. Foundation reads the
        // file itself (by path) and streams it; this descriptor pins the identity we
        // validated and drives the change monitor.
        let snapshot = try FileSnapshot.open(file.url)
        guard snapshot.size == file.expectedLength, file.expectedLength >= 0,
              file.expectedRevision == nil || file.expectedRevision == snapshot.revision else {
            snapshot.close()
            throw .localFileUnavailable
        }
        urlRequest.setValue(String(file.expectedLength), forHTTPHeaderField: "Content-Length")

        let handler = TransportTaskHandler(method: request.method, allowsRedirects: request.allowsRedirects, limits: limits, sink: .memory, progress: progress,
                                           diagnostics: diagnostics)
        let monitor = FileChangeMonitor(snapshot: snapshot, queue: monitorQueue) { [diagnostics] in
            diagnostics.record(.file, .warning, "upload source changed")
            handler.fail(.localFileUnavailable)
        }
        let fileURL = file.url
        let uploadRequest = urlRequest
        let outcome: Result<HTTPResponse, APIError>
        do throws(APIError) {
            outcome = .success(try await run(handler) { session in session.uploadTask(with: uploadRequest, fromFile: fileURL) })
        } catch {
            outcome = .failure(error)
        }
        // Re-validate after the body was sent: same inode, size and modification time,
        // both through the pinned descriptor and at the path Foundation read from.
        let unchanged = snapshot.isUnchanged(atPath: fileURL.path)
        monitor.cancel()  // closes the descriptor on the monitor queue
        switch outcome {
        case .success(let response):
            guard unchanged else { throw .localFileUnavailable }
            return response
        case .failure(let error):
            if error == .cancelled || unchanged { throw error }
            throw .localFileUnavailable
        }
    }

    public func download(_ request: HTTPRequest, to handle: FileHandle, limits: ResponseLimits,
                         progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> HTTPResponse {
        let urlRequest = try Self.makeURLRequest(for: request, scope: scope, userAgent: userAgent)
        let handler = TransportTaskHandler(method: request.method, allowsRedirects: request.allowsRedirects, limits: limits, sink: .file(handle), progress: progress,
                                           diagnostics: diagnostics)
        return try await run(handler) { session in session.dataTask(with: urlRequest) }
    }

    public func shutdown() async {
        let wasOpen = lifecycle.withLock { open -> Bool in
            defer { open = false }
            return open
        }
        if wasOpen {
            diagnostics.record(.http, .info, "transport shutdown")
            session.invalidateAndCancel()
        }
        await delegate.waitUntilInvalidated()
    }

    // MARK: Task execution

    private func run(_ handler: TransportTaskHandler,
                     makeTask: @Sendable (URLSession) -> URLSessionTask) async throws(APIError) -> HTTPResponse {
        if Task.isCancelled { throw .cancelled }
        let session = self.session
        let delegate = self.delegate
        // Task creation and registration happen under the lifecycle lock so that no
        // task can be created on a session that `shutdown()` has invalidated
        // (URLSession raises an exception for that).
        let created: URLSessionTask? = lifecycle.withLock { open in
            guard open else { return nil }
            let task = makeTask(session)
            delegate.register(handler, for: task)
            return task
        }
        guard let task = created else { throw .cancelled }
        handler.attach(task)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TransportTaskHandler.Outcome, Never>) in
                handler.install(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return try outcome.get()
    }
}
