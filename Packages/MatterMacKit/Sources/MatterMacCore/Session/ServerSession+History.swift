public import MatterMacModels
public import MattermostAPI

extension ServerSession {
    static let initialPageSize = 60
    static let unreadContext = 30
    static let pageSize = 60
    /// Windows retained per session beyond the active ones (LRU); also bounded by the
    /// global post budget.
    static let maximumRetainedWindows = 12
    /// A trimmed active window never drops below this many posts.
    static let minimumActiveWindow = 60

    // MARK: - Teams and channels

    public func selectTeam(_ id: TeamID) async {
        guard isActiveSessionAlive, directory.teams[id] != nil else { return }
        selectedTeam = id
        markDirty(.sidebar)
        if !directory.loadedTeams.contains(id) { await loadChannels(team: id) }
        refreshThreadTotals()
    }

    func loadChannels(team: TeamID) async {
        let epoch = epoch
        let revision = membershipRevision
        do {
            async let channels = service.channels(team: team)
            async let members = service.channelMemberships(team: team)
            let (list, memberships) = try await (channels, members)
            guard self.epoch == epoch, membershipRevision == revision, !Task.isCancelled else { return }
            let vanished = directory.replaceChannels(team: team, channels: list, memberships: memberships)
            for id in vanished { purgeChannel(id, reason: nil) }
            // DM partners must be resolvable for sidebar names.
            let partners = directory.channels.values.compactMap { $0.directPartner(of: me.id) }
            for partner in partners where directory.peekUser(partner) == nil { missingUsers.insert(partner) }
            markDirty([.sidebar, .header])
            refreshPresenceSoon()
            refreshSidebarOrganization(team: team)
        } catch {
            guard self.epoch == epoch, membershipRevision == revision, !Task.isCancelled else { return }
            deps.diagnostics.record(.sync, .error, "channel list load failed")
            handleAuthenticationFailureIfNeeded(error)
        }
    }

    /// Fetches one channel + membership we learned about from an event.
    func fetchChannel(_ id: ChannelID) {
        guard !isRunning(.channelFetch(id)) else { return }
        run(.channelFetch(id)) { session in
            let epoch = session.epoch
            let revision = session.membershipRevision
            do {
                async let channel = session.service.channel(id)
                async let membership = session.service.channelMembership(id)
                let (c, m) = try await (channel, membership)
                guard session.epoch == epoch, session.membershipRevision == revision, !Task.isCancelled else { return }
                switch c.type {
                case .unknown: return
                default: break
                }
                session.directory.upsertChannel(c)
                session.directory.upsertMembership(m)
                if let partner = c.directPartner(of: session.me.id), session.directory.peekUser(partner) == nil {
                    session.missingUsers.insert(partner)
                }
                session.markDirty([.sidebar, .header])
            } catch let error as APIError {
                guard session.epoch == epoch, session.membershipRevision == revision, !Task.isCancelled else { return }
                if case .forbidden = error { session.purgeChannel(id, reason: nil) }
                if case .notFound = error { session.purgeChannel(id, reason: nil) }
            } catch {}
        }
    }

    // MARK: - Opening conversations

    /// Makes `id` the visible channel. A retained, fresh window is published
    /// immediately (retained-channel switch); otherwise an initial page is fetched.
    public func openChannel(_ id: ChannelID, focusing post: PostID? = nil) async {
        guard isActiveSessionAlive, directory.channels[id] != nil else { return }
        let target = TimelineTarget.channel(id)
        activeChannel = id
        if manualUnreadHold != id { manualUnreadHold = nil }
        if let team = directory.channels[id]?.teamID, team != selectedTeam {
            selectedTeam = team
        }
        var window = windows[target] ?? HistoryWindow(target: target)
        window.lastAccess = nextAccessTick()
        if let post, window.contains(post) {
            pendingScroll[target] = .post(post)
        } else if let post {
            windows[target] = window
            markDirty([.timeline, .header, .sidebar])
            await loadAround(post, target: target)
            return
        }
        restoredChannel = nil
        let needsLoad = !window.isLoaded || window.isStale || window.isCached
        if !window.isLoaded {
            let unread = directory.unread(for: id, collapsedThreads: collapsedThreadsActive)
            lastViewedOnOpen[id] = directory.memberships[id]?.lastViewedAt
            if unread.isUnread { pendingScroll[target] = .unreadBoundary } else { pendingScroll[target] = .liveEdge }
        }
        windows[target] = window
        markDirty([.timeline, .header, .sidebar])
        loadMemberCount(id)
        if needsLoad { startInitialLoad(target) }
        evaluateReadState()
    }

