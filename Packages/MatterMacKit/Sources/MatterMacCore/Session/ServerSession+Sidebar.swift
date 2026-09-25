import Foundation
public import MatterMacModels
import MattermostAPI

// Server sidebar categories, team unread counts and team icons (SPEC §4 "read and
// respect server-side preferences"; docs/research/channels.md §1, §9). Categories
// are re-read from REST on every `sidebar_category_*` event rather than patched
// from partial payloads. Collapsing is an explicit server change; grouping unread
// channels is a local, in-memory presentation choice.
extension ServerSession {
    /// Coalesces bursts of category events (one move emits several).
    static let categoryEventDelay: Duration = .milliseconds(150)
    /// Other teams' unread counts are refreshed at most this often from events.
    static let teamUnreadDelay: Duration = .seconds(2)

    /// After a team's channel list (re)loads: categories and other teams' counts.
    func refreshSidebarOrganization(team: TeamID) {
        scheduleCategoryLoad(team: team, delay: .zero)
        refreshTeamUnreads(delay: .zero)
    }

    func scheduleCategoryLoad(team: TeamID, delay: Duration) {
        run(.sidebarCategories(team)) { session in
            if delay > .zero {
                try? await session.deps.clock.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await session.loadCategories(team: team)
        }
    }

    func loadCategories(team: TeamID) async {
        let epoch = epoch
        do {
            let list = try await service.sidebarCategories(team: team, me: me.id)
            guard self.epoch == epoch, !Task.isCancelled, directory.teams[team] != nil else { return }
            directory.replaceCategories(team: team, list)
            markDirty(.sidebar)
        } catch {
            guard self.epoch == epoch else { return }
            if case .cancelled = error { return }
            handleAuthenticationFailureIfNeeded(error)
            // Keep categories loaded earlier (stale but server-shaped); with none, the
            // sidebar falls back to synthesized sections.
            directory.categoriesUnavailable.insert(team)
            deps.diagnostics.record(.sync, .warning, "sidebar categories unavailable")
            markDirty(.sidebar)
        }
    }

    func handleSidebarCategoriesChanged(team: TeamID?) {
        // The data-less variant (favorites preference saved) can affect any team.
        if team == nil {
            for other in directory.categories.keys where other != selectedTeam { directory.removeCategories(team: other) }
        }
        guard let target = team ?? selectedTeam else { return }
        if target == selectedTeam {
            scheduleCategoryLoad(team: target, delay: Self.categoryEventDelay)
        } else {
            // Re-read when that team is shown again.
            directory.removeCategories(team: target)
        }
    }

    /// Loads missing categories for the shown team (after eviction or an event for a
    /// team that was not shown). Called while publishing; never loops on failure.
    func loadCategoriesIfNeeded() {
        guard let team = selectedTeam, directory.loadedTeams.contains(team), directory.categories[team] == nil,
              !directory.categoriesUnavailable.contains(team), !isRunning(.sidebarCategories(team)) else { return }
        scheduleCategoryLoad(team: team, delay: .zero)
    }

    /// Collapses or expands a category on the server (visible in the user's other
    /// clients). The change is shown immediately and reverted if the server refuses.
    /// The category is re-read first so its channel list is written back unchanged.
    public func setCategoryCollapsed(_ id: SidebarCategoryID, collapsed: Bool) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let team = directory.categories.first(where: { $0.value.contains { $0.id == id } })?.key,
              let current = directory.categories[team]?.first(where: { $0.id == id }) else {
            throw .notFoundOrInaccessible
        }
        guard !Task.isCancelled else { throw .cancelled }
        guard current.isCollapsed != collapsed else { return }
        let alreadySaving = directory.pendingCollapse[id] != nil
        directory.pendingCollapse[id] = collapsed
        directory.updateCategory(id, team: team) { $0.isCollapsed = collapsed }
        markDirty(.sidebar)
        // One worker per category; subsequent clicks replace its desired value.
        guard !alreadySaving else { return }
        let epoch = epoch
        var confirmed = current.isCollapsed
        do {
            while directory.pendingCollapse[id] != nil {
                var fresh = try await service.sidebarCategory(id, team: team, me: me.id)
                guard self.epoch == epoch, !Task.isCancelled,
                      let desired = directory.pendingCollapse[id] else { throw APIError.cancelled }
                confirmed = fresh.isCollapsed
                fresh.isCollapsed = desired
                let saved = try await service.updateSidebarCategory(fresh)
                guard self.epoch == epoch else { throw APIError.cancelled }
                confirmed = saved.isCollapsed
                guard !Task.isCancelled else { throw APIError.cancelled }
                if directory.pendingCollapse[id] == desired {
                    directory.pendingCollapse[id] = nil
                    directory.updateCategory(id, team: team) { $0.isCollapsed = saved.isCollapsed }
                    markDirty(.sidebar)
                }
            }
        } catch {
            guard self.epoch == epoch else { throw .cancelled }
            directory.pendingCollapse[id] = nil
            // A later coalesced request can fail after an earlier one succeeded.
            directory.updateCategory(id, team: team) { $0.isCollapsed = confirmed }
            markDirty(.sidebar)
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    /// "Group unread channels separately": local and in memory only.
    public func setGroupsUnreads(_ value: Bool) {
        guard directory.groupsUnreads != value else { return }
        directory.groupsUnreads = value
        directory.stickyUnread = nil
        markDirty(.sidebar)
    }

    // MARK: - Other teams

    func refreshTeamUnreads(delay: Duration) {
        guard directory.teams.count > 1 else { return }
        if delay > .zero, isRunning(.teamUnreads) { return }
        run(.teamUnreads) { session in
            if delay > .zero {
                try? await session.deps.clock.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let epoch = session.epoch
            guard let list = try? await session.service.teamUnreads(includeCollapsedThreads: session.collapsedThreadsActive),
                  session.epoch == epoch, !Task.isCancelled else { return }
            session.directory.teamUnreads = Dictionary(list.prefix(500).map { ($0.teamID, $0) },
                                                       uniquingKeysWith: { first, _ in first })
            session.markDirty(.sidebar)
        }
    }

    /// A post in a team whose channels are not loaded changes only its team badge.
    func noteTeamActivity(_ team: TeamID?) {
        guard let team, team != selectedTeam, !directory.loadedTeams.contains(team), directory.teams[team] != nil
        else { return }
        refreshTeamUnreads(delay: Self.teamUnreadDelay)
    }

    /// The team's icon through the shared bounded image pipeline.
    public func teamIcon(_ team: TeamID, revision: Int64, maxPixelSize: Int,
                         pipeline: ImagePipeline) async -> ImagePipeline.Decoded? {
        guard isActiveSessionAlive, revision > 0, directory.teams[team] != nil else { return nil }
        let epoch = epoch
        let key = ImagePipeline.Key(scope: scope, resource: .teamIcon(team, revision: revision), maxPixelSize: maxPixelSize)
        let image = await pipeline.image(for: key, using: service)
        guard isActiveSessionAlive, self.epoch == epoch, !Task.isCancelled else { return nil }
        return image
    }

    // MARK: - Publishing

    /// Builds the channel sections for the selected team: the server's categories in
    /// server order, or the synthesized Favorites/Channels/Direct Messages fallback.
    func sidebarSections(collapsedThreads crt: Bool) -> [SidebarSection] {
        var sections: [SidebarSection]
        var rows: [ChannelID: SidebarChannelRow] = [:]
        var visible: [Channel] = []
        let categories = selectedTeam.flatMap { directory.categories[$0] } ?? []
        // The Favorites category is authoritative when categories are loaded; the
        // server keeps it in sync with the `favorite_channel` preferences.
        let favorites = categories.isEmpty ? directory.favorites
            : Set(categories.filter { $0.kind == .favorites }.flatMap(\.channelIDs))
        for channel in directory.channels.values {
            guard channel.type.isDirectOrGroup || channel.teamID == selectedTeam else { continue }
            let row = sidebarRow(for: channel, collapsedThreads: crt, isFavorite: favorites.contains(channel.id))
            if isHiddenDirectChannel(channel, row: row) { continue }
            rows[channel.id] = row
            visible.append(channel)
        }
        if !categories.isEmpty {
            sections = []
            var placed = Set<ChannelID>()
            var channelsIndex: Int?
            var directIndex: Int?
            for category in categories {
                let members = category.channelIDs.compactMap { id -> SidebarChannelRow? in
                    guard placed.insert(id).inserted else { return nil }
                    return rows[id]
                }
                let kind: SidebarSection.Kind
                switch category.kind {
                case .favorites: kind = .favorites
                case .channels: kind = .channels; channelsIndex = channelsIndex ?? sections.count
                case .directMessages: kind = .directMessages; directIndex = directIndex ?? sections.count
                case .custom, .managed, .unknown: kind = .custom
                }
                sections.append(SidebarSection(kind: kind, rows: members, title: category.displayName,
                                               categoryID: category.id, isCollapsed: category.isCollapsed,
                                               isMuted: category.isMuted, sorting: category.effectiveSorting))
            }
            // Channels the server has not placed yet (joined since the last read) go
            // where the server puts orphans: Channels or Direct Messages.
            let orphans = visible.filter { !placed.contains($0.id) }
            for channel in orphans {
                guard let row = rows[channel.id] else { continue }
                let target = channel.type.isDirectOrGroup ? directIndex : channelsIndex
                if let target {
                    let section = sections[target]
                    sections[target] = section.replacingRows(section.rows + [row])
                } else {
                    let kind: SidebarSection.Kind = channel.type.isDirectOrGroup ? .directMessages : .channels
                    let index = sections.count
                    sections.append(SidebarSection(kind: kind, rows: [row], id: "orphan-\(kind)"))
                    if kind == .directMessages { directIndex = index } else { channelsIndex = index }
                }
            }
            sections = sections.map { $0.replacingRows(sorted($0.rows, by: $0.sorting ?? .manual, crt: crt)) }
        } else {
            var favorites: [SidebarChannelRow] = []
            var channels: [SidebarChannelRow] = []
            var directs: [SidebarChannelRow] = []
            for channel in visible {
                guard let row = rows[channel.id] else { continue }
                if row.isFavorite { favorites.append(row) }
                else if channel.type.isDirectOrGroup { directs.append(row) }
                else { channels.append(row) }
            }
            sections = []
            if !favorites.isEmpty {
                sections.append(SidebarSection(kind: .favorites, rows: sorted(favorites, by: .alphabetical, crt: crt)))
            }
            sections.append(SidebarSection(kind: .channels, rows: sorted(channels, by: .alphabetical, crt: crt)))
            sections.append(SidebarSection(kind: .directMessages, rows: sorted(directs, by: .recent, crt: crt),
                                           sorting: .recent))
        }
        sections = sections.map(limitingDirectMessages)
        if directory.groupsUnreads { sections = groupingUnreads(sections) }
        return sections
    }

    private func isHiddenDirectChannel(_ channel: Channel, row: SidebarChannelRow) -> Bool {
        guard channel.type.isDirectOrGroup, !row.isUnread, channel.id != activeChannel else { return false }
        if let partner = channel.directPartner(of: me.id), directory.hiddenDirectPartners.contains(partner) { return true }
        return channel.type == .group && directory.hiddenGroups.contains(channel.id)
    }

    private func sorted(_ rows: [SidebarChannelRow], by sorting: SidebarCategory.Sorting, crt: Bool) -> [SidebarChannelRow] {
        switch sorting {
        case .alphabetical:
            return rows.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .recent:
            return rows.sorted {
                if $0.lastPostAt != $1.lastPostAt { return $0.lastPostAt > $1.lastPostAt }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .default, .manual, .unknown:
            return rows
        }
    }

    /// Direct messages beyond the visible limit are hidden unless unread or active.
    private func limitingDirectMessages(_ section: SidebarSection) -> SidebarSection {
        guard section.kind == .directMessages, section.rows.count > Self.visibleDirectMessages else { return section }
        let keep = Array(section.rows.prefix(Self.visibleDirectMessages))
        let extra = section.rows.dropFirst(Self.visibleDirectMessages)
        let kept = extra.filter { $0.isUnread || $0.mentionCount > 0 || $0.channelID == activeChannel }
        return section.replacingRows(keep + kept, hiddenCount: extra.count - kept.count)
    }

    /// Moves unread channels (and the active channel while it was unread) into an
    /// Unreads group at the top: mentions first, then most recent activity.
    private func groupingUnreads(_ sections: [SidebarSection]) -> [SidebarSection] {
        let sticky = directory.stickyUnread
        let isGrouped: (SidebarChannelRow) -> Bool = { $0.isUnread || $0.mentionCount > 0 || $0.channelID == sticky }
        let unread = sections.flatMap(\.rows).filter(isGrouped).sorted {
            if ($0.mentionCount > 0) != ($1.mentionCount > 0) { return $0.mentionCount > 0 }
            if $0.lastPostAt != $1.lastPostAt { return $0.lastPostAt > $1.lastPostAt }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        guard !unread.isEmpty else { return sections }
        return [SidebarSection(kind: .unreads, rows: unread, sorting: .recent)]
            + sections.map { $0.replacingRows($0.rows.filter { !isGrouped($0) }, hiddenCount: $0.hiddenCount) }
    }

    /// Keeps the active channel in the Unreads group while it stays open.
    func updateStickyUnread(collapsedThreads crt: Bool) {
        guard directory.groupsUnreads, let active = activeChannel else {
            directory.stickyUnread = nil
            return
        }
        if directory.stickyUnread != active {
            directory.stickyUnread = directory.unread(for: active, collapsedThreads: crt).isUnread ? active : nil
        }
    }

    func teamSummaries(collapsedThreads crt: Bool) -> [TeamSummary] {
        directory.sortedTeams.map { team -> TeamSummary in
            var unread = false
            var mentions = 0
            if directory.loadedTeams.contains(team.id) {
                for channel in directory.channels.values where channel.teamID == team.id {
                    let state = directory.unread(for: channel.id, collapsedThreads: crt)
                    unread = unread || state.isUnread
                    mentions += Int(state.mentions)
                }
            } else if let counts = directory.teamUnreads[team.id] {
                let messages = crt ? counts.messageCountRoot : counts.messageCount
                mentions = Int(clamping: crt ? counts.mentionCountRoot : counts.mentionCount)
                unread = messages > 0 || mentions > 0
            }
            return TeamSummary(id: team.id, displayName: team.displayName, name: team.name, hasUnread: unread,
                               mentionCount: mentions, iconRevision: team.iconRevision)
        }
    }

    func directMessageMentions(collapsedThreads crt: Bool) -> Int {
        directory.channels.values.reduce(0) { sum, channel in
            guard channel.type.isDirectOrGroup else { return sum }
            return sum + Int(clamping: directory.unread(for: channel.id, collapsedThreads: crt).mentions)
        }
    }
}

extension SidebarSection {
    func replacingRows(_ rows: [SidebarChannelRow], hiddenCount: Int? = nil) -> SidebarSection {
        SidebarSection(kind: kind, rows: rows, id: id, title: title, categoryID: categoryID, isCollapsed: isCollapsed,
                       isMuted: isMuted, sorting: sorting, hiddenCount: hiddenCount ?? self.hiddenCount)
    }
}
