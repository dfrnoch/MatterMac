import Foundation
public import MatterMacModels
import MattermostAPI

/// Bounded search state for one session (SPEC §12: server search, cancel superseded
/// queries, paginate, cap retained results).
struct SearchModel {
    var generation: UInt64 = 0
    var terms = ""
    var state: SearchSnapshot.State = .idle
    var results: [PostID] = []
    var page = 0
    var canLoadMore = false
    var isTruncated = false

    mutating func purge(channel: ChannelID) {
        // Results referencing the channel are removed by the caller via the store.
        _ = channel
    }
}

extension ServerSession {
    // MARK: - Users

    /// Fetches missing author/partner profiles in batches, coalesced into one task.
    func scheduleUserFetch() {
        guard !isRunning(.userFetch), !missingUsers.isEmpty else { return }
        run(.userFetch) { session in
            let epoch = session.epoch
            while !session.missingUsers.isEmpty, !Task.isCancelled {
                let batch = Array(session.missingUsers.prefix(200))
                session.missingUsers.subtract(batch)
                guard let users = try? await session.service.users(ids: batch), session.epoch == epoch else { return }
                for user in users { session.directory.upsertUser(user) }
                session.markDirty([.timeline, .thread, .sidebar, .header, .search])
            }
        }
    }

    public func profile(for user: UserID) async -> UserProfilePresentation? {
        guard isActiveSessionAlive else { return nil }
        let epoch = epoch
        if directory.peekUser(user) == nil {
            guard let fetched = try? await service.users(ids: [user]).first, self.epoch == epoch, isActiveSessionAlive else { return nil }
            directory.upsertUser(fetched)
        }
        guard let value = directory.peekUser(user) else { return nil }
        // Other users' presence is only polled; refresh it when a profile is opened.
        if let statuses = try? await service.statuses(ids: [user]), let status = statuses[user] {
            guard self.epoch == epoch, isActiveSessionAlive else { return nil }
            directory.setStatus(status, for: user)
        }
        guard self.epoch == epoch, isActiveSessionAlive else { return nil }
        return UserProfilePresentation(user: value, displayName: directory.nameFormat.displayName(for: value),
                                       status: directory.status(of: user), isCurrentUser: user == me.id)
    }

    // MARK: - Presence

    /// Other users' statuses are not pushed by the server (status_change is self-only),
    /// so visible DM partners and visible authors are polled — only while the window is
    /// visible and the app active, at most once a minute, ≤ 200 ids.
    func refreshPresenceSoon() {
        guard appIsActive, windowIsVisible, !isRunning(.presence) else { return }
        run(.presence) { session in
            while !Task.isCancelled {
                guard session.appIsActive, session.windowIsVisible else { return }
                let ids = session.presenceCandidates()
                if !ids.isEmpty, let statuses = try? await session.service.statuses(ids: ids), !Task.isCancelled {
                    for (user, status) in statuses { session.directory.setStatus(status, for: user) }
                    session.markDirty([.sidebar, .header])
                }
                try? await session.deps.clock.sleep(for: .seconds(60))
            }
        }
    }

    func presenceCandidates() -> [UserID] {
        // The signed-in user first: `status_change` only reports later changes.
        var ids: [UserID] = [me.id]
        var seen: Set<UserID> = [me.id]
        for channel in directory.channels.values where channel.type == .direct {
            if let partner = channel.directPartner(of: me.id), seen.insert(partner).inserted { ids.append(partner) }
            if ids.count >= 150 { break }
        }
        if let active = activeChannel, let window = windows[.channel(active)] {
            for entry in window.entries.suffix(60) {
                if let author = store.post(entry.id)?.userID, author != me.id, seen.insert(author).inserted {
                    ids.append(author)
                }
                if ids.count >= 200 { break }
            }
        }
        return ids
    }

    // MARK: - Direct messages