    func startInitialLoad(_ target: TimelineTarget) {
        guard case .channel(let channelID) = target else { return }
        let generation = windows[target]?.nextGeneration() ?? 0
        windows[target]?.initialLoad = .loading(generation: generation)
        run(.initialLoad(target)) { session in
            await session.seedWindowFromCache(target, generation: generation)
            guard !Task.isCancelled else { return }
            let epoch = session.epoch
            let journalStart = session.journal.position
            let crt = session.collapsedThreadsActive
            let membership = session.directory.memberships[channelID]
            let unread = session.directory.unread(for: channelID, collapsedThreads: crt)
            do {
                let page: PostPage
                if unread.isUnread, (membership?.lastViewedAt.milliseconds ?? 0) > 0 {
                    page = try await session.service.postsAroundLastUnread(
                        channel: channelID, me: session.me.id, limitBefore: Self.unreadContext,
                        limitAfter: Self.unreadContext, collapsedThreads: crt)
                } else {
                    page = try await session.service.posts(channel: channelID, query: .latest(perPage: Self.initialPageSize),
                                                           collapsedThreads: crt, priority: .interactive)
                }
                guard session.epoch == epoch, !Task.isCancelled, var window = session.windows[target],
                      window.initialLoad == .loading(generation: generation) else { return }
                session.merge(page: page, journalStart: journalStart)
                let entries = page.posts.filter { !crt || $0.rootID == nil }.map {
                    HistoryWindow.Entry(id: $0.id, createAt: $0.createAt)
                }
                let wasCached = window.isCached
                let delta = window.replace(with: entries, hasOlder: page.previousPostID != nil,
                                           hasNewer: page.nextPostID != nil)
                window.initialLoad = .idle
                window.olderState = .idle
                window.newerState = .idle
                if let lastViewed = session.lastViewedOnOpen[channelID], unread.isUnread {
                    window.unreadBoundary = page.posts.reversed().first {
                        $0.createAt > lastViewed && $0.userID != session.me.id && (!crt || $0.rootID == nil)
                    }?.id
                }
                session.apply(delta, to: &window)
                session.windows[target] = window
                session.enforceRetention()
                session.markDirty([.timeline])
                // The visible rows may not change, so no new visibility report would
                // arrive; the channel can be marked read now that it is current.
                if wasCached { session.evaluateReadState() }
            } catch {
                guard session.epoch == epoch, !Task.isCancelled,
                      session.windows[target]?.initialLoad == .loading(generation: generation) else { return }
                session.windows[target]?.initialLoad = .failed(Self.userFacing(error))
                session.windows[target]?.olderState = .failed(Self.userFacing(error))
                session.handleAuthenticationFailureIfNeeded(error)
                session.markDirty([.timeline])
            }
        }
    }

    /// Loads a window centred on `post` (search result / permalink): the post, a page
    /// before, and a page after. The window then has gaps on both sides as needed.
    func loadAround(_ post: PostID, target: TimelineTarget) async {
        guard case .channel(let channelID) = target else { return }
        let generation = windows[target]?.nextGeneration() ?? 0
        windows[target]?.initialLoad = .loading(generation: generation)
        pendingScroll[target] = .post(post)
        run(.initialLoad(target)) { session in
            await session.seedWindowFromCache(target, generation: generation)
            guard !Task.isCancelled else { return }
            let epoch = session.epoch
            let journalStart = session.journal.position
            let crt = session.collapsedThreadsActive
            do {
                async let focus = session.service.post(post)
                async let before = session.service.posts(channel: channelID, query: .before(post, perPage: 30),
                                                         collapsedThreads: crt, priority: .interactive)
                async let after = session.service.posts(channel: channelID, query: .after(post, perPage: 30),
                                                        collapsedThreads: crt, priority: .interactive)
                let (focused, older, newer) = try await (focus, before, after)
                guard session.epoch == epoch, !Task.isCancelled, var window = session.windows[target],
                      window.initialLoad == .loading(generation: generation) else { return }
                // A reply found by search is shown in its thread when CRT hides replies.
                let combined = PostPage(posts: newer.posts + [focused] + older.posts,
                                        related: older.related + newer.related,
                                        nextPostID: newer.nextPostID, previousPostID: older.previousPostID)
                session.merge(page: combined, journalStart: journalStart)
                let entries = combined.posts.filter { !crt || $0.rootID == nil }.map {
                    HistoryWindow.Entry(id: $0.id, createAt: $0.createAt)
                }
                let delta = window.replace(with: entries, hasOlder: older.previousPostID != nil,
                                           hasNewer: newer.nextPostID != nil)
                window.initialLoad = .idle
                session.apply(delta, to: &window)
                session.windows[target] = window
                if crt, let root = focused.rootID {
                    session.pendingScroll[target] = .post(root)
                    await session.openThread(root: root, channel: channelID)
                }
                session.enforceRetention()
                session.markDirty([.timeline])
            } catch {
                guard session.epoch == epoch, !Task.isCancelled,
                      session.windows[target]?.initialLoad == .loading(generation: generation) else { return }
                session.windows[target]?.initialLoad = .failed(Self.userFacing(error))
                session.windows[target]?.olderState = .failed(Self.userFacing(error))
                session.notify(.operationFailed(Self.userFacing(error)))
                session.markDirty([.timeline])
            }
        }
    }

