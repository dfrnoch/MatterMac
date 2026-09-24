public import Foundation
public import MatterMacModels
import MattermostAPI
public import MattermostRealtime

/// Injected collaborators for a server session. No globals, no service locator.
public struct SessionDependencies: Sendable {
    public var budget: ResourceBudget
    public var retention: RetentionLedger
    public var unsent: UnsentWorkLedger
    public var diagnostics: DiagnosticRing
    public var wallClock: any WallClock
    public var clock: any Clock<Duration>
    public var documents: PostDocumentBuilder
    public var makeRealtime: @Sendable (ServerEndpoint, BearerCredential, UserID) -> any RealtimeConnection
    public var timeZone: @Sendable () -> TimeZone

    public init(budget: ResourceBudget, retention: RetentionLedger, unsent: UnsentWorkLedger, diagnostics: DiagnosticRing,
                wallClock: any WallClock = SystemWallClock(), clock: any Clock<Duration> = ContinuousClock(),
                documents: PostDocumentBuilder,
                makeRealtime: @escaping @Sendable (ServerEndpoint, BearerCredential, UserID) -> any RealtimeConnection,
                timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }) {
        self.budget = budget
        self.retention = retention
        self.unsent = unsent
        self.diagnostics = diagnostics
        self.wallClock = wallClock
        self.clock = clock
        self.documents = documents
        self.makeRealtime = makeRealtime
        self.timeZone = timeZone
    }
}

/// Transient, user-visible session events that are not part of any snapshot.
public enum SessionNotice: Sendable, Hashable {
    /// Content was purged; unsent work remains charged in the pending queue.
    case accessRevoked(channel: ChannelID)
    case teamRemoved(teamName: String)
    /// The server session ended (401); the user must sign in again.
    case signedOutByServer
    /// The server identity changed underneath us (different user id): session ended.
    case identityChanged
    case operationFailed(UserFacingError)
}

public struct SearchResultItem: Hashable, Sendable, Identifiable {
    public let postID: PostID
    public let channelID: ChannelID
    public let channelName: String
    public let author: String
    public let createdAt: MattermostTimestamp
    public let preview: String
    public let rootID: PostID?
    public var id: PostID { postID }

    public init(postID: PostID, channelID: ChannelID, channelName: String, author: String, createdAt: MattermostTimestamp,
                preview: String, rootID: PostID?) {
        self.postID = postID
        self.channelID = channelID
        self.channelName = channelName
        self.author = author
        self.createdAt = createdAt
        self.preview = preview
        self.rootID = rootID
    }
}

public struct SearchSnapshot: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case idle
        case searching
        case results
        case failed(UserFacingError)
    }
    public let scope: AccountScope
    public let generation: UInt64
    public let terms: String
    public let state: State
    public let items: [SearchResultItem]
    public let isTruncated: Bool
    public let canLoadMore: Bool

    public init(scope: AccountScope, generation: UInt64, terms: String, state: State, items: [SearchResultItem],
                isTruncated: Bool, canLoadMore: Bool) {
        self.scope = scope
        self.generation = generation
        self.terms = terms
        self.state = state
        self.items = items
        self.isTruncated = isTruncated
        self.canLoadMore = canLoadMore
    }
}

public struct QuickSwitchItem: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case channel(ChannelID)
        case user(UserID)
    }
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let channelType: ChannelType?
    public let isUnread: Bool
    public var id: Kind { kind }

    public init(kind: Kind, title: String, subtitle: String, channelType: ChannelType?, isUnread: Bool) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.channelType = channelType
        self.isUnread = isUnread
    }
}

public struct CompletionCandidate: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case user, channel, special }
    public let kind: Kind
    public let id: String
    public let title: String
    public let subtitle: String
    public let insertion: String

    public init(kind: Kind, id: String, title: String, subtitle: String, insertion: String) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.insertion = insertion
    }
}

public struct UserProfilePresentation: Hashable, Sendable {
    public let user: User
    public let displayName: String
    public let status: PresenceStatus?
    public let isCurrentUser: Bool
    public init(user: User, displayName: String, status: PresenceStatus?, isCurrentUser: Bool = false) {
        self.user = user
        self.displayName = displayName
        self.status = status
        self.isCurrentUser = isCurrentUser
    }
}

/// Channel information for the details panel. Fetched on demand, never retained by Core.
public struct ChannelDetailsPresentation: Hashable, Sendable {
    public let channelID: ChannelID
    public let name: String
    public let displayName: String
    public let type: ChannelType
    public let header: String
    public let purpose: String
    public let memberCount: Int?
    public let pinnedPostCount: Int?
    public let isArchived: Bool
    public let isFavorite: Bool
    public let isMuted: Bool
    /// The server refuses leaving the default channel and DMs cannot be left.
    public let canLeave: Bool
    public let directPartner: UserID?
    public let link: URL?

    public init(channelID: ChannelID, name: String, displayName: String, type: ChannelType, header: String,
                purpose: String, memberCount: Int?, pinnedPostCount: Int?, isArchived: Bool, isFavorite: Bool,
                isMuted: Bool, canLeave: Bool, directPartner: UserID?, link: URL?) {
        self.channelID = channelID
        self.name = name
        self.displayName = displayName
        self.type = type
        self.header = header
        self.purpose = purpose
        self.memberCount = memberCount
        self.pinnedPostCount = pinnedPostCount
        self.isArchived = isArchived
        self.isFavorite = isFavorite
        self.isMuted = isMuted
        self.canLeave = canLeave
        self.directPartner = directPartner
        self.link = link
    }
}

