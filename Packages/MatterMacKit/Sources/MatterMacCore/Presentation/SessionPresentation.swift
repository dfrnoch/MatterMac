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
    public var id: ChannelID { channelID }

    public init(channelID: ChannelID, displayName: String, type: ChannelType, isUnread: Bool, mentionCount: Int,
                isArchived: Bool, isMuted: Bool, partnerStatus: PresenceStatus?, lastPostAt: MattermostTimestamp,
                partnerID: UserID? = nil, partnerAvatarRevision: Int64 = 0, partnerUsername: String? = nil) {
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

public struct SidebarSection: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case favorites, channels, directMessages }
    public let kind: Kind
    public let rows: [SidebarChannelRow]
    public var id: Kind { kind }

    public init(kind: Kind, rows: [SidebarChannelRow]) {
        self.kind = kind
        self.rows = rows
    }
}

public struct TeamSummary: Hashable, Sendable, Identifiable {
    public let id: TeamID
    public let displayName: String
    public let name: String
    public let hasUnread: Bool
    public let mentionCount: Int

    public init(id: TeamID, displayName: String, name: String, hasUnread: Bool, mentionCount: Int) {
        self.id = id
        self.displayName = displayName
        self.name = name
        self.hasUnread = hasUnread
        self.mentionCount = mentionCount
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

    public init(scope: AccountScope, generation: UInt64, teams: [TeamSummary], selectedTeam: TeamID?,
                sections: [SidebarSection], isTruncated: Bool, myStatus: PresenceStatus? = nil,
                myCustomStatus: CustomStatus? = nil) {
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
