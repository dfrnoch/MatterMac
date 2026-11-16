public import AppKit
public import MatterMacPlatform
public import MatterMacModels
public import MatterMacCore
public import MattermostAPI
public import MattermostRealtime

/// Process-lifetime composition object created once by the app target. Owns the
/// shared budgets, in-memory stores, optional Keychain sign-ins, the optional
/// on-device content cache and the local settings (saved only with injected storage).
@MainActor
public final class AppEnvironment {
    public let accounts: KeychainAccounts?
    /// Encrypted on-device cache (images, directory, recent channels); `nil` keeps
    /// everything in memory (tests, UI testing).
    public let contentCache: ContentCache?
    /// Automatic updates from GitHub releases; `nil` for development and test builds.
    public var updater: AppUpdater?
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
    /// Local presentation and attention settings (Settings › "On This Mac"). Saved
    /// between launches only when the app injects storage; otherwise in memory.
    public let settings: LocalSettings
    /// Composer send behavior (a local setting).
    public var sendBehavior: SendBehaviorSetting {
        get { settings.sendBehavior }
        set { settings.sendBehavior = newValue }
    }
    /// Learned writing-style profiles between launches; `nil` keeps them in memory.
    public let styleProfiles: (any StyleProfileStore)?
    /// Command-line agent control; listens only while the setting is on, and only when
    /// the app gave it a socket path (tests and UI testing give none).
    private(set) lazy var agent = AgentController(environment: self, socketPath: agentSocketPath)
    private let agentSocketPath: String?
    /// Reply suggestions already computed this run (memory only).
    let suggestions = SuggestionCache()
    /// A broken assistant setup is reported once per run.
    var assistantProblemReported = false
    /// Stands in for `NSApp.isActive` (tests run in an inactive process).
    var isAppActiveOverride: Bool?
    var isAppActive: Bool { isAppActiveOverride ?? NSApp.isActive }
    /// Replaces the provider chosen in Settings (tests).
    public var assistantOverride: (any AssistantProvider)?
    private var claudeAPI: (model: ClaudeAPIAssistant.Model, provider: ClaudeAPIAssistant)?
    /// The provider chosen in Settings; `nil` when the assistant is off.
    public var assistant: (any AssistantProvider)? {
        if let assistantOverride { return assistantOverride }
        switch settings.assistant {
        case .off: return nil
        case .onDevice: return OnDeviceAssistant()
        case .claudeAPI:
            // One URL session per chosen summary model, kept while it stays chosen.
            if let claudeAPI, claudeAPI.model == settings.assistantClaudeModel { return claudeAPI.provider }
            let provider = ClaudeAPIAssistant(summaryModel: settings.assistantClaudeModel)
            claudeAPI = (settings.assistantClaudeModel, provider)
            return provider
        case .claudeCode: return ScriptAssistant(kind: .claudeCode)
        case .codex: return ScriptAssistant(kind: .codex)
        }
    }
    /// The window's model, created by `MatterMacRootView` (weak: the view owns it).
    public internal(set) weak var appModel: AppModel?

    public enum SendBehaviorSetting: String, CaseIterable, Sendable {
        case returnSends
        case commandReturnSends
    }

    public init(budget: ResourceBudget = .standard, allowsInsecureLoopback: Bool = false,
                accounts: KeychainAccounts? = nil, cacheStorage: ContentCache.Storage? = nil,
                settingsStorage: (any LocalSettingsStorage)? = nil, agentSocketPath: String? = nil,
                styleProfiles: (any StyleProfileStore)? = nil,
                serviceFactory: any MattermostServiceFactory,
                makeRealtime: @escaping @Sendable (ServerEndpoint, BearerCredential, UserID) -> any RealtimeConnection,
                markupParse: @escaping @Sendable (String, MarkupLimits) -> MessageDocument) {
        self.accounts = accounts
        self.budget = budget
        let diagnostics = DiagnosticRing(byteBudget: budget.diagnosticRingBytes)
        self.diagnostics = diagnostics
        self.contentCache = cacheStorage.map { ContentCache(storage: $0, budget: budget, diagnostics: diagnostics) }
        self.unsentLedger = UnsentWorkLedger(budget: budget)
        self.retention = RetentionLedger(budget: budget)
        self.drafts = DraftStore(ledger: unsentLedger)
        self.serviceFactory = serviceFactory
        self.makeRealtime = makeRealtime
        self.markupParse = markupParse
        self.allowsInsecureLoopback = allowsInsecureLoopback
        self.settings = LocalSettings(storage: settingsStorage)
        self.agentSocketPath = agentSocketPath
        self.styleProfiles = styleProfiles
        diagnostics.record(.lifecycle, .info, "environment created")
        agent.bind()
    }

    var sessionDependencies: SessionDependencies {
        SessionDependencies(
            budget: budget, retention: retention, unsent: unsentLedger, diagnostics: diagnostics,
            documents: PostDocumentBuilder(limits: MarkupLimits(maximumInputCharacters: budget.maximumRenderedCharacters),
                                           parse: markupParse),
            makeRealtime: makeRealtime, contentCache: contentCache)
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
