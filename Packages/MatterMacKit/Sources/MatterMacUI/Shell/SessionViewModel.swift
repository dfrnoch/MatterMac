import AppKit
public import Observation
public import MatterMacModels
public import MatterMacCore
import MattermostAPI

/// Main-actor view model for one server session. Receives bounded snapshots from the
/// `ServerSession` actor and forwards user intents to it. Snapshots carrying another
/// scope are ignored, so a late response from a previous session can never appear
/// under the current identity (SPEC §4).
@MainActor
@Observable
public final class SessionViewModel {
    public let slot: SessionRegistry.Slot
    public var scope: AccountScope { slot.session.scope }
    var session: ServerSession { slot.session }
    weak var app: AppModel?

    public private(set) var sidebar: SidebarSnapshot?
    public private(set) var timeline: TimelineSnapshot?
    public private(set) var thread: TimelineSnapshot?
    public private(set) var header: ChannelHeaderPresentation?
    public private(set) var connection: ConnectionStatus = .connecting
    public private(set) var search: SearchSnapshot?
    public private(set) var selectedChannel: ChannelID?
    public private(set) var pendingNotice: SessionNotice?
    public private(set) var requiresAuthentication = false
    public private(set) var isCopyingUnsentText = false
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    public var isUnsentRecoveryVisible = false
    /// The results pane (search, recent mentions, saved, pinned) in the trailing area.
    public var isSearchVisible = false {
        didSet {
            guard isSearchVisible != oldValue else { return }
            if isSearchVisible {
                isChannelInfoVisible = false
                if thread != nil || replyTarget != nil { closeThread() }
            } else {
                clearSearch()
            }
        }
    }
    public var isQuickSwitcherVisible = false
    /// The followed-threads view (collapsed reply threads) in the main area.
    public var isThreadsViewVisible = false
    public private(set) var threadActivity: ThreadActivity?
    /// The channel details inspector (members, favorite/mute, leave).
    public var isChannelInfoVisible = false {
        didSet {
            guard isChannelInfoVisible, !oldValue else { return }
            if thread != nil || replyTarget != nil { closeThread() }
            if isSearchVisible { isSearchVisible = false }
        }
    }
    /// Bumped after an explicit channel setting change so the inspector reloads.
    public private(set) var channelInfoRevision: UInt64 = 0
    public var isThreadVisible: Bool { thread != nil }
    public var inlineError: String?
    /// The latest ephemeral slash-command reply, shown until dismissed.
    public var commandFeedback: String?
    /// The composer target the user is typing into (channel or thread).
    public private(set) var replyTarget: PostID?
    public var editing: (postID: PostID, originalText: String)?

    @ObservationIgnored private var subscriptions: [Task<Void, Never>] = []
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var directMessageTask: Task<Void, Never>?
    private(set) var isDetached = false
    @ObservationIgnored weak var draftProvider: (any DraftProviding)?
    @ObservationIgnored weak var threadDraftProvider: (any DraftProviding)?

    init(slot: SessionRegistry.Slot, app: AppModel) {
        self.slot = slot
        self.app = app
        subscribe()
    }

    /// Stops consuming snapshots (called when the session is removed).
    func detach() {
        isDetached = true
        navigationTask?.cancel()
        directMessageTask?.cancel()
        recoveryTask?.cancel()
        for task in subscriptions { task.cancel() }
        subscriptions.removeAll()
    }