    // MARK: - Paging

    public func loadOlder(_ target: TimelineTarget) async {
        guard isActiveSessionAlive, var window = windows[target], window.hasOlder else { return }
        if case .loading = window.olderState { return }
        if case .thread(let root, let channel) = target {
            // Thread windows page forward from the root; reloading the start is how a
            // trimmed long thread returns to its beginning (documented limitation).
            await reloadThread(root: root, channel: channel)
            return
        }
        guard case .channel(let channelID) = target, let anchor = window.oldest else {
            startInitialLoad(target)
            return
        }
        let generation = window.nextGeneration()
        window.olderState = .loading(generation: generation)
        windows[target] = window
        markDirty(.timeline)
        run(.older(target)) { session in
            let epoch = session.epoch
            let journalStart = session.journal.position
            let crt = session.collapsedThreadsActive
            do {
                let page = try await session.service.posts(
                    channel: channelID, query: .before(anchor.id, perPage: Self.pageSize), collapsedThreads: crt,
                    priority: .interactive)
                guard session.epoch == epoch, !Task.isCancelled, var window = session.windows[target],
                      window.olderState == .loading(generation: generation) else { return }
                session.merge(page: page, journalStart: journalStart)
                let added = window.merge(page.posts.filter { !crt || $0.rootID == nil }.map {
                    HistoryWindow.Entry(id: $0.id, createAt: $0.createAt)
                })
                for id in added { session.store.retain(id) }
                window.hasOlder = page.previousPostID != nil
                window.olderState = .idle
                // Scrolling up: keep the newly loaded older content, trim the newer side.
                let removed = window.trim(toCount: session.budget.activeTimeline.count, keepingAround: anchor.id)
                for id in removed { session.store.release(id) }
                session.windows[target] = window
                session.enforceRetention()
                session.markDirty(.timeline)
            } catch {
                guard session.epoch == epoch, !Task.isCancelled, session.windows[target]?.olderState == .loading(generation: generation)
                else { return }
                session.windows[target]?.olderState = .failed(Self.userFacing(error))
                session.handleAuthenticationFailureIfNeeded(error)
                session.markDirty(.timeline)
            }
        }
    }

    public func loadNewer(_ target: TimelineTarget) async {
        guard isActiveSessionAlive, var window = windows[target], window.hasNewer else { return }
        if case .loading = window.newerState { return }
        let generation = window.nextGeneration()
        window.newerState = .loading(generation: generation)
        windows[target] = window
        markDirty(target == openThread ? .thread : .timeline)
        guard let anchor = window.newest else { return }
        run(.newer(target)) { session in
            let epoch = session.epoch
            let journalStart = session.journal.position
            let crt = session.collapsedThreadsActive
            do {
                let page: PostPage
                switch target {
                case .channel(let channelID):
                    page = try await session.service.posts(
                        channel: channelID, query: .after(anchor.id, perPage: Self.pageSize), collapsedThreads: crt,
                        priority: .interactive)
                case .thread(let root, _):
                    page = try await session.service.thread(
                        root: root, query: ThreadPageQuery(after: (anchor.id, anchor.createAt), perPage: Self.pageSize,
                                                           collapsedThreads: crt))
                }
                guard session.epoch == epoch, !Task.isCancelled, var window = session.windows[target],
                      window.newerState == .loading(generation: generation) else { return }
                session.merge(page: page, journalStart: journalStart)
                let isThread: Bool
                if case .thread = target { isThread = true } else { isThread = false }
                let added = window.merge(page.posts.filter { isThread || !crt || $0.rootID == nil }.map {
                    HistoryWindow.Entry(id: $0.id, createAt: $0.createAt)
                })
                for id in added { session.store.retain(id) }
                window.hasNewer = isThread ? (page.hasNext ?? false) : page.nextPostID != nil
                window.newerState = .idle
                let cap = isThread ? session.budget.threadWindow.count : session.budget.activeTimeline.count
                let removed = window.trim(toCount: cap, keepingAround: anchor.id)
                for id in removed { session.store.release(id) }
                session.windows[target] = window
                session.enforceRetention()
                session.markDirty(isThread ? .thread : .timeline)
            } catch {
                guard session.epoch == epoch, !Task.isCancelled, session.windows[target]?.newerState == .loading(generation: generation)
                else { return }
                session.windows[target]?.newerState = .failed(Self.userFacing(error))
                session.markDirty(target == session.openThread ? .thread : .timeline)
            }
        }
    }

