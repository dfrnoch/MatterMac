public import AppKit
public import MatterMacPlatform
public import MatterMacModels
public import MatterMacCore
public import MattermostAPI
public import MattermostRealtime

/// Process-lifetime composition object created once by the app target. Owns the
/// shared budgets, in-memory stores, and optional Keychain sign-ins. Runtime state is
/// released when the process exits.
@MainActor
public final class AppEnvironment {
    public let accounts: KeychainAccounts?
    public let budget: ResourceBudget
    public let diagnostics: DiagnosticRing
    public let unsentLedger: UnsentWorkLedger
    public let retention: RetentionLedger
    public let drafts: DraftStore
    public let serviceFactory: any MattermostServiceFactory
    public let makeRealtime: @Sendable (ServerEndpoint, BearerCredential, UserID) -> any RealtimeConnection
    public let markupParse: @Sendable (String, MarkupLimits) -> MessageDocument
    /// Explicit development setting (never persisted): permits plain-HTTP loopback
    /// servers for local testing. Off unless the app was built for development and
    /// the user enabled it for this run.
    public var allowsInsecureLoopback: Bool
    /// In-session send behavior (not persisted).
    public var sendBehavior: SendBehaviorSetting = .returnSends
    /// The window's model, created by `MatterMacRootView` (weak: the view owns it).
    public internal(set) weak var appModel: AppModel?

    public enum SendBehaviorSetting: String, CaseIterable, Sendable {
        case returnSends
        case commandReturnSends
    }

    public init(budget: ResourceBudget = .standard, allowsInsecureLoopback: Bool = false,
                accounts: KeychainAccounts? = nil,
                serviceFactory: any MattermostServiceFactory,
                makeRealtime: @escaping @Sendable (ServerEndpoint, BearerCredential, UserID) -> any RealtimeConnection,
                markupParse: @escaping @Sendable (String, MarkupLimits) -> MessageDocument) {
        self.accounts = accounts
        self.budget = budget
        self.diagnostics = DiagnosticRing(byteBudget: budget.diagnosticRingBytes)
        self.unsentLedger = UnsentWorkLedger(budget: budget)
        self.retention = RetentionLedger(budget: budget)
        self.drafts = DraftStore(ledger: unsentLedger)
        self.serviceFactory = serviceFactory
        self.makeRealtime = makeRealtime
        self.markupParse = markupParse
        self.allowsInsecureLoopback = allowsInsecureLoopback
        diagnostics.record(.lifecycle, .info, "environment created")
    }

    var sessionDependencies: SessionDependencies {
        SessionDependencies(
            budget: budget, retention: retention, unsent: unsentLedger, diagnostics: diagnostics,
            documents: PostDocumentBuilder(limits: MarkupLimits(maximumInputCharacters: budget.maximumRenderedCharacters),
                                           parse: markupParse),
            makeRealtime: makeRealtime)
    }

    /// Whether quitting now would discard unsent drafts or pending sends.
    public var hasUnsentWork: Bool {
        let usage = unsentLedger.usage
        return usage.totalBytes > 0 || usage.pendingOperations > 0
    }

    /// Called from `applicationShouldTerminate`. Warns when unsent content exists and
    /// explains that RAM-only drafts cannot be recovered after quitting.
    public func confirmTermination() -> NSApplication.TerminateReply {
        guard hasUnsentWork else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit and discard unsent messages?")
        alert.informativeText = String(localized: """
            You have drafts or messages that have not been confirmed by the server. MatterMac keeps \
            them only in memory, so quitting discards them and they cannot be restored.
            """)
        alert.addButton(withTitle: String(localized: "Keep Open"))
        alert.addButton(withTitle: String(localized: "Quit and Discard"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
