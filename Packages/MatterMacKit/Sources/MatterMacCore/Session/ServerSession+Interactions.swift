public import MatterMacModels
import MattermostAPI

// Message interactions beyond sending: pin, save, mark unread, and in-app navigation
// for links into this server (decision 0022). Every call is an explicit user action
// and a server-side change; failures are reported, never retried silently.
extension ServerSession {
    // MARK: - Pin

    /// `POST /posts/{id}/pin|unpin`. The local copy changes on success; the server's
    /// `post_edited` echo (newer `update_at`) then replaces it.
    public func setPinned(_ id: PostID, _ pinned: Bool) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let post = store.post(id), directory.memberships[post.channelID] != nil else {
            throw .notFoundOrInaccessible
        }
        let epoch = epoch
        do {
            try await service.setPinned(id, pinned: pinned)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            if case .badRequest(let info) = error, info.id == ServerErrorID.editTimeLimit { throw .permissionDenied }
            throw Self.userFacing(error)
        }
        guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
        if store.setPinned(id, pinned) { markDirty([.timeline, .thread, .search]) }
    }

    // MARK: - Save (flagged posts)

    /// Saves (`PUT /users/{id}/preferences`) or removes (`…/preferences/delete`) the
    /// `flagged_post` preference for a post.
    public func setSaved(_ id: PostID, _ saved: Bool) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let preference = Preference(category: "flagged_post", name: id.rawValue, value: "true")
        let epoch = epoch
        do {
            if saved { try await service.savePreferences([preference], me: me.id) }
            else { try await service.deletePreferences([preference], me: me.id) }
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
        directory.apply(preference, deleted: !saved)
        markDirty([.timeline, .thread, .search])
    }

    public func isSaved(_ id: PostID) -> Bool { directory.savedPosts.contains(id) }

    // MARK: - Mark as unread

    /// `POST /users/{me}/posts/{post}/set_unread`. Applies the returned read state
    /// locally, shows the "New messages" line above the post, and holds automatic read
    /// marking for the channel until the user acts again (see `updateVisibility`).
    public func markUnread(from id: PostID) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let post = store.post(id), directory.memberships[post.channelID] != nil else {
            throw .notFoundOrInaccessible
        }
        let channel = post.channelID
        let epoch = epoch
        // Stop any queued view request so it cannot undo the change after the fact.
        tasks[.readMark]?.cancel()
        tasks[.readMark] = nil
        taskTokens[.readMark] = nil
        if activeChannel == channel { manualUnreadHold = channel }
        let state: ChannelUnreadState
        do {
            state = try await service.markUnread(from: id, me: me.id)
        } catch {
            if manualUnreadHold == channel, self.epoch == epoch { manualUnreadHold = nil }
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
        applyUnreadState(state)
        let target = TimelineTarget.channel(channel)
        if windows[target]?.contains(id) == true {
            windows[target]?.unreadBoundary = id
            lastViewedOnOpen[channel] = state.lastViewedAt
        }
        // The user may have switched away while the request ran.
        if activeChannel == channel { manualUnreadHold = channel }
        markDirty([.sidebar, .timeline, .header])
    }

    func applyUnreadState(_ state: ChannelUnreadState) {
        directory.updateMembership(state.channelID) { membership in
            membership.lastViewedAt = state.lastViewedAt
            membership.messageCount = state.messageCount
            membership.messageCountRoot = state.messageCountRoot
            membership.mentionCount = state.mentionCount
            membership.mentionCountRoot = state.mentionCountRoot
            membership.urgentMentionCount = state.urgentMentionCount
        }
    }

    /// Whether automatic read marking is currently suspended for `channel`.
    public func isHeldUnread(_ channel: ChannelID) -> Bool { manualUnreadHold == channel }

    // MARK: - Links into this server

    public enum LinkDestination: Sendable, Hashable {
        case channel(ChannelID, focusing: PostID?)
        case directMessage(UserID)
    }

    /// Resolves a permalink, channel or direct-message link for this server. Only
    /// channels the user is a member of are opened; others report
    /// `.notFoundOrInaccessible` (nothing is joined implicitly).
    public func resolve(_ link: MattermostLink) async throws(UserFacingError) -> LinkDestination {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        switch link {
        case .post(_, let postID):
            if let post = store.post(postID), directory.channels[post.channelID] != nil {
                return .channel(post.channelID, focusing: postID)
            }
            let epoch = epoch
            let post: Post
            do {
                post = try await service.post(postID)
            } catch {
                handleAuthenticationFailureIfNeeded(error)
                if case .forbidden = error { throw .notFoundOrInaccessible }
                throw Self.userFacing(error)
            }
            guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
            guard directory.channels[post.channelID] != nil else { throw .notFoundOrInaccessible }
            return .channel(post.channelID, focusing: postID)
        case .channel(let teamName, let name):
            let team = directory.teams.values.first { $0.name == teamName }?.id ?? selectedTeam
            let match = directory.channels.values.first { channel in
                channel.name == name && (channel.teamID == team || channel.teamID == nil)
            }
            guard let match else { throw .notFoundOrInaccessible }
            return .channel(match.id, focusing: nil)
        case .directMessage(_, let username):
            if username == me.username.lowercased() { return .directMessage(me.id) }
            let epoch = epoch
            let users: [User]
            do {
                users = try await service.users(usernames: [username])
            } catch {
                handleAuthenticationFailureIfNeeded(error)
                throw Self.userFacing(error)
            }
            guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
            guard let user = users.first(where: { $0.username.lowercased() == username }) else {
                throw .notFoundOrInaccessible
            }
            directory.upsertUser(user)
            return .directMessage(user.id)
        }
    }
}