public struct ChannelMemberRow: Hashable, Sendable, Identifiable {
    public var id: UserID { userID }
    public let userID: UserID
    public let displayName: String
    public let username: String
    public let status: PresenceStatus?
    public let isBot: Bool
    public let isGuest: Bool
    public let avatarRevision: Int64

    public init(userID: UserID, displayName: String, username: String, status: PresenceStatus?, isBot: Bool,
                isGuest: Bool, avatarRevision: Int64) {
        self.userID = userID
        self.displayName = displayName
        self.username = username
        self.status = status
        self.isBot = isBot
        self.isGuest = isGuest
        self.avatarRevision = avatarRevision
    }
}

public struct ChannelMembersPage: Sendable {
    public let members: [ChannelMemberRow]
    public let hasMore: Bool
    public init(members: [ChannelMemberRow], hasMore: Bool) {
        self.members = members
        self.hasMore = hasMore
    }
}

/// Result of signing out, reported honestly to the user (SPEC §7 logout).
public enum SignOutOutcome: Sendable, Hashable {
    /// The server confirmed the session was revoked.
    case serverSessionRevoked
    /// Local data was cleared but the server could not be reached to revoke the
    /// session; it expires according to server policy.
    case serverLogoutUnconfirmed
    /// A personal access token was discarded locally; it remains valid on the server
    /// until the user revokes it there.
    case personalAccessTokenDiscardedLocally
}

struct DirtyFlags: OptionSet {
    let rawValue: UInt8
    static let sidebar = DirtyFlags(rawValue: 1 << 0)
    static let timeline = DirtyFlags(rawValue: 1 << 1)
    static let thread = DirtyFlags(rawValue: 1 << 2)
    static let header = DirtyFlags(rawValue: 1 << 3)
    static let search = DirtyFlags(rawValue: 1 << 4)
    static let all: DirtyFlags = [.sidebar, .timeline, .thread, .header, .search]
}

/// A mention or direct message from someone else, for in-app badges and opt-in
/// notifications. Carries no message text (SPEC §19 "avoid rich content").
public struct IncomingMessageAlert: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case mention
        case directMessage
    }
    public let scope: AccountScope
    public let channelID: ChannelID
    public let rootID: PostID?
    public let kind: Kind
    public let channelName: String
    public let senderName: String

    public init(scope: AccountScope, channelID: ChannelID, rootID: PostID?, kind: Kind, channelName: String,
                senderName: String) {
        self.scope = scope
        self.channelID = channelID
        self.rootID = rootID
        self.kind = kind
        self.channelName = channelName
        self.senderName = senderName
    }
}

/// Followed-thread totals for the Threads toolbar badge.
public struct ThreadActivity: Hashable, Sendable {
    public let scope: AccountScope
    /// Bumps whenever the server reports thread changes; views refetch when visible.
    public let revision: UInt64
    /// `false` when collapsed reply threads are off for this account/server.
    public let isAvailable: Bool
    public let unreadThreads: Int
    public let unreadMentions: Int

    public init(scope: AccountScope, revision: UInt64, isAvailable: Bool, unreadThreads: Int, unreadMentions: Int) {
        self.scope = scope
        self.revision = revision
        self.isAvailable = isAvailable
        self.unreadThreads = unreadThreads
        self.unreadMentions = unreadMentions
    }
}

/// One followed thread in the Threads view. Holds a short plain-text preview only.
public struct ThreadSummary: Hashable, Sendable, Identifiable {
    public var id: PostID { rootID }
    public let rootID: PostID
    public let channelID: ChannelID
    public let channelName: String
    public let authorID: UserID
    public let authorName: String
    public let authorAvatarRevision: Int64
    public let preview: String
    public let replyCount: Int
    public let lastReplyAt: MattermostTimestamp
    public let unreadReplies: Int
    public let unreadMentions: Int
    /// Up to five recent participants (display name, id, picture revision).
    public let participants: [Participant]

    public struct Participant: Hashable, Sendable {
        public let id: UserID
        public let name: String
        public let avatarRevision: Int64
    }

    public init(rootID: PostID, channelID: ChannelID, channelName: String, authorID: UserID, authorName: String,
                authorAvatarRevision: Int64, preview: String, replyCount: Int, lastReplyAt: MattermostTimestamp,
                unreadReplies: Int, unreadMentions: Int, participants: [Participant]) {
        self.rootID = rootID
        self.channelID = channelID
        self.channelName = channelName
        self.authorID = authorID
        self.authorName = authorName
        self.authorAvatarRevision = authorAvatarRevision
        self.preview = preview
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.unreadReplies = unreadReplies
        self.unreadMentions = unreadMentions
        self.participants = participants
    }
}

public struct ThreadsPage: Sendable {
    public let threads: [ThreadSummary]
    public let hasMore: Bool
    public let unreadThreads: Int
    public let unreadMentions: Int

    public init(threads: [ThreadSummary], hasMore: Bool, unreadThreads: Int, unreadMentions: Int) {
        self.threads = threads
        self.hasMore = hasMore
        self.unreadThreads = unreadThreads
        self.unreadMentions = unreadMentions
    }
}
