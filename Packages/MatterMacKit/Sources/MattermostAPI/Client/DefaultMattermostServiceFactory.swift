public import MatterMacModels

/// Production `MattermostServiceFactory` (SPEC §9, §15, §17).
///
/// Owns the process-wide limiters shared by every server session:
/// - `requestAdmission`: normal API requests, `budget.requestsPerServer` per server
///   (with `budget.interactiveReservedPerServer` reserved for interactive work) and
///   `budget.requestsGlobal` across all servers;
/// - `transferAdmission`: attachment uploads/downloads,
///   `budget.attachmentTransfersGlobal` across all servers.
///
/// Session lifetimes: every `discovery(for:)` / `service(for:credential:)` call
/// creates a new client with its *own* transport, i.e. one URLSession + one
/// delegate per endpoint/credential lifetime. Nothing is cached here, so the
/// factory never extends a session's lifetime; the owner calls `shutdown()` on the
/// client (sign-out, server removal) to invalidate the URLSession. A client that is
/// dropped without `shutdown()` invalidates its URLSession in `deinit`.
public final class DefaultMattermostServiceFactory: MattermostServiceFactory {
    public let budget: ResourceBudget
    public let requestAdmission: AdmissionController
    public let transferAdmission: AdmissionController
    private let retryPolicy: RetryPolicy
    private let clock: any Clock<Duration>
    private let diagnostics: DiagnosticRing?
    private let makeTransport: @Sendable (ServerEndpoint) -> any HTTPTransport

    /// Production configuration: `URLSessionTransport` per client.
    public convenience init(budget: ResourceBudget = .standard, diagnostics: DiagnosticRing? = nil,
                            userAgent: String = UserAgent.standard) {
        self.init(budget: budget, diagnostics: diagnostics, retryPolicy: .standard, clock: ContinuousClock()) { endpoint in
            URLSessionTransport(scope: endpoint, budget: budget, userAgent: userAgent, diagnostics: diagnostics)
        }
    }

    /// Injectable configuration (tests, benchmarks).
    public init(budget: ResourceBudget, diagnostics: DiagnosticRing?, retryPolicy: RetryPolicy, clock: any Clock<Duration>,
                transportProvider: @escaping @Sendable (ServerEndpoint) -> any HTTPTransport) {
        self.budget = budget
        self.diagnostics = diagnostics
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.makeTransport = transportProvider
        self.requestAdmission = AdmissionController(limits: .requests(budget), diagnostics: diagnostics)
        self.transferAdmission = AdmissionController(limits: .transfers(budget), diagnostics: diagnostics)
    }

    public func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService {
        makeDiscoveryClient(for: endpoint)
    }

    public func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService {
        makeClient(for: endpoint, credential: credential)
    }

    public func makeDiscoveryClient(for endpoint: ServerEndpoint) -> MattermostDiscoveryClient {
        MattermostDiscoveryClient(endpoint: endpoint, pipeline: makePipeline(endpoint), budget: budget)
    }

    public func makeClient(for endpoint: ServerEndpoint, credential: BearerCredential) -> MattermostHTTPClient {
        MattermostHTTPClient(endpoint: endpoint, credential: credential, pipeline: makePipeline(endpoint), budget: budget)
    }

    private func makePipeline(_ endpoint: ServerEndpoint) -> RequestPipeline {
        RequestPipeline(transport: makeTransport(endpoint), requestAdmission: requestAdmission,
                        transferAdmission: transferAdmission, retryPolicy: retryPolicy, clock: clock, budget: budget,
                        diagnostics: diagnostics)
    }
}
