public import Foundation
public import MatterMacModels

// The Core → UI timeline contract. Core publishes bounded, immutable snapshots of the
// visible window (at most `ResourceBudget.activeTimeline.count` post rows plus a few
// markers). The UI diffs consecutive snapshots by (id, revision) and applies minimal
// NSTableView row changes. Items share storage copy-on-write, so publishing a
// snapshot does not copy message text.

public enum TimelineTarget: Hashable, Sendable {
    case channel(ChannelID)
    case thread(root: PostID, channel: ChannelID)

    public var channelID: ChannelID {
        switch self {
        case .channel(let id): id
        case .thread(_, let channel): channel
        }
    }
}

public struct TimelineItemID: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case post(PostID)
        case pending(PendingPostID)
        /// Days since 1970 in the user's calendar, for the separator before that day.
        case dateSeparator(Int)
        case unreadBoundary
        case olderGap
        case newerGap
        case historyStart
    }

    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    public var description: String {
        switch kind {
        case .post(let id): "post:\(id)"
        case .pending(let id): "pending:\(id)"
        case .dateSeparator(let day): "day:\(day)"
        case .unreadBoundary: "unread"
        case .olderGap: "older"
        case .newerGap: "newer"
        case .historyStart: "start"
        }
    }
}

public struct TimelineItem: Hashable, Sendable, Identifiable {
    public let id: TimelineItemID
    /// Changes whenever anything that affects this row's rendering or height changes.
    public let revision: UInt64
    public let content: Content

    public enum Content: Hashable, Sendable {
        case post(PostPresentation)
        case dateSeparator(Date)
        case unreadBoundary(count: Int)
        case gap(GapPresentation)
        case historyStart(channelName: String)
    }

    public init(id: TimelineItemID, revision: UInt64, content: Content) {
        self.id = id
        self.revision = revision
        self.content = content
    }

    public var post: PostPresentation? {
        if case .post(let post) = content { return post }
        return nil
    }
}

public struct GapPresentation: Hashable, Sendable {
    public enum Direction: Hashable, Sendable { case older, newer }
    public enum State: Hashable, Sendable {
        case idle
        case loading
        /// Loading failed; the UI shows the explanation with a retry action.
        case failed(UserFacingError)
    }
    public let direction: Direction
    public let state: State

    public init(direction: Direction, state: State) {
        self.direction = direction
        self.state = state
    }
}

public struct AuthorPresentation: Hashable, Sendable {
    public let userID: UserID
    public let displayName: String
    public let username: String
    public let isBot: Bool
    public let isCurrentUser: Bool
    /// Changes when the profile image changes (server `last_picture_update`).
    public let avatarRevision: Int64

    public init(userID: UserID, displayName: String, username: String, isBot: Bool, isCurrentUser: Bool,
                avatarRevision: Int64) {
        self.userID = userID
        self.displayName = displayName
        self.username = username
        self.isBot = isBot
        self.isCurrentUser = isCurrentUser
        self.avatarRevision = avatarRevision
    }
}

public enum MessageBody: Hashable, Sendable {
    /// Parsed user content. `isCollapsed` marks a giant message shown as a preview
    /// with an explicit expand action.
    case document(MessageDocument, isCollapsed: Bool)
    /// A system post rendered as a single readable sentence.
    case system(String)
    /// A post deleted on the server (placeholder; content is not retained).
    case deleted
    /// A plugin or unsupported post type; `summary` is safe readable text.
    case unsupported(summary: String, fallbackText: String)
}

public struct ReactionGroup: Hashable, Sendable, Identifiable {
    public let emojiName: String
    public let count: Int
    public let includesCurrentUser: Bool
    public var id: String { emojiName }

    public init(emojiName: String, count: Int, includesCurrentUser: Bool) {
        self.emojiName = emojiName
        self.count = count
        self.includesCurrentUser = includesCurrentUser
    }
}