    /// Jumps to the newest posts. If the window has a newer gap it is replaced by the
    /// latest page (the old range becomes an older gap).
    public func jumpToLiveEdge(_ target: TimelineTarget) async {
        guard isActiveSessionAlive, let window = windows[target] else { return }
        pendingScroll[target] = .liveEdge
        if window.hasNewer, case .channel = target {
            startInitialLoadReplacingWindow(target)
        } else {
            markDirty(.timeline)
        }
    }

    func startInitialLoadReplacingWindow(_ target: TimelineTarget) {
        guard case .channel(let channelID) = target else { return }
        let generation = windows[target]?.nextGeneration() ?? 0
        windows[target]?.initialLoad = .loading(generation: generation)
        run(.initialLoad(target)) { session in
            await session.seedWindowFromCache(target, generation: generation)
            guard !Task.isCancelled else { return }
            let epoch = session.epoch
            let journalStart = session.journal.position
            let crt = session.collapsedThreadsActive
            do {
                let page = try await session.service.posts(channel: channelID, query: .latest(perPage: Self.initialPageSize),
                                                           collapsedThreads: crt, priority: .interactive)
                guard session.epoch == epoch, !Task.isCancelled, var window = session.windows[target],
                      window.initialLoad == .loading(generation: generation) else { return }
                session.merge(page: page, journalStart: journalStart)
                let delta = window.replace(
                    with: page.posts.filter { !crt || $0.rootID == nil }.map { HistoryWindow.Entry(id: $0.id, createAt: $0.createAt) },
                    hasOlder: page.previousPostID != nil, hasNewer: false)
                window.initialLoad = .idle
                window.unreadBoundary = nil
                session.apply(delta, to: &window)
                session.windows[target] = window
                session.enforceRetention()
                session.markDirty(.timeline)
            } catch {
                guard session.epoch == epoch, !Task.isCancelled,
                      session.windows[target]?.initialLoad == .loading(generation: generation) else { return }
                session.windows[target]?.initialLoad = .failed(Self.userFacing(error))
                session.markDirty(.timeline)
            }
        }
    }

    public func expand(_ post: PostID, in target: TimelineTarget) {
        guard windows[target]?.contains(post) == true else { return }
        if (windows[target]?.expanded.count ?? 0) >= 32 { windows[target]?.expanded.removeAll() }
        windows[target]?.expanded.insert(post)
        store.bumpRevision(post)
        markDirty(target == openThread ? .thread : .timeline)
    }

    public func retryInitialLoad(_ target: TimelineTarget) {
        if case .thread(let root, let channel) = target {
            Task { await self.reloadThread(root: root, channel: channel) }
        } else {
            startInitialLoad(target)
        }
    }

    // MARK: - Threads

    public func openThread(root: PostID, channel: ChannelID) async {
        guard isActiveSessionAlive else { return }
        let target = TimelineTarget.thread(root: root, channel: channel)
        if let previous = openThread, previous != target { closeWindow(previous) }
        openThread = target
        var window = windows[target] ?? HistoryWindow(target: target)
        window.lastAccess = nextAccessTick()
        window.hasOlder = false
        windows[target] = window
        markDirty(.thread)
        if !window.isLoaded || window.isStale { await reloadThread(root: root, channel: channel) }
    }

    public func closeThread() {
        guard let thread = openThread else { return }
        openThread = nil
        closeWindow(thread)
        markDirty(.thread)
    }

