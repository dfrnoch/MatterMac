import Foundation
public import MatterMacModels
public import MattermostAPI
import MattermostRealtime

/// One authenticated account on one server slot (SPEC §5 MatterMacCore, §6, §10–§12).
///
/// Ownership and lifetimes:
/// - Owns the REST service, the realtime connection, all session stores, and every
///   task it starts. Tasks are tracked in `tasks` (bounded: one per purpose/window
///   edge) and all cancelled by `shutdown`.
/// - Publishes bounded snapshots through `AsyncStream`s buffered `.bufferingNewest(1)`
///   (latest-value semantics: an unconsumed older snapshot is replaced, never queued).
///   Notices use `.bufferingNewest(8)`.
/// - `epoch` increments on shutdown; every async continuation re-checks it (and the
///   window generation) after each `await` so late responses never mutate state.
public actor ServerSession {
    public nonisolated let scope: AccountScope
    public nonisolated let endpoint: ServerEndpoint
    public nonisolated let credentialKind: BearerCredential.Kind

    // Output streams (single consumer each).
    public nonisolated let sidebarUpdates: AsyncStream<SidebarSnapshot>
    public nonisolated let timelineUpdates: AsyncStream<TimelineSnapshot>
    public nonisolated let threadUpdates: AsyncStream<TimelineSnapshot?>
    public nonisolated let headerUpdates: AsyncStream<ChannelHeaderPresentation?>
    public nonisolated let connectionUpdates: AsyncStream<ConnectionStatus>
    public nonisolated let searchUpdates: AsyncStream<SearchSnapshot>
    public nonisolated let notices: AsyncStream<SessionNotice>
    /// Alerts for posts from others that the account's server notification
    /// preferences say should notify (who and where; text only after an explicit
    /// preview opt-in). The UI decides how to present them.
    public nonisolated let alerts: AsyncStream<IncomingMessageAlert>
    /// Unread totals of followed threads (collapsed reply threads) for the Threads view.
    public nonisolated let threadActivity: AsyncStream<ThreadActivity>
    /// Server-side display and notification settings (latest value).
    public nonisolated let accountSettingsUpdates: AsyncStream<AccountSettingsSnapshot>

    let sidebarContinuation: AsyncStream<SidebarSnapshot>.Continuation
    let timelineContinuation: AsyncStream<TimelineSnapshot>.Continuation
    let threadContinuation: AsyncStream<TimelineSnapshot?>.Continuation
    let headerContinuation: AsyncStream<ChannelHeaderPresentation?>.Continuation
    let connectionContinuation: AsyncStream<ConnectionStatus>.Continuation
    let searchContinuation: AsyncStream<SearchSnapshot>.Continuation
    let noticeContinuation: AsyncStream<SessionNotice>.Continuation
    let alertContinuation: AsyncStream<IncomingMessageAlert>.Continuation
    let threadActivityContinuation: AsyncStream<ThreadActivity>.Continuation
    var threadActivityRevision: UInt64 = 0
    var threadTotalsPending = false
    /// What the current search results represent.
    var searchKind: SearchKind = .terms
    /// The newest reply time already reported read for the open thread (CRT).
    var threadReadMark: (root: PostID, at: MattermostTimestamp)?
    let accountSettingsContinuation: AsyncStream<AccountSettingsSnapshot>.Continuation

    let service: any MattermostService
    let realtime: any RealtimeConnection
    let deps: SessionDependencies
    var budget: ResourceBudget { deps.budget }

    // Identity & capabilities
    var me: User
    var capabilities: ServerCapabilities
    var typingEnabled = true
    var serverDeduplicationTrusted = true

    // State
    var directory: DirectoryStore
    var store: PostStore
    var windows: [TimelineTarget: HistoryWindow] = [:]
    var journal = EventJournal(capacity: 256)
    var pending = PendingSendQueue()
    var selectedTeam: TeamID?
    var activeChannel: ChannelID?
    var openThread: TimelineTarget?
    var memberCounts: [ChannelID: Int] = [:]
    var typing: [ChannelID: [UserID: ContinuousClock.Instant]] = [:]
    var connection: ConnectionStatus = .disconnected
    var realtimeState: RealtimeState = .disconnected
    var consecutiveRealtimeFailures = 0
    var accessCounter: UInt64 = 0
    var pendingScroll: [TimelineTarget: TimelineScrollRequest] = [:]
    var lastViewedOnOpen: [ChannelID: MattermostTimestamp] = [:]
    var searchState = SearchModel()
    /// Explicit user opt-in (in memory): alerts carry a short plain-text preview.
    var alertPreviewsEnabled = false

    // Visibility / read policy
    var appIsActive = true
    var windowIsVisible = true
    var visibility: [TimelineTarget: VisibleRange] = [:]
    var lastViewedChannel: ChannelID?
    /// Set by "Mark as Unread": automatic read marking is suspended for this channel
    /// until the user scrolls its timeline, sends in it, or opens another channel.
    var manualUnreadHold: ChannelID?

    // Publishing
    var dirty: DirtyFlags = []
    var flushScheduled = false
    var generations: [TimelineTarget: UInt64] = [:]
    var sidebarGeneration: UInt64 = 0

    // Tasks (bounded by purpose; all cancelled on shutdown)
    var tasks: [TaskKey: Task<Void, Never>] = [:]
    var downloads: [UUID: (channel: ChannelID, task: Task<Void, any Error>)] = [:]
    var epoch: UInt64 = 1
    /// Invalidates membership snapshots that began before a channel was purged.
    var membershipRevision: UInt64 = 0
    var isShutDown = false
    var authenticationEnded = false
    var missingUsers: Set<UserID> = []
    var pendingAlerts: [(event: PostedEvent, cost: Int)] = []
    /// Custom emoji name → id, misses and queued lookups (ServerSession+CustomEmoji.swift).
    var customEmoji: CustomEmojiStore

    enum TaskKey: Hashable {
        case realtimeConsumer
        case sender
        case initialLoad(TimelineTarget)
        case older(TimelineTarget)
        case newer(TimelineTarget)
        case readMark
        case presence
        case typingExpiry
        case userFetch
        case resync
        case search
        case teamLoad(TeamID)
        case channelFetch(ChannelID)
        case configRefresh
        case authenticationCleanup
        case sendRetry(PendingPostID)
        case threadTotals
        case threadRead
        case sidebarCategories(TeamID)
        case categoryUpdate(SidebarCategoryID)
        case teamUnreads
        case alertSender
        case emojiFetch
    }

    struct VisibleRange: Equatable {
        var first: PostID?
        var last: PostID?
        var atLiveEdge: Bool
    }

    public init(scope: AccountScope, endpoint: ServerEndpoint, me: User, credential: BearerCredential,
                capabilities: ServerCapabilities, service: any MattermostService, dependencies: SessionDependencies) {
        self.scope = scope
        self.endpoint = endpoint
        self.credentialKind = credential.kind
        self.me = me
        self.capabilities = capabilities
        self.service = service
        self.deps = dependencies
        self.realtime = dependencies.makeRealtime(endpoint, credential, me.id)
        self.directory = DirectoryStore(budget: dependencies.budget)
        self.customEmoji = CustomEmojiStore(budget: dependencies.budget)
        let documents = dependencies.documents
        self.store = PostStore(render: { documents.document(for: $0) })
        (sidebarUpdates, sidebarContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (timelineUpdates, timelineContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (threadUpdates, threadContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (headerUpdates, headerContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (connectionUpdates, connectionContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (searchUpdates, searchContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (notices, noticeContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        (alerts, alertContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        (threadActivity, threadActivityContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (accountSettingsUpdates, accountSettingsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        directory.pin(me)
    }

    // MARK: - Lifecycle

    /// Loads configuration, preferences, teams, and the first team's channels, then
    /// starts the realtime connection. Safe to call once.
    public func start() async {
        guard isActiveSessionAlive, tasks[.realtimeConsumer] == nil else { return }
        deps.diagnostics.record(.lifecycle, .info, "session start")
        setConnection(.synchronizing)
        startRealtimeConsumer()
        await realtime.start()
        guard isActiveSessionAlive else { return }
        let epoch = epoch
        async let config = service.fullConfiguration()
        async let preferences = service.preferences()
        async let teams = service.teams()
        if let wire = try? await config, self.epoch == epoch {
            capabilities = wire.capabilities.merged(over: capabilities)
            typingEnabled = wire.enableUserTypingMessages ?? true
            applyNameDisplay(wire)
        }
        if let preferences = try? await preferences, self.epoch == epoch {
            directory.applyPreferences(preferences, replacing: true)
        }
        markDirty(.settings)
        do {
            let list = try await teams
            guard self.epoch == epoch else { return }
            directory.replaceTeams(list)
            if selectedTeam == nil { selectedTeam = directory.sortedTeams.first?.id }
            markDirty(.sidebar)
            if let team = selectedTeam { await loadChannels(team: team) }
            refreshThreadTotals()
        } catch {
            guard self.epoch == epoch else { return }
            deps.diagnostics.record(.sync, .error, "teams load failed")
            handleAuthenticationFailureIfNeeded(error)
        }
    }

    /// Ends the session: cancels every task, stops the socket, optionally revokes the
    /// server session, and discards all session data (SPEC §7 logout).
    public func shutdown(revokeServerSession: Bool) async -> SignOutOutcome {
        guard !isShutDown else { return .serverLogoutUnconfirmed }
        isShutDown = true
        epoch &+= 1
        for transfer in downloads.values { transfer.task.cancel() }
        downloads.removeAll()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        pendingAlerts.removeAll()
        await realtime.stop()
        var outcome: SignOutOutcome = credentialKind == .personalAccessToken
            ? .personalAccessTokenDiscardedLocally : .serverLogoutUnconfirmed
        if revokeServerSession && !authenticationEnded && credentialKind == .session {
            do {
                try await service.logout()
                outcome = .serverSessionRevoked
            } catch {
                deps.diagnostics.record(.auth, .warning, "server logout unconfirmed")
            }
        }
        await service.shutdown()
        let reservations = pending.removeAll().map(\.reservation)
        deps.unsent.removeAll(for: scope, pending: reservations)
        windows.removeAll()
        store.removeAll()
        directory.removeAll()
        customEmoji.removeAll()
        journal.removeAll()
        typing.removeAll()
        searchState = SearchModel()
        deps.retention.remove(scope.server)
        setConnection(.disconnected)
        sidebarContinuation.finish()
        timelineContinuation.finish()
        threadContinuation.finish()
        headerContinuation.finish()
        connectionContinuation.finish()
        searchContinuation.finish()
        noticeContinuation.finish()
        alertContinuation.finish()
        threadActivityContinuation.finish()
        accountSettingsContinuation.finish()
        deps.diagnostics.record(.lifecycle, .info, "session shut down")
        return outcome
    }

    public var isActiveSessionAlive: Bool { !isShutDown && !authenticationEnded }

    /// Pending (unconfirmed) operations — used for the sign-out/quit warning.
    public var unsentOperationCount: Int { pending.items.count }

    /// Texts of unconfirmed sends (for "copy before discarding" affordances).
    public var unsentTexts: [String] { pending.items.map(\.message) }

    public func currentUser() -> User { me }
    public func serverCapabilities() -> ServerCapabilities { capabilities }

    // MARK: - Task bookkeeping

    /// Starts (replacing) the task for `key`. The task removes itself when finished.
    func run(_ key: TaskKey, _ operation: @escaping @Sendable (isolated ServerSession) async -> Void) {
        guard isActiveSessionAlive else { return }
        tasks[key]?.cancel()
        let token = UUID()
        taskTokens[key] = token
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.execute(key, token: token, operation)
        }
    }

    var taskTokens: [TaskKey: UUID] = [:]

    private func execute(_ key: TaskKey, token: UUID,
                         _ operation: @Sendable (isolated ServerSession) async -> Void) async {
        if isActiveSessionAlive, !Task.isCancelled { await operation(self) }
        if taskTokens[key] == token {
            tasks[key] = nil
            taskTokens[key] = nil
            if key == .sender { processSendQueue() }
        }
    }

    func isRunning(_ key: TaskKey) -> Bool { tasks[key] != nil }

    // MARK: - Publishing

    func markDirty(_ flags: DirtyFlags) {
        guard !isShutDown else { return }
        dirty.formUnion(flags)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in await self?.flush() }
    }

    func flush() {
        flushScheduled = false
        guard !isShutDown else { return }
        let flags = dirty
        dirty = []
        if flags.contains(.sidebar) { publishSidebar() }
        if flags.contains(.timeline), let channel = activeChannel { publishTimeline(.channel(channel)) }
        if flags.contains(.thread) {
            if let thread = openThread { publishTimeline(thread) } else { threadContinuation.yield(nil) }
        }
        if flags.contains(.header) { publishHeader() }
        if flags.contains(.search) { publishSearch() }
        if flags.contains(.settings) { publishAccountSettings() }
        if !missingUsers.isEmpty { scheduleUserFetch() }
        if !customEmoji.wanted.isEmpty { scheduleEmojiFetch() }
    }

    func setConnection(_ status: ConnectionStatus) {
        guard !authenticationEnded || status == .authenticationRequired || isShutDown else { return }
        guard connection != status else { return }
        connection = status
        connectionContinuation.yield(status)
    }

    func notify(_ notice: SessionNotice) {
        if notice == .signedOutByServer || notice == .identityChanged {
            guard isActiveSessionAlive else { return }
            authenticationEnded = true
            epoch &+= 1
            for task in tasks.values { task.cancel() }
            for transfer in downloads.values { transfer.task.cancel() }
            for item in pending.items {
                pending.update(item.pendingID) {
                    $0.state = item.isInFlight || item.state == .outcomeUnknown
                        ? .outcomeUnknown : .failed(.authenticationRequired)
                }
            }
            windows.removeAll()
            store.removeAll()
            directory.removeAll()
            customEmoji.removeAll()
            journal.removeAll()
            typing.removeAll()
            missingUsers.removeAll()
            pendingAlerts.removeAll()
            searchState = SearchModel()
            activeChannel = nil
            openThread = nil
            setConnection(.authenticationRequired)
            reportRetention()
            markDirty(.all)
            // One bounded cleanup task; unsent work keeps its existing reservations.
            let realtime = realtime, service = service
            tasks[.authenticationCleanup] = Task {
                await realtime.stop()
                await service.shutdown()
            }
        }
        noticeContinuation.yield(notice)
    }

    // MARK: - Helpers

    var collapsedThreadsActive: Bool {
        switch capabilities.collapsedThreads {
        case .disabled, .unknown: return false
        case .alwaysOn: return true
        case .defaultOn: return directory.collapsedThreadsPreference ?? true
        case .defaultOff: return directory.collapsedThreadsPreference ?? false
        }
    }

    func now() -> MattermostTimestamp { MattermostTimestamp(date: deps.wallClock.now()) }

    func nextAccessTick() -> UInt64 {
        accessCounter &+= 1
        return accessCounter
    }

    func handleAuthenticationFailureIfNeeded(_ error: any Error) {
        // Deployment-specific error IDs do not turn an authenticated 401 into a retry.
        guard let api = error as? APIError, case .unauthorized = api else { return }
        setConnection(.authenticationRequired)
        notify(.signedOutByServer)
    }

    func applyNameDisplay(_ wire: ClientConfigWire) {
        directory.serverNameFormat = wire.teammateNameDisplay.flatMap(NameFormat.init(rawValue:)) ?? .username
        directory.isNameFormatLocked = wire.lockTeammateNameDisplay ?? false
        directory.viewArchivedChannels = wire.viewArchivedChannels ?? ((capabilities.version?.major ?? 11) >= 11)
    }

    func teamName(for channel: Channel?) -> String? {
        if let teamID = channel?.teamID, let team = directory.teams[teamID] { return team.name }
        return selectedTeam.flatMap { directory.teams[$0]?.name }
    }
}

extension ServerCapabilities {
    /// Full (authenticated) configuration merged over what discovery learned.
    func merged(over base: ServerCapabilities) -> ServerCapabilities {
        var result = self
        if result.version == nil { result.version = base.version }
        if result.siteName.isEmpty { result.siteName = base.siteName }
        return result
    }
}
