import Foundation
import MatterMacModels
import MattermostAPI
import MattermostRealtime

extension ServerSession {
    // MARK: - Consumer

    /// The single consumer of the realtime mailbox. Deliveries are processed in order;
    /// snapshots are published once per drained batch via `markDirty` coalescing.
    func startRealtimeConsumer() {
        run(.realtimeConsumer) { session in
            let realtime = session.realtime
            while !Task.isCancelled {
                guard let delivery = await realtime.nextDelivery() else { break }
                guard session.isActiveSessionAlive else { break }
                session.handle(delivery)
            }
        }
    }

    func handle(_ delivery: RealtimeDelivery) {
        guard isActiveSessionAlive else { return }
        switch delivery {
        case .state(let state):
            handleRealtimeState(state)
        case .event(let event):
            handle(event)
        case .resynchronize(let reason):
            deps.diagnostics.record(.realtime, .info, "resynchronize", code: Int64(reasonCode(reason)))
            startResync()
        }
    }

    func reasonCode(_ reason: ResynchronizationReason) -> Int {
        switch reason {
        case .initialConnection: 0
        case .newConnection: 1
        case .sequenceGap: 2
        case .mailboxOverflow: 3
        case .oversizedEvent: 4
        default: 5
        }
    }

    func handleRealtimeState(_ state: RealtimeState) {
        realtimeState = state
        if case .connected = state { consecutiveRealtimeFailures = 0 }
        if case .backingOff = state {
            consecutiveRealtimeFailures += 1
            // An expired token still upgrades (101) and is then closed silently after
            // 5 s, so the socket alone cannot tell "revoked" from "network". Probe REST.
            if consecutiveRealtimeFailures == 2 || consecutiveRealtimeFailures % 10 == 0 { probeAuthentication() }
        }
        switch state {
        case .disconnected: setConnection(.disconnected)
        case .connecting: setConnection(.connecting)
        case .authenticating: setConnection(.authenticating)
        case .connected:
            if !isRunning(.resync) { setConnection(.connected) }
            resumeQueuedSends()
        case .backingOff(let seconds): setConnection(.backingOff(retryInSeconds: seconds))
        case .authenticationRequired:
            setConnection(.authenticationRequired)
            notify(.signedOutByServer)
        case .stopped: setConnection(.disconnected)
        }
        // Stale labels depend on connection state.
        markDirty([.timeline, .thread])
    }

    // MARK: - Events

