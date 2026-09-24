public import MatterMacModels

/// Connection lifecycle shown to the user (SPEC §10 explicit states).
public enum ConnectionStatus: Hashable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case synchronizing
    case connected
    /// Waiting before the next reconnect attempt.
    case backingOff(retryInSeconds: Int)
    /// Token rejected or revoked; the user must sign in again.
    case authenticationRequired
    /// No usable network path. Content in memory is readable and labeled stale.
    case offline

    public var isLive: Bool { self == .connected }
}

public struct SidebarChannelRow: Hashable, Sendable, Identifiable {
    public let channelID: ChannelID
    public let displayName: String
    public let type: ChannelType
    public let isUnread: Bool
    public let mentionCount: Int
    public let isArchived: Bool
    public let isMuted: Bool
    /// Presence of the DM partner, for direct channels.
    public let partnerStatus: PresenceStatus?
    public let lastPostAt: MattermostTimestamp
    /// The DM partner and their picture revision (`last_picture_update`), for avatars.
    public let partnerID: UserID?
    public let partnerAvatarRevision: Int64
    /// `@username` of the DM partner when the display name is something else.
    public let partnerUsername: String?
    /// In the Favorites category (or `favorite_channel` preference when categories
    /// are unavailable).
    public let isFavorite: Bool
    public var id: ChannelID { channelID }

    public init(channelID: ChannelID, displayName: String, type: ChannelType, isUnread: Bool, mentionCount: Int,
                isArchived: Bool, isMuted: Bool, partnerStatus: PresenceStatus?, lastPostAt: MattermostTimestamp,
                partnerID: UserID? = nil, partnerAvatarRevision: Int64 = 0, partnerUsername: String? = nil,
                isFavorite: Bool = false) {
        self.isFavorite = isFavorite
        self.partnerID = partnerID
        self.partnerAvatarRevision = partnerAvatarRevision
        self.partnerUsername = partnerUsername
        self.channelID = channelID
        self.displayName = displayName
        self.type = type
        self.isUnread = isUnread
        self.mentionCount = mentionCount
        self.isArchived = isArchived
        self.isMuted = isMuted
        self.partnerStatus = partnerStatus
        self.lastPostAt = lastPostAt
    }
}

/// One sidebar group: a server category, a synthesized fallback section, or the
/// local Unreads group. `rows` always lists every channel of the section, including
/// rows hidden by collapsing; `visibleRows(selected:)` applies the display rules.
public struct SidebarSection: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case unreads, favorites, channels, directMessages, custom }
    public let id: String
    public let kind: Kind
    /// The server's display name for custom categories; default categories and
    /// synthesized sections are titled by kind in the user's language.
    public let title: String
    public let rows: [SidebarChannelRow]
    /// `nil` for synthesized sections and the Unreads group (not collapsible).
    public let categoryID: SidebarCategoryID?
    public let isCollapsed: Bool
    public let isMuted: Bool
    public let sorting: SidebarCategory.Sorting?
    /// Channels left out because of the visible-DM limit (reachable via "More…").
    public let hiddenCount: Int

    public init(kind: Kind, rows: [SidebarChannelRow], id: String? = nil, title: String = "",
                categoryID: SidebarCategoryID? = nil, isCollapsed: Bool = false, isMuted: Bool = false,
                sorting: SidebarCategory.Sorting? = nil, hiddenCount: Int = 0) {
        self.id = id ?? categoryID?.rawValue ?? "\(kind)"
        self.kind = kind
        self.title = title
        self.rows = rows
        self.categoryID = categoryID
        self.isCollapsed = isCollapsed
        self.isMuted = isMuted
        self.sorting = sorting
        self.hiddenCount = hiddenCount
    }

    /// Rows shown for this section. Archived channels appear only while selected; a
    /// collapsed category still shows unread channels and the selected one, as the
    /// official client does.
    public func visibleRows(selected: ChannelID?) -> [SidebarChannelRow] {
        rows.filter { row in
            if row.channelID == selected { return true }
            if row.isArchived { return false }
            return !isCollapsed || row.isUnread || row.mentionCount > 0
        }
    }
}

extension SidebarSnapshot {
    /// Rows in on-screen order (keyboard navigation).
    public func visibleRows(selected: ChannelID?) -> [SidebarChannelRow] {
        sections.flatMap { $0.visibleRows(selected: selected) }
    }