    func reloadThread(root: PostID, channel: ChannelID) async {
        let target = TimelineTarget.thread(root: root, channel: channel)
        guard windows[target] != nil else { return }
        let generation = windows[target]?.nextGeneration() ?? 0
        windows[target]?.initialLoad = .loading(generation: generation)
        markDirty(.thread)
        run(.initialLoad(target)) { session in
            await session.seedWindowFromCache(target, generation: generation)
            guard !Task.isCancelled else { return }
            let epoch = session.epoch
            let journalStart = session.journal.position
            let crt = session.collapsedThreadsActive
            do {
                let page = try await session.service.thread(
                    root: root, query: ThreadPageQuery(after: nil, perPage: Self.pageSize, collapsedThreads: crt))
                guard session.epoch == epoch, !Task.isCancelled, var window = session.windows[target],
                      window.initialLoad == .loading(generation: generation) else { return }
                session.merge(page: page, journalStart: journalStart)
                let delta = window.replace(
                    with: page.posts.map { HistoryWindow.Entry(id: $0.id, createAt: $0.createAt) },
                    hasOlder: false, hasNewer: page.hasNext ?? false)
                window.initialLoad = .idle
                session.apply(delta, to: &window)
                session.windows[target] = window
                session.enforceRetention()
                session.markDirty(.thread)
            } catch {
                guard session.epoch == epoch, !Task.isCancelled,
                      session.windows[target]?.initialLoad == .loading(generation: generation) else { return }
                session.windows[target]?.initialLoad = .failed(Self.userFacing(error))
                if case .notFound = error as? APIError {
                    session.notify(.operationFailed(.notFoundOrInaccessible))
                }
                session.markDirty(.thread)
            }
        }
    }

    // MARK: - Merge & retention

    /// Merges a REST page into the store, then re-applies journaled realtime events
    /// that arrived while the request was in flight.
    func merge(page: PostPage, journalStart: UInt64) {
        for post in page.posts { store.upsert(post) }
        for post in page.related { store.upsert(post) }
        let touched = Set(page.posts.map(\.id) + page.related.map(\.id))
        if let records = journal.records(after: journalStart) {
            for record in records where touched.contains(record.postID) { replay(record) }
        } else {
            // The journal wrapped during the request: we cannot prove this page is
            // current; mark affected windows stale so they refresh.
            for key in windows.keys { windows[key]?.isStale = true }
            deps.diagnostics.record(.sync, .warning, "journal wrapped during request")
        }
        for post in page.posts + page.related {
            if directory.peekUser(post.userID) == nil { missingUsers.insert(post.userID) }
        }
    }

    func replay(_ record: EventJournal.Record) {
        switch record {
        case .upsert(let post): store.upsert(post, insertIfMissing: false)
        case .deleted(let id, _, let at): store.markDeleted(id, at: at)
        case .reaction(let reaction, let added): store.applyReaction(reaction, added: added)
        }
    }

    /// Adjusts store references after a window replacement.
    func apply(_ delta: (added: [PostID], removed: [PostID]), to window: inout HistoryWindow) {
        for id in delta.added { store.retain(id) }
        for id in delta.removed { store.release(id) }
    }

    func closeWindow(_ target: TimelineTarget) {
        guard var window = windows.removeValue(forKey: target) else { return }
        for id in window.removeAll() { store.release(id) }
        tasks[.initialLoad(target)]?.cancel()
        tasks[.older(target)]?.cancel()
        tasks[.newer(target)]?.cancel()
        store.collectUnreferenced()
        reportRetention()
    }