    func handle(_ event: RealtimeEvent) {
        guard isActiveSessionAlive else { return }
        switch event {
        case .posted(let posted):
            handlePosted(posted)
        case .postEdited(let post):
            journal.append(.upsert(post))
            if store.upsert(post, insertIfMissing: false) != .notPresent { markDirty([.timeline, .thread, .search]) }
            if collapsedThreadsActive, let root = post.rootID { updateThreadRoot(root) }
        case .postDeleted(let post):
            handleDeleted(post)
        case .ephemeralMessage:
            // Ephemeral system responses (e.g. slash-command output) are not supported
            // in v1 because MatterMac does not send slash commands.
            break
        case .reactionAdded(let reaction):
            journal.append(.reaction(reaction, added: true))
            if store.applyReaction(reaction, added: true) { markDirty([.timeline, .thread]) }
        case .reactionRemoved(let reaction):
            journal.append(.reaction(reaction, added: false))
            if store.applyReaction(reaction, added: false) { markDirty([.timeline, .thread]) }
        case .typing(let user, let channel, _):
            guard user != me.id else { return }
            var entries = typing[channel] ?? [:]
            if entries.count >= 16, entries[user] == nil { return }
            entries[user] = ContinuousClock.now.advanced(by: .seconds(6))
            typing[channel] = entries
            if typing.count > 64 { typing = typing.filter { $0.key == activeChannel } }
            scheduleTypingExpiry()
            if channel == activeChannel { markDirty(.header) }
        case .statusChanged(let user, let status):
            directory.setStatus(status, for: user)
            markDirty([.sidebar, .header])
        case .channelsViewed(let times):
            for (channel, time) in times { markViewedLocally(channel, at: time) }
            markDirty(.sidebar)
        case .channelCreated(let channel, _), .directAdded(let channel), .groupAdded(let channel),
             .channelRestored(let channel), .channelConverted(let channel), .channelChanged(let channel):
            fetchChannel(channel)
        case .channelUpdated(let channel):
            if directory.channels[channel.id] != nil {
                directory.upsertChannel(channel)
                markDirty([.sidebar, .header, .timeline])
            }
        case .channelDeleted(let channel, let deleteAt):
            directory.updateChannel(channel) { $0.deleteAt = deleteAt.isZero ? MattermostTimestamp(milliseconds: 1) : deleteAt }
            markDirty([.sidebar, .header, .timeline])
        case .channelMemberUpdated(let membership):
            guard membership.userID == me.id else { return }
            directory.upsertMembership(membership)
            markDirty(.sidebar)
        case .userAdded(let user, let channel, _):
            if user == me.id { fetchChannel(channel) } else { memberCounts[channel] = nil; if channel == activeChannel { loadMemberCount(channel) } }
        case .userRemoved(let user, let channel, _):
            if user == me.id {
                deps.diagnostics.record(.sync, .info, "membership revoked")
                purgeChannel(channel, reason: nil)
            } else {
                memberCounts[channel] = nil
                if channel == activeChannel { loadMemberCount(channel) }
            }
        case .addedToTeam(_, let user):
            if user == me.id { refreshTeams() }
        case .leftTeam(let team, let user):
            guard user == me.id else { return }
            let name = directory.teams[team]?.displayName ?? ""
            for channel in directory.removeTeam(team) { purgeChannel(channel, reason: .teamRemoved(teamName: name)) }
            if selectedTeam == team { selectedTeam = directory.sortedTeams.first?.id }
            notify(.teamRemoved(teamName: name))
            markDirty(.all)
        case .teamUpdated(let team):
            directory.upsertTeam(team)
            markDirty(.sidebar)
        case .teamDeleted(let team):
            for channel in directory.removeTeam(team) { purgeChannel(channel, reason: nil) }
            markDirty(.all)
        case .userUpdated(let user):
            directory.upsertUser(user)
            if user.id == me.id { me = user; directory.pin(user) }
            markDirty([.timeline, .thread, .sidebar, .header])
        case .userRoleUpdated(let user):
            if user == me.id { refreshIdentity() }
        case .preferencesChanged(let preferences):
            for preference in preferences { directory.apply(preference, deleted: false) }
            markDirty([.sidebar, .timeline, .thread])
        case .preferencesDeleted(let preferences):
            for preference in preferences { directory.apply(preference, deleted: true) }
            markDirty([.sidebar, .timeline, .thread])
        case .postUnread(let unread):
            directory.updateMembership(unread.channelID) { membership in
                membership.lastViewedAt = unread.lastViewedAt
                membership.mentionCount = unread.mentionCount
                membership.mentionCountRoot = unread.mentionCountRoot
                membership.urgentMentionCount = unread.urgentMentionCount
            }
            // The event's counts are not unambiguous across versions; reload the member.
            fetchChannel(unread.channelID)
            markDirty(.sidebar)
        case .threadUpdated(let thread, _), .threadFollowChanged(let thread, _):
            updateThreadRoot(thread)
        case .threadReadChanged:
            break
        case .configChanged, .licenseChanged:
            refreshConfiguration()
        case .emojiAdded, .unhandled:
            break
        }
    }

