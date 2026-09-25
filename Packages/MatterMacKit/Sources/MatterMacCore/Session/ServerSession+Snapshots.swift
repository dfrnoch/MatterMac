import Foundation
import MatterMacModels

extension ServerSession {
    /// Visible DMs/GMs in the sidebar (server default `limit_visible_dms_gms` is 40);
    /// unread ones are always shown.
    static let visibleDirectMessages = 40

    func publishSidebar() {
        sidebarGeneration &+= 1
        let crt = collapsedThreadsActive
        loadCategoriesIfNeeded()
        updateStickyUnread(collapsedThreads: crt)
        let usesCategories = selectedTeam.map { directory.categories[$0]?.isEmpty == false } ?? false
        sidebarContinuation.yield(SidebarSnapshot(scope: scope, generation: sidebarGeneration,
                                                  teams: teamSummaries(collapsedThreads: crt),
                                                  selectedTeam: selectedTeam,
                                                  sections: sidebarSections(collapsedThreads: crt),
                                                  isTruncated: directory.channelsTruncated,
                                                  myStatus: directory.status(of: me.id),
                                                  myCustomStatus: directory.peekUser(me.id)?.customStatus,
                                                  usesServerCategories: usesCategories,
                                                  groupsUnreads: directory.groupsUnreads,
                                                  directMessageMentions: directMessageMentions(collapsedThreads: crt),
                                                  canBrowseArchivedChannels: directory.viewArchivedChannels))
    }

    func sidebarRow(for channel: Channel, collapsedThreads: Bool, isFavorite: Bool = false) -> SidebarChannelRow {
        let unread = directory.unread(for: channel.id, collapsedThreads: collapsedThreads)
        let partner = channel.directPartner(of: me.id)
        return SidebarChannelRow(
            channelID: channel.id, displayName: displayName(of: channel), type: channel.type,
            isUnread: unread.isUnread && (channel.id != activeChannel || manualUnreadHold == channel.id)
                || (unread.mentions > 0),
            mentionCount: Int(unread.mentions), isArchived: channel.isArchived,
            isMuted: directory.memberships[channel.id]?.markUnread == .mention,
            partnerStatus: partner.flatMap { directory.status(of: $0) },
            lastPostAt: channel.lastPostAt,
            partnerID: channel.type == .direct ? partner : nil,
            partnerAvatarRevision: partner.flatMap { directory.peekUser($0)?.lastPictureUpdate.milliseconds } ?? 0,
            partnerUsername: partner.flatMap { directory.peekUser($0)?.username },
            isFavorite: isFavorite)
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
        var context = TimelineBuildContext(
            scope: scope, me: me.id, channel: channel, teamName: teamName(for: channel), endpoint: endpoint,
            collapsedThreads: collapsedThreadsActive, editTimeLimitSeconds: capabilities.postEditTimeLimitSeconds,
            canDeleteOthers: isAdmin, now: now(), collapsedMessageCharacters: budget.collapsedMessageCharacters,
            timeZone: deps.timeZone(), lastViewedAtOnOpen: lastViewedOnOpen[target.channelID],
            linkPreviewImages: capabilities.hasImageProxy == true)
        context.customEmojiEnabled = customEmojiEnabled
        let output = TimelineBuilder.build(window: window, store: store, directory: directory,
                                           pending: pending.items(for: target), context: context,
                                           customEmoji: customEmoji)
        missingUsers.formUnion(output.missingUsers)
        wantCustomEmoji(output.missingEmojiNames)
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