    private func subscribe() {
        let session = slot.session
        let scope = session.scope
        subscriptions.append(Task { [weak self] in
            for await snapshot in session.sidebarUpdates {
                guard let self, !self.requiresAuthentication, !self.isDetached, snapshot.scope == scope else { continue }
                self.sidebar = snapshot
                self.app?.updateDockBadge()
                if let selected = self.selectedChannel,
                   !snapshot.sections.contains(where: { $0.rows.contains(where: { $0.channelID == selected }) }) {
                    self.saveDrafts()
                    self.draftProvider?.discardEditingState()
                    self.threadDraftProvider?.discardEditingState()
                    self.selectedChannel = nil
                    self.timeline = nil
                    self.thread = nil
                    self.replyTarget = nil
                    self.header = nil
                }
                if self.selectedChannel == nil, let first = snapshot.sections.lazy.flatMap(\.rows).first {
                    self.select(channel: first.channelID)
                }
            }
        })
        subscriptions.append(Task { [weak self] in
            for await snapshot in session.timelineUpdates {
                guard let self, !self.requiresAuthentication, !self.isDetached, snapshot.scope == scope else { continue }
                // Only the visible channel's snapshots are applied.
                guard snapshot.target.channelID == self.selectedChannel else { continue }
                self.timeline = snapshot
            }
        })
        subscriptions.append(Task { [weak self] in
            for await snapshot in session.threadUpdates {
                guard let self, !self.requiresAuthentication, !self.isDetached else { continue }
                if let snapshot, snapshot.scope != scope { continue }
                if let snapshot {
                    guard snapshot.target.channelID == self.selectedChannel,
                          case .thread(let root, _) = snapshot.target, root == self.replyTarget else { continue }
                }
                self.thread = snapshot
            }
        })
        subscriptions.append(Task { [weak self] in
            for await header in session.headerUpdates {
                guard let self, !self.requiresAuthentication, !self.isDetached else { continue }
                if let header, header.channelID != self.selectedChannel { continue }
                self.header = header
                draftProvider?.updateComposerAvailability()
                threadDraftProvider?.updateComposerAvailability()
            }
        })
        subscriptions.append(Task { [weak self] in
            for await status in session.connectionUpdates {
                if self?.requiresAuthentication == false { self?.connection = status }
            }
        })
        subscriptions.append(Task { [weak self] in
            for await snapshot in session.searchUpdates {
                guard let self, !self.requiresAuthentication, !self.isDetached, snapshot.scope == scope else { continue }
                self.search = snapshot
            }
        })
        subscriptions.append(Task { [weak self] in
            for await activity in session.threadActivity {
                guard let self, !self.isDetached, !self.requiresAuthentication, activity.scope == scope else { continue }
                self.threadActivity = activity
            }
        })
        subscriptions.append(Task { [weak self] in
            for await alert in session.alerts {
                guard let self, !self.isDetached, !self.requiresAuthentication, alert.scope == scope else { continue }
                self.app?.deliver(alert)
            }
        })
        subscriptions.append(Task { [weak self] in
            for await notice in session.notices {
                guard let self else { continue }
                await handleNotice(notice)
            }
        })
    }

    func handleNotice(_ notice: SessionNotice) async {
        guard !isDetached else { return }
        if notice == .signedOutByServer || notice == .identityChanged {
            saveDrafts()
            requiresAuthentication = true
            connection = .authenticationRequired
            navigationTask?.cancel()
            directMessageTask?.cancel()
            draftProvider?.discardEditingState()
            threadDraftProvider?.discardEditingState()
            sidebar = nil; timeline = nil; thread = nil; header = nil; search = nil
            selectedChannel = nil; replyTarget = nil; editing = nil
            isSearchVisible = false; isQuickSwitcherVisible = false
            _ = await app?.forgetSavedAccount(self)
        } else if requiresAuthentication { return } // Keep the required recovery action visible.
        switch notice {
        case .accessRevoked(let channel) where channel == selectedChannel:
            saveDrafts()
            draftProvider?.discardEditingState()
            threadDraftProvider?.discardEditingState()
            selectedChannel = nil; timeline = nil; thread = nil; header = nil; replyTarget = nil
        default: break
        }
        pendingNotice = notice
        switch notice {
        case .operationFailed: break
        default:
            draftProvider?.clearImages()
            threadDraftProvider?.clearImages()
            app?.layoutCaches.purge(scope: scope)
            await app?.images.purge(scope: scope)
        }
    }

    var noticeText: String? {
        switch pendingNotice {
        case .signedOutByServer: "Your server session has ended. Review and export unsent work before signing in again."
        case .identityChanged: "The server returned a different account. This session has stopped to protect your data. Review and export unsent work before signing in again."
        case .accessRevoked: "Access to a channel was removed. Its messages were cleared; unsent text and attachments remain in this session."
        case .teamRemoved: "Access to a team was removed. Unsent work remains in this session."
        case .operationFailed(let error): UserFacingErrorText.describe(error)
        case nil: nil
        }
    }

    func dismissNotice() { if !requiresAuthentication { pendingNotice = nil } }