    func handlePosted(_ event: PostedEvent) {
        let post = event.post
        journal.append(.upsert(post))
        let channelID = post.channelID
        guard directory.channels[channelID] != nil else {
            // A new DM/GM or a channel we were just added to.
            fetchChannel(channelID)
            return
        }
        let isRoot = post.rootID == nil
        directory.updateChannel(channelID) { channel in
            channel.totalMessageCount += 1
            if isRoot { channel.totalMessageCountRoot += 1; channel.lastRootPostAt = max(channel.lastRootPostAt, post.createAt) }
            channel.lastPostAt = max(channel.lastPostAt, post.createAt)
        }
        if post.userID == me.id {
            // Own posts never count as unread.
            let total = directory.channels[channelID]
            directory.updateMembership(channelID) { membership in
                membership.messageCount = total?.totalMessageCount ?? membership.messageCount
                membership.messageCountRoot = total?.totalMessageCountRoot ?? membership.messageCountRoot
                membership.lastViewedAt = max(membership.lastViewedAt, post.createAt)
            }
            if let pendingID = post.pendingPostID, pending.item(pendingID) != nil {
                confirmSend(pendingID, with: post)
                return
            }
        } else if event.mentionsCurrentUser {
            directory.updateMembership(channelID) { membership in
                membership.mentionCount += 1
                if isRoot { membership.mentionCountRoot += 1 }
            }
        }
        insertLive(post)
        markDirty([.sidebar, .timeline, .thread])
        evaluateReadState()
    }

    /// Inserts a live post into every window that shows it (channel timeline unless
    /// CRT hides replies; the open thread for replies).
    func insertLive(_ post: Post) {
        let crt = collapsedThreadsActive
        let alreadyRetained = store.contains(post.id)
        let entry = HistoryWindow.Entry(id: post.id, createAt: post.createAt)
        let channelTarget = TimelineTarget.channel(post.channelID)
        if !(crt && post.rootID != nil), var window = windows[channelTarget], window.isLoaded {
            store.upsert(post)
            if window.insertLive(entry) { store.retain(post.id) }
            windows[channelTarget] = window
        }
        if let root = post.rootID {
            let threadTarget = TimelineTarget.thread(root: root, channel: post.channelID)
            if var window = windows[threadTarget], window.isLoaded {
                store.upsert(post)
                if window.insertLive(entry) { store.retain(post.id) }
                windows[threadTarget] = window
            }
            // A replayed or REST-overlapping copy of a known reply must not count twice.
            if !alreadyRetained { updateThreadRoot(root, newReplyAt: post.createAt) }
        }
        store.collectUnreferenced()
        enforceRetention()
    }

    func updateThreadRoot(_ root: PostID, newReplyAt: MattermostTimestamp? = nil) {
        guard let newReplyAt, var post = store.entry(root)?.post else { return }
        post.replyCount += 1
        post.lastReplyAt = max(post.lastReplyAt, newReplyAt)
        // Keep updateAt monotonic so an older snapshot cannot roll the count back.
        post.updateAt = max(post.updateAt, newReplyAt)
        store.upsert(post)
        markDirty([.timeline, .thread])
    }

    func handleDeleted(_ post: Post) {
        let at = now()
        journal.append(.deleted(post.id, rootOf: post.rootID, at: at))
        var changed = store.markDeleted(post.id, at: at)
        if post.rootID == nil {
            // Deleting a root deletes its thread on the server (no per-reply events).
            for reply in store.replies(to: post.id) { changed = store.markDeleted(reply, at: at) || changed }
            if let thread = openThread, case .thread(let root, _) = thread, root == post.id {
                markDirty(.thread)
            }
        } else if let root = post.rootID, var rootEntry = store.entry(root)?.post, rootEntry.replyCount > 0 {
            rootEntry.replyCount -= 1
            rootEntry.updateAt = MattermostTimestamp(milliseconds: max(rootEntry.updateAt.milliseconds, at.milliseconds))
            store.upsert(rootEntry)
            changed = true
        }
        if changed { markDirty([.timeline, .thread, .search]) }
    }

