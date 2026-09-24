import Foundation
import MatterMacModels

extension ServerSession {
    /// Visible DMs/GMs in the sidebar (server default `limit_visible_dms_gms` is 40);
    /// unread ones are always shown.
    static let visibleDirectMessages = 40

    func publishSidebar() {
        sidebarGeneration &+= 1
        let crt = collapsedThreadsActive
        let teams = directory.sortedTeams.map { team -> TeamSummary in
            var unread = false
            var mentions = 0
            if directory.loadedTeams.contains(team.id) {
                for channel in directory.channels.values where channel.teamID == team.id {
                    let state = directory.unread(for: channel.id, collapsedThreads: crt)
                    unread = unread || state.isUnread
                    mentions += Int(state.mentions)
                }
            }
            return TeamSummary(id: team.id, displayName: team.displayName, name: team.name, hasUnread: unread,
                               mentionCount: mentions)
        }
        var favorites: [SidebarChannelRow] = []
        var channels: [SidebarChannelRow] = []
        var directs: [SidebarChannelRow] = []
        for channel in directory.channels.values {
            let isDirect = channel.type.isDirectOrGroup
            guard isDirect || channel.teamID == selectedTeam else { continue }
            let row = sidebarRow(for: channel, collapsedThreads: crt)
            if directory.favorites.contains(channel.id) {
                favorites.append(row)
            } else if isDirect {
                if let partner = channel.directPartner(of: me.id), directory.hiddenDirectPartners.contains(partner),
                   !row.isUnread, channel.id != activeChannel { continue }
                if channel.type == .group, directory.hiddenGroups.contains(channel.id), !row.isUnread,
                   channel.id != activeChannel { continue }
                directs.append(row)
            } else {
                channels.append(row)
            }
        }
        let byName: (SidebarChannelRow, SidebarChannelRow) -> Bool = {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        favorites.sort(by: byName)
        channels.sort(by: byName)
        directs.sort { $0.lastPostAt > $1.lastPostAt }
        if directs.count > Self.visibleDirectMessages {
            let keep = directs.prefix(Self.visibleDirectMessages)
            let extraUnread = directs.dropFirst(Self.visibleDirectMessages).filter { $0.isUnread || $0.channelID == activeChannel }
            directs = Array(keep) + extraUnread
        }
        var sections: [SidebarSection] = []
        if !favorites.isEmpty { sections.append(SidebarSection(kind: .favorites, rows: favorites)) }
        sections.append(SidebarSection(kind: .channels, rows: channels))
        sections.append(SidebarSection(kind: .directMessages, rows: directs))
        sidebarContinuation.yield(SidebarSnapshot(scope: scope, generation: sidebarGeneration, teams: teams,
                                                  selectedTeam: selectedTeam, sections: sections,
                                                  isTruncated: directory.channelsTruncated))
    }

    func sidebarRow(for channel: Channel, collapsedThreads: Bool) -> SidebarChannelRow {
        let unread = directory.unread(for: channel.id, collapsedThreads: collapsedThreads)
        let partner = channel.directPartner(of: me.id)
        return SidebarChannelRow(
            channelID: channel.id, displayName: displayName(of: channel), type: channel.type,
            isUnread: unread.isUnread && channel.id != activeChannel || (unread.mentions > 0),
            mentionCount: Int(unread.mentions), isArchived: channel.isArchived,
            isMuted: directory.memberships[channel.id]?.markUnread == .mention,
            partnerStatus: partner.flatMap { directory.status(of: $0) },
            lastPostAt: channel.lastPostAt)
    }

    /// Human-readable channel name. DMs use the partner's display name; GMs drop the
    /// current user from the server-provided member list.
    func displayName(of channel: Channel) -> String {
        switch channel.type {
        case .direct:
            if let partner = channel.directPartner(of: me.id) {
                if let user = directory.peekUser(partner) { return directory.nameFormat.displayName(for: user) }
                return String(localized: "Direct message")
            }
            // Self-DM ("<me>__<me>").
            return directory.nameFormat.displayName(for: me) + " " + String(localized: "(you)")
        case .group:
            let names = channel.displayName.components(separatedBy: ", ").filter { $0 != me.username }
            return names.isEmpty ? channel.displayName : names.joined(separator: ", ")
        default:
            return channel.displayName.isEmpty ? channel.name : channel.displayName
        }
    }

    func publishTimeline(_ target: TimelineTarget) {
        guard let window = windows[target] else {
            if case .thread = target { threadContinuation.yield(nil) }
            return
        }
        let generation = (generations[target] ?? 0) &+ 1
        generations[target] = generation
        let channel = directory.channels[target.channelID]
        let isAdmin = me.isSystemAdmin || directory.memberships[target.channelID]?.isChannelAdmin == true
        let context = TimelineBuildContext(
            scope: scope, me: me.id, channel: channel, teamName: teamName(for: channel), endpoint: endpoint,
            collapsedThreads: collapsedThreadsActive, editTimeLimitSeconds: capabilities.postEditTimeLimitSeconds,
            canDeleteOthers: isAdmin, now: now(), collapsedMessageCharacters: budget.collapsedMessageCharacters,
            timeZone: deps.timeZone(), lastViewedAtOnOpen: lastViewedOnOpen[target.channelID])
        let output = TimelineBuilder.build(window: window, store: store, directory: directory,
                                           pending: pending.items(for: target), context: context)
        missingUsers.formUnion(output.missingUsers)
        var items = output.items
        if !window.isLoaded, case .loading = window.initialLoad {
            items = [TimelineItem(id: TimelineItemID(.olderGap), revision: 2,
                                  content: .gap(GapPresentation(direction: .older, state: .loading)))]
        } else if !window.isLoaded, case .failed(let error) = window.initialLoad {
            items = [TimelineItem(id: TimelineItemID(.olderGap), revision: 3,
                                  content: .gap(GapPresentation(direction: .older, state: .failed(error))))]
        }
        let scroll = pendingScroll.removeValue(forKey: target)
        let snapshot = TimelineSnapshot(scope: scope, target: target, generation: generation, items: items,
                                        isAtLiveEdge: !window.hasNewer,
                                        isStale: window.isStale || connection != .connected,
                                        scrollRequest: scroll)
        switch target {
        case .channel: timelineContinuation.yield(snapshot)
        case .thread: threadContinuation.yield(snapshot)
        }
    }

    func publishHeader() {
        guard let id = activeChannel, let channel = directory.channels[id] else {
            headerContinuation.yield(nil)
            return
        }
        let partner = channel.directPartner(of: me.id)
        let deadline = ContinuousClock.now
        let typingNames = (typing[id] ?? [:]).filter { $0.value > deadline }.keys.prefix(4).compactMap { user in
            directory.peekUser(user).map { directory.nameFormat.displayName(for: $0) }
        }.sorted()
        headerContinuation.yield(ChannelHeaderPresentation(
            channelID: id, displayName: displayName(of: channel), type: channel.type, header: channel.header,
            purpose: channel.purpose, memberCount: memberCounts[id], isArchived: channel.isArchived,
            partnerStatus: partner.flatMap { directory.status(of: $0) }, typingNames: typingNames,
            canPost: channel.isArchived ? false : nil, fileAttachmentsEnabled: capabilities.fileAttachmentsEnabled))
    }

    func loadMemberCount(_ id: ChannelID) {
        guard memberCounts[id] == nil else { return }
        guard let type = directory.channels[id]?.type, type == .open || type == .private || type == .group else { return }
        run(.channelFetch(id)) { session in
            let epoch = session.epoch
            guard let stats = try? await session.service.channelStats(id), session.epoch == epoch else { return }
            if session.memberCounts.count > 256 { session.memberCounts.removeAll() }
            session.memberCounts[id] = stats.memberCount
            session.markDirty(.header)
        }
    }
}