    /// Resolves the channel; the UI selects it before asking Core to publish history.
    public func directMessageChannel(with user: UserID) async throws(UserFacingError) -> ChannelID {
        guard isActiveSessionAlive, !Task.isCancelled else { throw .cancelled }
        if let existing = directory.channels.values.first(where: { $0.type == .direct && $0.directPartner(of: me.id) == user }) {
            return existing.id
        }
        do {
            let channel = try await service.createDirectChannel(with: user, me: me.id)
            guard isActiveSessionAlive, !Task.isCancelled else { throw UserFacingError.cancelled }
            let membership = try await service.channelMembership(channel.id)
            guard isActiveSessionAlive else { throw UserFacingError.cancelled }
            directory.upsertChannel(channel)
            directory.upsertMembership(membership)
            if directory.peekUser(user) == nil { missingUsers.insert(user) }
            markDirty(.sidebar)
            return channel.id
        } catch let error as UserFacingError {
            throw error
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    public func joinChannel(_ id: ChannelID) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        do {
            try await service.joinChannel(id, me: me.id)
            guard isActiveSessionAlive else { throw APIError.cancelled }
            fetchChannel(id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    public func leaveChannel(_ id: ChannelID) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        do {
            try await service.leaveChannel(id, me: me.id)
            guard isActiveSessionAlive else { throw APIError.cancelled }
            purgeChannel(id, reason: nil)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    // MARK: - Quick switcher & completions

    public func quickSwitcherResults(query: String, limit: Int = 20) async -> [QuickSwitchItem] {
        guard isActiveSessionAlive else { return [] }
        let epoch = epoch
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let crt = collapsedThreadsActive
        var results: [QuickSwitchItem] = []
        for channel in directory.channels.values {
            let name = displayName(of: channel)
            guard needle.isEmpty || name.lowercased().contains(needle) || channel.name.lowercased().contains(needle)
            else { continue }
            let team = channel.teamID.flatMap { directory.teams[$0]?.displayName } ?? ""
            results.append(QuickSwitchItem(kind: .channel(channel.id), title: name,
                                           subtitle: channel.type.isDirectOrGroup ? String(localized: "Direct message") : team,
                                           channelType: channel.type,
                                           isUnread: directory.unread(for: channel.id, collapsedThreads: crt).isUnread))
        }
        results.sort {
            if $0.isUnread != $1.isUnread { return $0.isUnread }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        results = Array(results.prefix(limit))
        // People without an existing DM, from the server's user autocomplete.
        if needle.count >= 2, let team = selectedTeam, results.count < limit,
           let users = try? await service.autocompleteUsers(team: team, channel: nil, name: needle, limit: 10) {
            guard self.epoch == epoch, isActiveSessionAlive else { return [] }
            let existing = Set(directory.channels.values.compactMap { $0.directPartner(of: me.id) })
            for user in users where user.id != me.id && !existing.contains(user.id) && !user.isDeactivated {
                directory.upsertUser(user)
                results.append(QuickSwitchItem(kind: .user(user.id), title: directory.nameFormat.displayName(for: user),
                                               subtitle: "@" + user.username, channelType: .direct, isUnread: false))
            }
        }
        return Array(results.prefix(limit))
    }

    public func completions(trigger: Character, query: String, channel: ChannelID?, rootID: PostID? = nil) async -> [CompletionCandidate] {
        guard isActiveSessionAlive, !Task.isCancelled else { return [] }
        let epoch = epoch
        let needle = query.lowercased()
        switch trigger {
        case "/":
            return await commandCompletions(query, channel: channel, rootID: rootID)
        case "@":
            var items: [CompletionCandidate] = []
            if needle.isEmpty || "channel".hasPrefix(needle) || "here".hasPrefix(needle) || "all".hasPrefix(needle) {
                for special in ["here", "channel", "all"] where needle.isEmpty || special.hasPrefix(needle) {
                    items.append(CompletionCandidate(kind: .special, id: special, title: "@" + special,
                                                     subtitle: String(localized: "Notifies everyone in the channel"),
                                                     insertion: "@" + special))
                }
            }
            guard let team = directory.channels[channel ?? ChannelID(unchecked: "none")]?.teamID ?? selectedTeam,
                  let users = try? await service.autocompleteUsers(team: team, channel: channel, name: needle, limit: 8)
            else { return items }
            guard self.epoch == epoch, !Task.isCancelled else { return [] }
            for user in users where !user.isDeactivated {
                directory.upsertUser(user)
                items.append(CompletionCandidate(kind: .user, id: user.id.rawValue, title: "@" + user.username,
                                                 subtitle: user.fullName, insertion: "@" + user.username))
            }
            return Array(items.prefix(8))
        case "~":
            let team = channel.flatMap { directory.channels[$0]?.teamID } ?? selectedTeam
            return directory.channels.values
                .filter { ($0.type == .open || $0.type == .private) && $0.teamID == team }
                .filter { needle.isEmpty || $0.name.hasPrefix(needle) || $0.displayName.lowercased().hasPrefix(needle) }
                .sorted { $0.name < $1.name }
                .prefix(8)
                .map { CompletionCandidate(kind: .channel, id: $0.id.rawValue, title: "~" + $0.name,
                                           subtitle: $0.displayName, insertion: "~" + $0.name) }
        case ":":
            // System (Unicode) emoji from the static catalog (exact, then prefix, then
            // substring matches; `subtitle` carries the glyph), then the server's custom
            // emoji when enabled (ServerSession+CustomEmoji.swift).
            return await emojiCompletions(needle, limit: 8)
        default:
            return []
        }
    }

    // MARK: - Search

    public func search(_ terms: String) {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        tasks[.search]?.cancel()
        releaseSearchResults()
        searchKind = .terms
        searchState.generation &+= 1
        searchState.terms = trimmed
        searchState.page = 0
        guard !trimmed.isEmpty, let team = selectedTeam else {
            searchState.state = .idle
            markDirty(.search)
            return
        }
        searchState.state = .searching
        markDirty(.search)
        runSearch(team: team, page: 0)
    }

    public func loadMoreSearchResults() {
        guard searchState.canLoadMore, searchState.state == .results, let team = selectedTeam else { return }
        searchState.page += 1
        if searchKind != .terms { runList(searchKind, team: team, page: searchState.page); return }
        runSearch(team: team, page: searchState.page)
    }

    public func clearSearch() {
        tasks[.search]?.cancel()
        releaseSearchResults()
        searchState = SearchModel()
        searchKind = .terms
        markDirty(.search)
    }

    func runSearch(team: TeamID, page: Int) {
        let generation = searchState.generation
        let terms = searchState.terms
        let offset = Int(deps.timeZone().secondsFromGMT())
        run(.search) { session in
            let epoch = session.epoch
            do {
                let result = try await session.service.searchPosts(
                    SearchQuery(team: team, terms: terms, timeZoneOffsetSeconds: offset, page: page, perPage: 20))
                guard session.epoch == epoch, session.searchState.generation == generation else { return }
                let cap = session.budget.searchResults.count
                var added = 0
                for post in result.posts where session.searchState.results.count < cap {
                    guard session.directory.channels[post.channelID] != nil || true else { continue }
                    session.store.upsert(post)
                    if !session.searchState.results.contains(post.id) {
                        session.store.retain(post.id)
                        session.searchState.results.append(post.id)
                        added += 1
                    }
                    if session.directory.peekUser(post.userID) == nil { session.missingUsers.insert(post.userID) }
                }
                session.searchState.isTruncated = session.searchState.results.count >= cap
                session.searchState.canLoadMore = result.posts.count >= 20 && !session.searchState.isTruncated
                session.searchState.state = .results
                session.enforceRetention()
                session.markDirty(.search)
            } catch {
                guard session.epoch == epoch, session.searchState.generation == generation else { return }
                session.searchState.state = .failed(Self.userFacing(error))
                session.markDirty(.search)
            }
        }
    }

    func releaseSearchResults() {
        for id in searchState.results { store.release(id) }
        searchState.results.removeAll()
        store.collectUnreferenced()
        reportRetention()
    }

    func publishSearch() {
        let items: [SearchResultItem] = searchState.results.compactMap { id in
            guard let entry = store.entry(id), !entry.post.isDeleted else { return nil }
            let post = entry.post
            let channel = directory.channels[post.channelID]
            let author = directory.peekUser(post.userID).map { directory.nameFormat.displayName(for: $0) } ?? ""
            let preview = String(entry.document.plainText.prefix(280))
            return SearchResultItem(postID: post.id, channelID: post.channelID,
                                    channelName: channel.map { displayName(of: $0) } ?? String(localized: "Unavailable channel"),
                                    author: author, createdAt: post.createAt, preview: preview, rootID: post.rootID,
                                    authorID: post.userID,
                                    authorAvatarRevision: directory.peekUser(post.userID)?.lastPictureUpdate.milliseconds ?? 0)
        }
        searchContinuation.yield(SearchSnapshot(scope: scope, generation: searchState.generation, terms: searchState.terms,
                                                state: searchState.state, items: items,
                                                isTruncated: searchState.isTruncated,
                                                canLoadMore: searchState.canLoadMore, kind: searchKind))
    }

    /// Opens a search result (or permalink) in its real channel context.
    public func openPost(_ post: PostID, channel: ChannelID) async {
        if directory.channels[channel] == nil { fetchChannel(channel); return }
        await openChannel(channel, focusing: post)
    }
}