    func markViewedLocally(_ channel: ChannelID, at time: MattermostTimestamp) {
        let totals = directory.channels[channel]
        directory.updateMembership(channel) { membership in
            membership.lastViewedAt = max(membership.lastViewedAt, time)
            membership.messageCount = totals?.totalMessageCount ?? membership.messageCount
            membership.messageCountRoot = totals?.totalMessageCountRoot ?? membership.messageCountRoot
            membership.mentionCount = 0
            membership.mentionCountRoot = 0
            membership.urgentMentionCount = 0
        }
    }

    func scheduleTypingExpiry() {
        guard !isRunning(.typingExpiry) else { return }
        run(.typingExpiry) { session in
            // One scheduled wake at the soonest expiry; no per-second scanning.
            while !Task.isCancelled {
                let soonest = session.typing.values.flatMap(\.values).min()
                guard let soonest else { return }
                let delay = soonest - ContinuousClock.now
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled else { return }
                let now = ContinuousClock.now
                var changedActive = false
                for (channel, entries) in session.typing {
                    let kept = entries.filter { $0.value > now }
                    if kept.count != entries.count, channel == session.activeChannel { changedActive = true }
                    session.typing[channel] = kept.isEmpty ? nil : kept
                }
                if changedActive { session.markDirty(.header) }
            }
        }
    }

    // MARK: - Resynchronization

    /// REST reconciliation after a new connection id, sequence gap, overflow, or
    /// malformed event (SPEC §10): verify identity, reload teams, channel summaries
    /// and memberships for the selected team, refresh the active window and open
    /// thread with overlap, and re-check posts in the visible window via `/posts/ids`
    /// (which includes deletions). Other windows are marked stale and refresh lazily.
    func startResync() {
        for key in windows.keys { windows[key]?.isStale = true }
        setConnection(.synchronizing)
        markDirty([.timeline, .thread])
        run(.resync) { session in
            let epoch = session.epoch
            do {
                let user = try await session.service.currentUser()
                guard session.epoch == epoch else { return }
                guard user.id == session.me.id else {
                    session.notify(.identityChanged)
                    session.setConnection(.authenticationRequired)
                    return
                }
                session.me = user
                session.directory.pin(user)
                let teams = try await session.service.teams()
                guard session.epoch == epoch else { return }
                let previousTeams = Set(session.directory.teams.keys)
                session.directory.replaceTeams(teams)
                for removed in previousTeams.subtracting(teams.map(\.id)) {
                    for channel in session.directory.removeTeam(removed) { session.purgeChannel(channel, reason: nil) }
                }
                if let team = session.selectedTeam, session.directory.teams[team] == nil {
                    session.selectedTeam = session.directory.sortedTeams.first?.id
                }
                for team in session.directory.loadedTeams where team != session.selectedTeam {
                    // Other teams reload when selected.
                    _ = team
                }
                if let team = session.selectedTeam { await session.loadChannels(team: team) }
                guard session.epoch == epoch else { return }
                if let active = session.activeChannel { await session.reconcileWindow(.channel(active)) }
                if let thread = session.openThread, case .thread(let root, let channel) = thread {
                    await session.reloadThread(root: root, channel: channel)
                }
                guard session.epoch == epoch else { return }
                if session.realtimeState == .connected(resumed: false) || session.realtimeState == .connected(resumed: true) {
                    session.setConnection(.connected)
                }
                session.markDirty(.all)
            } catch {
                guard session.epoch == epoch else { return }
                session.handleAuthenticationFailureIfNeeded(error)
                session.deps.diagnostics.record(.sync, .error, "resync failed")
                if case .connected = session.realtimeState { session.setConnection(.connected) }
            }
        }
    }