    /// Explicit clipboard export only. Attachments stay in their original owners.
    func copyUnsentText(to pasteboard: NSPasteboard = .general) {
        guard recoveryTask == nil, !isDetached else { return }
        saveDrafts()
        isCopyingUnsentText = true
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { recoveryTask = nil; isCopyingUnsentText = false }
            let pending = await session.unsentTexts
            guard !Task.isCancelled, !isDetached, let drafts = app?.environment.drafts else { return }
            let texts = drafts.nonEmptyKeys(for: scope).filter { !drafts.isSubmitting($0) || drafts.draft(for: $0)?.editingPost != nil }
                .compactMap { drafts.draft(for: $0)?.text } + pending
            let text = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !text.isEmpty else { inlineError = "There is no unsent text to copy. Attachments are not copied by this action."; return }
            pasteboard.clearContents()
            if !pasteboard.setString(text, forType: .string) {
                inlineError = "The text could not be copied. Your unsent work remains in this session."
            }
        }
    }

    // MARK: - Navigation

    /// `thread` opens that thread once the channel has been opened (after the old
    /// thread is closed), so a late close cannot dismiss it.
    public func select(channel: ChannelID, focusing post: PostID? = nil, thread root: PostID? = nil) {
        guard !isDetached, !requiresAuthentication else { return }
        guard channel != selectedChannel || post != nil || root != nil else { return }
        navigationTask?.cancel()
        directMessageTask?.cancel()
        saveDrafts()
        selectedChannel = channel
        timeline = nil
        thread = nil
        replyTarget = nil
        header = nil
        editing = nil
        commandFeedback = nil
        isThreadsViewVisible = false
        replyTarget = root
        navigationTask = Task {
            guard !Task.isCancelled else { return }
            await session.closeThread()
            guard !Task.isCancelled else { return }
            await session.openChannel(channel, focusing: post)
            guard !Task.isCancelled, let root else { return }
            await session.openThread(root: root, channel: channel)
        }
    }

    /// Opens a thread from the Threads view: its channel becomes current (for drafts
    /// and permissions) while the Threads view stays on screen.
    public func openThreadFromList(root: PostID, channel: ChannelID) {
        if selectedChannel != channel {
            select(channel: channel, thread: root)
            isThreadsViewVisible = true
        } else {
            isThreadsViewVisible = true
            openThread(root: root)
        }
    }

    public func followedThreads(unreadOnly: Bool, before: PostID?) async throws(UserFacingError) -> ThreadsPage {
        guard !isDetached, !requiresAuthentication else { throw .authenticationRequired }
        return try await session.followedThreads(unreadOnly: unreadOnly, before: before)
    }

    public func setThreadFollowing(_ root: PostID, _ following: Bool) {
        perform { try await $0.setThreadFollowing(root, following) }
    }

    public func markThreadRead(_ root: PostID?) {
        perform { try await $0.markThreadRead(root) }
    }

    public func selectTeam(_ team: TeamID) {
        Task { await session.selectTeam(team) }
    }

    public func openThread(root: PostID) {
        guard let channel = selectedChannel else { return }
        threadDraftProvider?.saveDraft()
        isChannelInfoVisible = false
        replyTarget = root
        Task { await session.openThread(root: root, channel: channel) }
    }

    public func closeThread() {
        threadDraftProvider?.saveDraft()
        replyTarget = nil
        thread = nil
        Task { await session.closeThread() }
    }

    public func openDirectMessage(with user: UserID) {
        guard directMessageTask == nil, !isDetached, !requiresAuthentication else { return }
        directMessageTask = Task {
            defer { directMessageTask = nil }
            do throws(UserFacingError) {
                let channel = try await session.directMessageChannel(with: user)
                guard !Task.isCancelled else { return }
                self.select(channel: channel)
            } catch {
                if !Task.isCancelled { self.inlineError = UserFacingErrorText.describe(error) }
            }
        }
    }

    public func open(_ item: QuickSwitchItem) {
        isQuickSwitcherVisible = false
        switch item.kind {
        case .channel(let id): select(channel: id)
        case .user(let id): openDirectMessage(with: id)
        }
    }

    public func open(_ result: SearchResultItem) {
        select(channel: result.channelID, focusing: result.postID)
    }

    public func quickSwitcherResults(_ query: String) async -> [QuickSwitchItem] {
        await session.quickSwitcherResults(query: query)
    }

    public func showRecentMentions() {
        isSearchVisible = true
        Task { await session.showRecentMentions() }
    }

    public func showSavedPosts() {
        isSearchVisible = true
        Task { await session.showSavedPosts() }
    }

    public func showPinnedPosts() {
        guard let channel = selectedChannel else { return }
        isSearchVisible = true
        Task { await session.showPinnedPosts(channel: channel) }
    }

    /// Opens a result's thread in the trailing pane (replacing the results).
    public func openThread(for result: SearchResultItem) {
        let root = result.rootID ?? result.postID
        isSearchVisible = false
        if selectedChannel != result.channelID { select(channel: result.channelID, thread: root) } else { openThread(root: root) }
    }

    public func runSearch(_ terms: String) {
        Task { await session.search(terms) }
    }

    public func loadMoreSearchResults() {
        Task { await session.loadMoreSearchResults() }
    }

    public func clearSearch() {
        Task { await session.clearSearch() }
    }

    // MARK: - People and channel details

    public func profile(for user: UserID) async -> UserProfilePresentation? {
        guard !isDetached, !requiresAuthentication else { return nil }
        let result = await session.profile(for: user)
        return isDetached ? nil : result
    }

    public func profile(username: String) async -> UserProfilePresentation? {
        guard !isDetached, !requiresAuthentication else { return nil }
        let result = await session.profile(username: username)
        return isDetached ? nil : result
    }

    public func channelDetails(_ id: ChannelID) async throws(UserFacingError) -> ChannelDetailsPresentation {
        guard !isDetached, !requiresAuthentication else { throw .authenticationRequired }
        return try await session.channelDetails(id)
    }

    public func channelMembers(_ id: ChannelID, page: Int) async throws(UserFacingError) -> ChannelMembersPage {
        guard !isDetached, !requiresAuthentication else { throw .authenticationRequired }
        return try await session.channelMembers(id, page: page)
    }

    /// Opens a `~channel` mention when it names a channel the user belongs to.
    public func openChannel(named name: String) {
        Task {
            guard let id = await session.memberChannel(named: name) else {
                inlineError = String(localized: "You are not a member of ~\(name), or it is not available on this team.")
                return
            }
            select(channel: id)
        }
    }

    public func setFavorite(_ channel: ChannelID, _ favorite: Bool) {
        perform { try await $0.setFavorite(channel, favorite) }
    }

    public func updateChannel(_ channel: ChannelID, displayName: String?, header: String?, purpose: String?) {
        perform { try await $0.updateChannel(channel, displayName: displayName, header: header, purpose: purpose) }
    }

    public func setMuted(_ channel: ChannelID, _ muted: Bool) {
        perform { try await $0.setMuted(channel, muted) }
    }

    public func setCustomStatus(emoji: String, text: String, duration: CustomStatusDuration) {
        perform { try await $0.setCustomStatus(emoji: emoji, text: text, duration: duration) }
    }

    public func setStatus(_ status: PresenceStatus) {
        perform { try await $0.setOwnStatus(status) }
    }

    /// Leaves after confirmation. Drafts for the channel stay in the unsent-work list.
    public func leaveChannel(_ channel: ChannelID, displayName: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Leave \(displayName)?")
        alert.informativeText = String(localized: "You will stop receiving messages from this channel. A private channel can only be rejoined if someone adds you again.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Leave Channel"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        saveDrafts()
        perform { [weak self] session in
            try await session.leaveChannel(channel)
            self?.isChannelInfoVisible = false
        }
    }

    private func perform(_ operation: @escaping @MainActor (ServerSession) async throws -> Void) {
        guard !isDetached, !requiresAuthentication else { return }
        Task {
            do {
                try await operation(session)
                channelInfoRevision &+= 1
            } catch {
                let error = error as? UserFacingError ?? .unknown
                if !isDetached, error != .cancelled { inlineError = UserFacingErrorText.describe(error) }
            }
        }
    }

    public func reconnect() {
        guard !requiresAuthentication else { return }
        Task { await session.reconnectNow() }
    }

    // MARK: - Drafts

    func draftKey(root: PostID?) -> DraftKey? {
        guard let channel = selectedChannel else { return nil }
        return DraftKey(scope: scope, channelID: channel, rootID: root)
    }

    func refreshDraft(for key: DraftKey) {
        draftProvider?.refreshDraft(for: key)
        threadDraftProvider?.refreshDraft(for: key)
    }

    func discardDraftEditingState(for key: DraftKey) {
        draftProvider?.discardDraft(for: key)
        threadDraftProvider?.discardDraft(for: key)
    }

    func saveDrafts() {
        draftProvider?.saveDraft()
        threadDraftProvider?.saveDraft()
    }

    func prepareForSignOut() {
        detach()
        draftProvider?.discardEditingState()
        threadDraftProvider?.discardEditingState()
    }

    func unsentWorkCount() async -> Int {
        saveDrafts()
        let drafts = app?.environment.drafts.nonEmptyKeys(for: scope).count ?? 0
        return drafts + (await session.unsentOperationCount)
    }

    // MARK: - App state

    public func updateAppState(isActive: Bool, isWindowVisible: Bool) {
        Task { await session.updateAppState(isActive: isActive, isWindowVisible: isWindowVisible) }
    }

    public func systemDidWake() {
        Task { await session.systemDidWake() }
    }

    public func networkPathChanged() {
        Task { await session.networkPathChanged() }
    }

    public func userActivity() {
        Task { await session.reportUserActivity(isActive: true) }
    }
}

/// Implemented by the composer bridge so the view model can persist drafts on
/// navigation without knowing AppKit details.
@MainActor
protocol DraftProviding: AnyObject {
    func saveDraft()
    func discardEditingState()
    func refreshDraft(for key: DraftKey)
    func discardDraft(for key: DraftKey)
    func clearImages()
    func updateComposerAvailability()
}