    /// Enforces per-window caps and the (shared, global) retained-post budget.
    /// Eviction order (SPEC §15): inactive windows (LRU) first, then the far sides of
    /// the active windows, never below `minimumActiveWindow`.
    func enforceRetention() {
        let activeTargets = Set([activeChannel.map { TimelineTarget.channel($0) }, openThread].compactMap { $0 })
        // Per-window caps.
        for (target, var window) in windows {
            let cap: Int
            if case .thread = target { cap = budget.threadWindow.count } else { cap = budget.activeTimeline.count }
            if window.count > cap {
                let anchor = visibility[target]?.first ?? visibility[target]?.last
                for id in window.trim(toCount: cap, keepingAround: anchor) { store.release(id) }
                windows[target] = window
            }
        }
        // Bound the number of retained inactive windows.
        let inactive = windows.keys.filter { !activeTargets.contains($0) }
            .sorted { (windows[$0]?.lastAccess ?? 0) < (windows[$1]?.lastAccess ?? 0) }
        if inactive.count > Self.maximumRetainedWindows {
            for target in inactive.prefix(inactive.count - Self.maximumRetainedWindows) { closeWindow(target) }
        }
        store.collectUnreferenced()
        var allowance = deps.retention.allowance(for: scope.server)
        var evictionQueue = windows.keys.filter { !activeTargets.contains($0) }
            .sorted { (windows[$0]?.lastAccess ?? 0) < (windows[$1]?.lastAccess ?? 0) }
        while (store.usage.count > allowance.count || store.usage.bytes > allowance.bytes), !evictionQueue.isEmpty {
            closeWindow(evictionQueue.removeFirst())
            allowance = deps.retention.allowance(for: scope.server)
        }
        // Then shrink active windows from their far side, in steps.
        var shrinkable = true
        while (store.usage.count > allowance.count || store.usage.bytes > allowance.bytes), shrinkable {
            shrinkable = false
            for target in activeTargets {
                guard var window = windows[target], window.count > Self.minimumActiveWindow else { continue }
                let anchor = visibility[target]?.first ?? visibility[target]?.last
                let targetCount = max(Self.minimumActiveWindow, window.count - 20)
                for id in window.trim(toCount: targetCount, keepingAround: anchor) { store.release(id) }
                windows[target] = window
                shrinkable = true
            }
            store.collectUnreferenced()
        }
        reportRetention()
    }

    func reportRetention() {
        deps.retention.report(scope.server, usage: store.usage)
    }

    // MARK: - Membership revocation

    /// Removes a channel and everything derived from it (rows, windows, search hits,
    /// thread views, typing state). Unsent work stays charged until explicitly discarded.
    func purgeChannel(_ id: ChannelID, reason: SessionNotice?) {
        pendingAlerts.removeAll { $0.event.post.channelID == id }
        membershipRevision &+= 1
        tasks.removeValue(forKey: .channelFetch(id))?.cancel()
        memberCounts[id] = nil
        let channel = directory.removeChannel(id)
        removeCachedChannel(id)
        if restoredChannel == id { restoredChannel = nil }
        for target in windows.keys where target.channelID == id { closeWindow(target) }
        _ = store.purge(channel: id)
        searchState.purge(channel: id)
        // An in-flight page may have been authorized before this revocation.
        // Keep unrelated hits, but require a fresh search before paginating again.
        tasks[.search]?.cancel()
        searchState.generation &+= 1
        searchState.canLoadMore = false
        searchState.state = .results
        typing[id] = nil
        for transfer in downloads.values where transfer.channel == id { transfer.task.cancel() }
        let blocked = pending.items.filter { $0.channelID == id }
        if let activeSendID, blocked.contains(where: { $0.pendingID == activeSendID }) {
            tasks[.sender]?.cancel()
        }
        for item in blocked {
            tasks[.sendRetry(item.pendingID)]?.cancel()
            pending.update(item.pendingID) {
                $0.state = item.isInFlight || item.state == .outcomeUnknown
                    ? .outcomeUnknown : .failed(.permissionDenied)
            }
        }
        if activeChannel == id { activeChannel = nil }
        if openThread?.channelID == id { openThread = nil }
        if channel != nil || !blocked.isEmpty {
            notify(reason ?? .accessRevoked(channel: id))
        }
        reportRetention()
        markDirty(.all)
    }

    // MARK: - Errors

    public static func userFacing(_ error: any Error) -> UserFacingError {
        guard let api = error as? APIError else { return .unknown }
        return userFacing(api)
    }

    public static func userFacing(_ error: APIError) -> UserFacingError {
        switch error {
        case .unauthorized: .authenticationRequired
        case .forbidden: .permissionDenied
        case .notFound: .notFoundOrInaccessible
        case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
        case .notSent(let failure), .outcomeUnknown(let failure): SendFailurePolicy.userFacing(failure)
        case .responseTooLarge(let limit): .payloadTooLarge(limitBytes: limit)
        case .malformedResponse: .malformedServerData
        case .server(let info): .serverError(status: info.statusCode)
        case .unexpectedStatus(let status): .serverError(status: status)
        case .cancelled: .cancelled
        case .notImplemented: .unsupportedCapability("server feature")
        case .payloadTooLarge: .payloadTooLarge(limitBytes: 0)
        case .badRequest: .serverError(status: 400)
        case .redirectRefused, .overloaded: .serverUnreachable
        case .localFileUnavailable: .fileUnavailable
        }
    }
}