    /// Refreshes a retained window after possibly missed events: re-reads the
    /// retained posts (edits/deletions), then catches up newer posts with bounded
    /// overlap; if too far behind, replaces the window with the latest page.
    func reconcileWindow(_ target: TimelineTarget) async {
        guard case .channel(let channelID) = target, let window = windows[target], window.isLoaded else {
            if case .channel = target { startInitialLoad(target) }
            return
        }
        let epoch = epoch
        let journalStart = journal.position
        let ids = Array(window.ids.suffix(200))
        do {
            if !ids.isEmpty {
                let current = try await service.posts(ids: ids)
                guard self.epoch == epoch else { return }
                let returned = Set(current.map(\.id))
                for post in current { store.upsert(post) }
                // Posts not returned are inaccessible now (or permanently deleted).
                for id in ids where !returned.contains(id) { store.markDeleted(id, at: now()) }
            }
            guard var window = windows[target] else { return }
            if !window.hasNewer, let newest = window.newest {
                let crt = collapsedThreadsActive
                var anchor = newest.id
                var pages = 0
                var caughtUp = false
                while pages < 3 {
                    let page = try await service.posts(channel: channelID, query: .after(anchor, perPage: Self.pageSize),
                                                       collapsedThreads: crt, priority: .background)
                    guard self.epoch == epoch, windows[target] != nil else { return }
                    merge(page: page, journalStart: journalStart)
                    window = windows[target] ?? window
                    let added = window.merge(page.posts.filter { !crt || $0.rootID == nil }.map {
                        HistoryWindow.Entry(id: $0.id, createAt: $0.createAt)
                    })
                    for id in added { store.retain(id) }
                    windows[target] = window
                    pages += 1
                    guard page.nextPostID != nil, let next = page.posts.first?.id else {
                        caughtUp = true
                        break
                    }
                    anchor = next
                }
                if !caughtUp {
                    startInitialLoadReplacingWindow(target)
                    return
                }
            }
            windows[target]?.isStale = false
            enforceRetention()
            markDirty(.timeline)
        } catch {
            guard self.epoch == epoch else { return }
            handleAuthenticationFailureIfNeeded(error)
        }
    }

    func probeAuthentication() {
        run(.configRefresh) { session in
            let epoch = session.epoch
            do throws(APIError) {
                let user = try await session.service.currentUser()
                guard session.epoch == epoch else { return }
                if user.id != session.me.id { session.notify(.identityChanged) }
            } catch {
                guard session.epoch == epoch else { return }
                if case .unauthorized = error {
                    session.setConnection(.authenticationRequired)
                    session.notify(.signedOutByServer)
                    await session.realtime.stop()
                }
            }
        }
    }

    func refreshTeams() {
        run(.teamLoad(TeamID(unchecked: "all"))) { session in
            let epoch = session.epoch
            guard let teams = try? await session.service.teams(), session.epoch == epoch else { return }
            session.directory.replaceTeams(teams)
            if session.selectedTeam == nil { session.selectedTeam = session.directory.sortedTeams.first?.id }
            if let team = session.selectedTeam, !session.directory.loadedTeams.contains(team) {
                await session.loadChannels(team: team)
            }
            session.markDirty(.sidebar)
        }
    }

    func refreshIdentity() {
        run(.configRefresh) { session in
            let epoch = session.epoch
            guard let user = try? await session.service.currentUser(), session.epoch == epoch else { return }
            if user.id != session.me.id {
                session.notify(.identityChanged)
                return
            }
            session.me = user
            session.directory.pin(user)
            session.markDirty([.timeline, .thread])
        }
    }

    func refreshConfiguration() {
        run(.configRefresh) { session in
            let epoch = session.epoch
            guard let wire = try? await session.service.fullConfiguration(), session.epoch == epoch else { return }
            session.capabilities = wire.capabilities.merged(over: session.capabilities)
            session.typingEnabled = wire.enableUserTypingMessages ?? true
            session.markDirty([.timeline, .thread, .header])
        }
    }

    // MARK: - System hooks

    public func systemDidWake() async {
        guard isActiveSessionAlive else { return }
        await realtime.requestReconnect(.systemWake)
    }

    public func networkPathChanged() async {
        guard isActiveSessionAlive else { return }
        await realtime.requestReconnect(.networkPathChanged)
    }

    public func reconnectNow() async {
        guard isActiveSessionAlive else { return }
        await realtime.requestReconnect(.userRequested)
    }
}