/// Explicit pending-send lifecycle (SPEC §11). Never shown as "sent" until the server
/// confirmed a canonical post.
public enum SendState: Hashable, Sendable {
    case queued
    case uploading(completedFiles: Int, totalFiles: Int)
    case sending
    case failed(UserFacingError)
    /// The request may or may not have reached the server (timeout or lost response).
    /// The user decides whether to retry, which may create a duplicate.
    case outcomeUnknown
}

/// Client-side hints for which actions to offer. The server remains the authority;
/// a permitted-looking action can still be refused and is then shown as failed.
public struct PostActionHints: Hashable, Sendable {
    public var canReply: Bool
    public var canReact: Bool
    public var canEdit: Bool
    public var canDelete: Bool
    public var canCopyLink: Bool

    public init(canReply: Bool = false, canReact: Bool = false, canEdit: Bool = false, canDelete: Bool = false,
                canCopyLink: Bool = false) {
        self.canReply = canReply
        self.canReact = canReact
        self.canEdit = canEdit
        self.canDelete = canDelete
        self.canCopyLink = canCopyLink
    }

    public static let none = PostActionHints()
}

public struct PostPresentation: Hashable, Sendable {
    /// Confirmed server post ID; `nil` while a send is pending.
    public let postID: PostID?
    public let pendingID: PendingPostID?
    public let channelID: ChannelID
    public let rootID: PostID?
    public let author: AuthorPresentation
    public let createdAt: MattermostTimestamp
    /// Same author, within the grouping interval, no separator in between.
    public let isContinuation: Bool
    public let body: MessageBody
    public let isEdited: Bool
    public let isPinned: Bool
    public let files: [FileInfo]
    public let reactions: [ReactionGroup]
    public let replyCount: Int
    /// In a channel timeline, a reply shows a small "replied to a thread" context.
    public let showsThreadContext: Bool
    public let sendState: SendState?
    public let actions: PostActionHints
    /// Server permalink, when the team context is known.
    public let permalink: URL?

    public init(postID: PostID?, pendingID: PendingPostID?, channelID: ChannelID, rootID: PostID?,
                author: AuthorPresentation, createdAt: MattermostTimestamp, isContinuation: Bool,
                body: MessageBody, isEdited: Bool, isPinned: Bool, files: [FileInfo], reactions: [ReactionGroup],
                replyCount: Int, showsThreadContext: Bool, sendState: SendState?, actions: PostActionHints,
                permalink: URL?) {
        self.postID = postID
        self.pendingID = pendingID
        self.channelID = channelID
        self.rootID = rootID
        self.author = author
        self.createdAt = createdAt
        self.isContinuation = isContinuation
        self.body = body
        self.isEdited = isEdited
        self.isPinned = isPinned
        self.files = files
        self.reactions = reactions
        self.replyCount = replyCount
        self.showsThreadContext = showsThreadContext
        self.sendState = sendState
        self.actions = actions
        self.permalink = permalink
    }
}

/// Where the timeline should scroll when a snapshot is applied. `nil` means "preserve
/// the current anchor" (the default for every live update).
public enum TimelineScrollRequest: Hashable, Sendable {
    case liveEdge
    case unreadBoundary
    case post(PostID)
}

public struct TimelineSnapshot: Sendable {
    public let scope: AccountScope
    public let target: TimelineTarget
    /// Monotonic per target; the UI ignores snapshots older than the one applied.
    public let generation: UInt64
    public let items: [TimelineItem]
    /// Whether the newest retained post is the channel's newest known post.
    public let isAtLiveEdge: Bool
    /// Content may be outdated (offline, reconnecting, or awaiting reconciliation).
    public let isStale: Bool
    public let scrollRequest: TimelineScrollRequest?

    public init(scope: AccountScope, target: TimelineTarget, generation: UInt64, items: [TimelineItem],
                isAtLiveEdge: Bool, isStale: Bool, scrollRequest: TimelineScrollRequest?) {
        self.scope = scope
        self.target = target
        self.generation = generation
        self.items = items
        self.isAtLiveEdge = isAtLiveEdge
        self.isStale = isStale
        self.scrollRequest = scrollRequest
    }
}
