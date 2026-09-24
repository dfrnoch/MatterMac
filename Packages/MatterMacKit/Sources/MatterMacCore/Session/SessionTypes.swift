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
    public init(user: User, displayName: String, status: PresenceStatus?) {
        self.user = user
        self.displayName = displayName
        self.status = status
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
