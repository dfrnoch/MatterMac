import Foundation
public import MatterMacModels
import MattermostAPI
import MattermostRealtime

/// Which posts notify, following the official client's desktop rules
/// (`webapp actions/notification_actions`), simplified where MatterMac lacks state:
///
/// - Muted channels (`mark_unread = mention`) never notify, as in the official client.
/// - The channel's `desktop` level wins unless it is `default`, which resolves to the
///   account level. A group message whose channel level is `default` notifies for
///   every message even when the account level is "mentions" (official behavior).
/// - `none` never notifies, also for direct messages.
/// - A mention is the server-computed `mentions` list, or a client-side match of
///   `@username`, custom keywords, the first name (when enabled) and @channel/@all/
///   @here when the account's `channel` setting is on and this channel's
///   `ignore_channel_mentions` is not `on` (the server's rule).
/// - Collapsed channel replies also notify server-selected desktop followers. The
///   posted event's `followers` list already resolves `desktop_threads` and channel
///   overrides; local follow lists are incomplete and must not substitute for it.
public enum NotificationPolicy {
    public struct Input: Sendable {
        public var post: Post
        public var channelType: ChannelType
        public var serverMentioned: Bool
        public var membership: ChannelMembership?
        public var account: UserNotifyProps
        public var username: String
        public var firstName: String
        public var notifiesThreadFollower: Bool
        public var collapsedThreads: Bool

        public init(post: Post, channelType: ChannelType, serverMentioned: Bool, membership: ChannelMembership?,
                    account: UserNotifyProps, username: String, firstName: String, collapsedThreads: Bool,
                    notifiesThreadFollower: Bool = false) {
            self.post = post
            self.channelType = channelType
            self.serverMentioned = serverMentioned
            self.membership = membership
            self.account = account
            self.username = username
            self.firstName = firstName
            self.notifiesThreadFollower = notifiesThreadFollower
            self.collapsedThreads = collapsedThreads
        }
    }

    public static func kind(for input: Input) -> IncomingMessageAlert.Kind? {
        let post = input.post
        guard !post.type.isSystem, !post.isDeleted else { return nil }
        if input.membership?.markUnread == .mention { return nil }
        let channelLevel = input.membership?.desktop ?? .default
        let level: DesktopNotificationLevel
        switch channelLevel {
        case .all: level = .all
        case .mention: level = .mention
        case .nothing: level = .nothing
        case .default:
            level = input.channelType == .group && input.account.desktop == .mention ? .all : input.account.desktop
        }
        guard level != .nothing else { return nil }
        if isMention(input) { return .mention }
        if input.channelType.isDirectOrGroup {
            // Direct messages always notify at "mentions"; group messages need "all".
            return input.channelType == .direct || level == .all ? .directMessage : nil
        }
        if input.collapsedThreads, post.rootID != nil {
            return input.notifiesThreadFollower ? .channelMessage : nil
        }
        return level == .all ? .channelMessage : nil
    }

    public static func isMention(_ input: Input) -> Bool {
        if input.serverMentioned { return true }
        // Server rule: the account's `channel` setting must be on and the channel must
        // not ignore channel-wide mentions ("off" does not override the account).
        let channelWide = input.account.channelWideMentions && input.membership?.ignoreChannelMentions != .on
        let matcher = MentionMatcher(username: input.username, firstName: input.firstName, props: input.account,
                                     channelWideMentions: channelWide)
        return matcher.matches(input.post.message)
    }