    /// The channel `offset` rows away from `selected` in on-screen order, wrapping
    /// around; with `unreadOnly`, the nearest unread channel in that direction.
    public func adjacentChannel(to selected: ChannelID?, offset: Int, unreadOnly: Bool) -> ChannelID? {
        var seen = Set<ChannelID>()
        let rows = visibleRows(selected: selected).filter { seen.insert($0.channelID).inserted }
        guard !rows.isEmpty, offset != 0 else { return nil }
        let step = offset > 0 ? 1 : -1
        let start = rows.firstIndex { $0.channelID == selected } ?? (step > 0 ? -1 : rows.count)
        var index = start
        for _ in 0..<rows.count {
            index = ((index + step) % rows.count + rows.count) % rows.count
            let row = rows[index]
            if row.channelID == selected { return nil }
            if !unreadOnly || row.isUnread || row.mentionCount > 0 { return row.channelID }
        }
        return nil
    }
}

public struct TeamSummary: Hashable, Sendable, Identifiable {
    public let id: TeamID
    public let displayName: String
    public let name: String
    public let hasUnread: Bool
    public let mentionCount: Int
    /// `last_team_icon_update`; 0 means no custom icon (initials are shown).
    public let iconRevision: Int64

    public init(id: TeamID, displayName: String, name: String, hasUnread: Bool, mentionCount: Int,
                iconRevision: Int64 = 0) {
        self.id = id
        self.displayName = displayName
        self.name = name
        self.hasUnread = hasUnread
        self.mentionCount = mentionCount
        self.iconRevision = iconRevision
    }
}

public struct SidebarSnapshot: Sendable {
    public let scope: AccountScope
    public let generation: UInt64
    public let teams: [TeamSummary]
    public let selectedTeam: TeamID?
    public let sections: [SidebarSection]
    /// `true` when more channels exist than the sidebar retains; reachable via search
    /// and the quick switcher.
    public let isTruncated: Bool
    /// The signed-in user's presence and custom status, when known.
    public let myStatus: PresenceStatus?
    public let myCustomStatus: CustomStatus?
    /// Sections follow the server's sidebar categories (else a synthesized fallback).
    public let usesServerCategories: Bool
    /// The local "Group unread channels separately" choice.
    public let groupsUnreads: Bool
    /// Mentions in direct and group messages, wherever they are shown.
    public let directMessageMentions: Int
    /// Whether the server lets users browse archived channels.
    public let canBrowseArchivedChannels: Bool

    public init(scope: AccountScope, generation: UInt64, teams: [TeamSummary], selectedTeam: TeamID?,
                sections: [SidebarSection], isTruncated: Bool, myStatus: PresenceStatus? = nil,
                myCustomStatus: CustomStatus? = nil, usesServerCategories: Bool = false, groupsUnreads: Bool = false,
                directMessageMentions: Int = 0, canBrowseArchivedChannels: Bool = false) {
        self.usesServerCategories = usesServerCategories
        self.groupsUnreads = groupsUnreads
        self.directMessageMentions = directMessageMentions
        self.canBrowseArchivedChannels = canBrowseArchivedChannels
        self.scope = scope
        self.generation = generation
        self.teams = teams
        self.selectedTeam = selectedTeam
        self.sections = sections
        self.isTruncated = isTruncated
        self.myStatus = myStatus
        self.myCustomStatus = myCustomStatus
    }
}

/// Header information for the active conversation.
public struct ChannelHeaderPresentation: Hashable, Sendable {
    public let channelID: ChannelID
    public let displayName: String
    public let type: ChannelType
    public let header: String
    public let purpose: String
    public let memberCount: Int?
    public let isArchived: Bool
    public let partnerStatus: PresenceStatus?
    /// Users currently typing (display names), coalesced and time-limited.
    public let typingNames: [String]
    public let canPost: Bool?
    public let fileAttachmentsEnabled: Bool?

    public init(channelID: ChannelID, displayName: String, type: ChannelType, header: String, purpose: String,
                memberCount: Int?, isArchived: Bool, partnerStatus: PresenceStatus?, typingNames: [String],
                canPost: Bool?, fileAttachmentsEnabled: Bool? = nil) {
        self.channelID = channelID
        self.displayName = displayName
        self.type = type
        self.header = header
        self.purpose = purpose
        self.memberCount = memberCount
        self.isArchived = isArchived
        self.partnerStatus = partnerStatus
        self.typingNames = typingNames
        self.canPost = canPost
        self.fileAttachmentsEnabled = fileAttachmentsEnabled
    }
}

/// Key for a session-only draft: server slot, account, channel, and optional thread.
public struct DraftKey: Hashable, Sendable {
    public let scope: AccountScope
    public let channelID: ChannelID
    public let rootID: PostID?

    public init(scope: AccountScope, channelID: ChannelID, rootID: PostID?) {
        self.scope = scope
        self.channelID = channelID
        self.rootID = rootID
    }
}