    /// Whitespace-collapsed plain text, at most `limit` characters plus an ellipsis.
    public static func preview(of document: MessageDocument, limit: Int = IncomingMessageAlert.previewCharacters) -> String? {
        let words = document.plainText.prefix(limit * 4).split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let text = words.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

extension ServerSession {
    // MARK: - Alerts

    /// Posts from others that the user's server notification preferences say should
    /// notify, unless the user set Do Not Disturb or is looking at that conversation.
    func alertIfNeeded(_ event: PostedEvent) {
        guard let (kind, channel) = eligibleAlert(event) else { return }
        let post = event.post
        guard post.props.overrideUsername == nil, directory.peekUser(post.userID) == nil else {
            yieldAlert(post, kind: kind, channel: channel)
            return
        }
        // Keep the in-flight event in this queue, so both waiting and resolving
        // content count toward the same budget. Alerts may be dropped; drafts may not.
        let cost = PostStore.estimatedCost(of: post, document: .empty)
        guard pendingAlerts.count < budget.pendingAlerts.count,
              cost <= budget.pendingAlerts.bytes - pendingAlerts.reduce(0, { $0 + $1.cost }),
              !pendingAlerts.contains(where: { $0.event.post.id == post.id }) else { return }
        pendingAlerts.append((event, cost))
        guard !isRunning(.alertSender) else { return }
        run(.alertSender) { session in
            let epoch = session.epoch
            // Across suspension retain only identities, never a second Post copy:
            // purge/delete can release the queued message immediately.
            while let identity = session.pendingAlertIdentity, !Task.isCancelled {
                var resolved: User?
                if session.directory.peekUser(identity.user) == nil {
                    resolved = try? await session.service.users(ids: [identity.user]).first
                }
                guard session.epoch == epoch, session.isActiveSessionAlive, !Task.isCancelled else { return }
                guard let index = session.pendingAlerts.firstIndex(where: { $0.event.post.id == identity.post }) else {
                    continue // Deleted, edited or revoked while resolving this sender.
                }
                if let resolved { session.directory.upsertUser(resolved) }
                let queued = session.pendingAlerts.remove(at: index)
                // Focus, DND, membership and notification preferences may have
                // changed while resolving the sender. Never use the earlier decision.
                if let (kind, channel) = session.eligibleAlert(queued.event) {
                    session.yieldAlert(queued.event.post, kind: kind, channel: channel)
                }
            }
        }
    }

    private var pendingAlertIdentity: (post: PostID, user: UserID)? {
        pendingAlerts.first.map { ($0.event.post.id, $0.event.post.userID) }
    }

    private func eligibleAlert(_ event: PostedEvent) -> (IncomingMessageAlert.Kind, Channel)? {
        let post = event.post
        guard isActiveSessionAlive, post.userID != me.id,
              let channel = directory.channels[post.channelID],
              let member = directory.memberships[channel.id], channel.deleteAt.isZero else { return nil }
        let input = NotificationPolicy.Input(
            post: post, channelType: channel.type, serverMentioned: event.mentionsCurrentUser,
            membership: member, account: me.notifyProps ?? .serverDefault,
            username: me.username, firstName: me.firstName, collapsedThreads: collapsedThreadsActive,
            notifiesThreadFollower: event.notifiesCurrentThreadFollower)
        guard let kind = NotificationPolicy.kind(for: input),
              directory.status(of: me.id)?.silencesNotifications != true else { return nil }
        if collapsedThreadsActive, let root = post.rootID {
            if let read = threadReadMark, read.root == root, read.at >= post.createAt { return nil }
            if appIsActive, windowIsVisible, openThread == .thread(root: root, channel: channel.id) { return nil }
        } else {
            if member.lastViewedAt >= post.createAt { return nil }
            if appIsActive, windowIsVisible, activeChannel == channel.id { return nil }
        }
        return (kind, channel)
    }

    private func yieldAlert(_ post: Post, kind: IncomingMessageAlert.Kind, channel: Channel) {
        let sender = post.props.overrideUsername
            ?? directory.peekUser(post.userID).map { directory.nameFormat.displayName(for: $0) }
            ?? String(localized: "Someone")
        let preview = alertPreviewsEnabled ? NotificationPolicy.preview(of: deps.documents.document(for: post)) : nil
        alertContinuation.yield(IncomingMessageAlert(
            scope: scope, channelID: channel.id, rootID: post.rootID, kind: kind,
            channelName: displayName(of: channel), senderName: String(sender.prefix(128)), preview: preview,
            soundEnabled: (me.notifyProps ?? .serverDefault).desktopSound))
    }

    /// Explicit, in-memory opt-in: include up to 100 characters of plain text in
    /// alerts. Off by default and reset on quit.
    public func setAlertPreviews(_ enabled: Bool) {
        alertPreviewsEnabled = enabled
    }

    /// Adopts a fresh copy of the signed-in user. Sanitized copies (some broadcasts)
    /// carry no notification properties; the known ones are kept then.
    func adoptCurrentUser(_ user: User) {
        var user = user
        if user.notifyProps == nil { user.notifyProps = me.notifyProps }
        let changed = user.notifyProps != me.notifyProps || user.firstName != me.firstName
        me = user
        directory.pin(user)
        if changed { markDirty(.settings) }
    }

    // MARK: - Account settings snapshot

    public func accountSettings() -> AccountSettingsSnapshot {
        AccountSettingsSnapshot(
            scope: scope, username: me.username, firstName: me.firstName,
            display: .init(militaryTime: directory.militaryTimePreference, nameFormat: directory.nameFormat,
                           preferredNameFormat: directory.preferredNameFormat, serverNameFormat: directory.serverNameFormat,
                           isNameFormatLocked: directory.isNameFormatLocked,
                           collapsedThreadsMode: capabilities.collapsedThreads,
                           collapsedThreadsActive: collapsedThreadsActive),
            notifications: me.notifyProps)
    }

    func publishAccountSettings() {
        guard isActiveSessionAlive else { return }
        accountSettingsContinuation.yield(accountSettings())
    }

    // MARK: - Display preferences (explicit server changes)

    public func setMilitaryTime(_ enabled: Bool) async throws(UserFacingError) {
        try await saveDisplayPreference("use_military_time", enabled ? "true" : "false")
    }

    public func setNameFormat(_ format: NameFormat) async throws(UserFacingError) {
        guard !directory.isNameFormatLocked else { throw .permissionDenied }
        try await saveDisplayPreference("name_format", format.rawValue)
    }

    /// Only when the server's `CollapsedThreads` is `default_on` or `default_off`.
    public func setCollapsedThreads(_ enabled: Bool) async throws(UserFacingError) {
        guard capabilities.collapsedThreads == .defaultOn || capabilities.collapsedThreads == .defaultOff else {
            throw .unsupportedCapability("collapsed_reply_threads")
        }
        try await saveDisplayPreference("collapsed_reply_threads", enabled ? "on" : "off")
    }

    private func saveDisplayPreference(_ name: String, _ value: String) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let preference = Preference(category: "display_settings", name: name, value: value)
        do {
            try await service.savePreferences([preference], me: me.id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard isActiveSessionAlive else { throw .cancelled }
        applyPreferences([preference], deleted: false)
    }

    /// Applies preference changes (explicit saves and realtime events) and reloads
    /// timelines when collapsed reply threads turned on or off.
    func applyPreferences(_ preferences: [Preference], deleted: Bool) {
        let crtBefore = collapsedThreadsActive
        for preference in preferences { directory.apply(preference, deleted: deleted) }
        markDirty([.sidebar, .timeline, .thread, .header, .settings])
        if crtBefore != collapsedThreadsActive { reloadAfterCollapsedThreadsChange() }
    }

    /// Channel windows hold (or hide) replies depending on the mode, so they are
    /// dropped and the visible one reloaded, like the official client's full reload.
    func reloadAfterCollapsedThreadsChange() {
        deps.diagnostics.record(.sync, .info, "collapsed threads changed")
        refreshThreadTotals()
        for target in windows.keys {
            guard case .channel(let channel) = target else { continue }
            if channel == activeChannel { startInitialLoadReplacingWindow(target) } else { closeWindow(target) }
        }
        markDirty(.all)
    }

    // MARK: - Account notification settings (explicit server changes)

    /// Writes the complete `notify_props` map with the given changes applied.
    public func updateAccountNotifications(_ change: @Sendable (inout UserNotifyProps) -> Void) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard var props = me.notifyProps, props.isComplete else { throw .unsupportedCapability("notify_props") }
        change(&props)
        let epoch = epoch
        let updated: User
        do {
            updated = try await service.patchNotifyProps(props, me: me.id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
        guard updated.id == me.id else { throw .malformedServerData }
        var user = updated
        if user.notifyProps == nil { user.notifyProps = props }
        adoptCurrentUser(user)
        markDirty(.settings)
    }

    // MARK: - Channel notification preferences (explicit server changes)

    public func channelNotificationPreferences(_ id: ChannelID) throws(UserFacingError) -> ChannelNotificationPreferences {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let channel = directory.channels[id], let member = directory.memberships[id] else {
            throw .notFoundOrInaccessible
        }
        let account = me.notifyProps ?? .serverDefault
        return ChannelNotificationPreferences(
            channelID: id, channelName: displayName(of: channel), channelType: channel.type, desktop: member.desktop,
            isMuted: member.markUnread == .mention, ignoreChannelMentions: member.ignoreChannelMentions,
            accountDesktop: account.desktop, accountChannelWideMentions: account.channelWideMentions)
    }

    /// Sends only the properties that differ from the current membership.
    public func setChannelNotificationPreferences(_ id: ChannelID, desktop: ChannelDesktopLevel, muted: Bool,
                                                  ignoreChannelMentions: IgnoreChannelMentions) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let member = directory.memberships[id] else { throw .notFoundOrInaccessible }
        let markUnread: MarkUnreadLevel = muted ? .mention : .all
        let change = ChannelNotifyPropsChange(
            desktop: member.desktop == desktop ? nil : desktop,
            markUnread: member.markUnread == markUnread ? nil : markUnread,
            ignoreChannelMentions: member.ignoreChannelMentions == ignoreChannelMentions ? nil : ignoreChannelMentions)
        guard !change.isEmpty else { return }
        do {
            try await service.updateChannelNotifyProps(id, change, me: me.id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard isActiveSessionAlive else { throw .cancelled }
        directory.updateMembership(id) {
            $0.desktop = desktop
            $0.markUnread = markUnread
            $0.ignoreChannelMentions = ignoreChannelMentions
        }
        markDirty([.sidebar, .header])
    }
}
