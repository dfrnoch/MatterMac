public import MatterMacModels
public import MattermostAPI

/// A decoded Mattermost WebSocket event. Payloads that arrive as JSON-encoded strings
/// inside `data` (post, reaction, channel, channelMember, preferences, thread) are
/// decoded a second time with the same bounds as REST responses.
public enum RealtimeEvent: Sendable {
    case posted(PostedEvent)
    case postEdited(Post)
    /// The payload is the pre-delete snapshot; the event itself is the deletion.
    case postDeleted(Post)
    case postUnread(PostUnreadEvent)
    case ephemeralMessage(Post)
    case reactionAdded(Reaction)
    case reactionRemoved(Reaction)
    case typing(userID: UserID, channelID: ChannelID, parentID: PostID?)
    /// Only ever delivered for the *current* user (server scope `self`).
    case statusChanged(userID: UserID, status: PresenceStatus)
    case channelsViewed([ChannelID: MattermostTimestamp])
    case channelCreated(channelID: ChannelID, teamID: TeamID?)
    case channelUpdated(Channel)
    /// Shared-channel variant that carries only the id.
    case channelChanged(ChannelID)
    case channelDeleted(channelID: ChannelID, deleteAt: MattermostTimestamp)
    case channelRestored(ChannelID)
    case channelConverted(ChannelID)
    case channelMemberUpdated(ChannelMembership)
    case directAdded(channelID: ChannelID)
    case groupAdded(channelID: ChannelID)
    /// `user_added`: the channel id comes from the broadcast envelope.
    case userAdded(userID: UserID, channelID: ChannelID, teamID: TeamID?)
    /// `user_removed`: when `userID` is the current user, access to the channel was
    /// revoked and its content must be purged.
    case userRemoved(userID: UserID, channelID: ChannelID, removerID: UserID?)
    case addedToTeam(teamID: TeamID, userID: UserID)
    case leftTeam(teamID: TeamID, userID: UserID)
    case teamUpdated(Team)
    case teamDeleted(TeamID)
    case userUpdated(User)
    case userRoleUpdated(userID: UserID)
    case preferencesChanged([Preference])
    case preferencesDeleted([Preference])
    /// `sidebar_category_created`/`_updated`/`_deleted`/`_order_updated`. Core re-reads
    /// the team's categories instead of trusting the partial payload; `teamID` is nil
    /// for the data-less variant emitted when favorites preferences are saved.
    case sidebarCategoriesChanged(teamID: TeamID?)
    case threadUpdated(threadID: PostID, channelID: ChannelID?)
    case threadReadChanged(threadID: PostID?, channelID: ChannelID?)
    case threadFollowChanged(threadID: PostID, isFollowing: Bool)
    /// A custom emoji was created; `nil` when the payload could not be read (the
    /// event only makes a name known sooner, so it is not a durable change).
    case emojiAdded(CustomEmoji?)
    case configChanged
    case licenseChanged
    /// An event MatterMac does not handle. Only the (bounded) name is kept.
    case unhandled(name: String)
}

public struct PostedEvent: Sendable {
    public let post: Post
    public let channelType: ChannelType
    public let teamID: TeamID?
    /// `true` when the current user is in the server-computed mention list.
    public let mentionsCurrentUser: Bool
    /// Server-filtered desktop thread notification recipient, not general follow state.
    public let notifiesCurrentThreadFollower: Bool
    public let setOnline: Bool

    public init(post: Post, channelType: ChannelType, teamID: TeamID?, mentionsCurrentUser: Bool, setOnline: Bool,
                notifiesCurrentThreadFollower: Bool = false) {
        self.post = post
        self.channelType = channelType
        self.teamID = teamID
        self.mentionsCurrentUser = mentionsCurrentUser
        self.notifiesCurrentThreadFollower = notifiesCurrentThreadFollower
        self.setOnline = setOnline
    }
}

public struct PostUnreadEvent: Sendable {
    public let channelID: ChannelID
    public let teamID: TeamID?
    public let postID: PostID?
    public let messageCount: Int64
    public let messageCountRoot: Int64
    public let mentionCount: Int64
    public let mentionCountRoot: Int64
    public let urgentMentionCount: Int64
    public let lastViewedAt: MattermostTimestamp

    public init(channelID: ChannelID, teamID: TeamID?, postID: PostID?, messageCount: Int64, messageCountRoot: Int64,
                mentionCount: Int64, mentionCountRoot: Int64, urgentMentionCount: Int64,
                lastViewedAt: MattermostTimestamp) {
        self.channelID = channelID
        self.teamID = teamID
        self.postID = postID
        self.messageCount = messageCount
        self.messageCountRoot = messageCountRoot
        self.mentionCount = mentionCount
        self.mentionCountRoot = mentionCountRoot
        self.urgentMentionCount = urgentMentionCount
        self.lastViewedAt = lastViewedAt
    }
}

/// Socket lifecycle as seen by Core (SPEC §10 explicit states).
public enum RealtimeState: Sendable, Hashable {
    case disconnected
    case connecting
    case authenticating
    /// Connected; `resumed` is `true` when the server replayed missed events on the
    /// same connection id (no REST resync needed for event continuity).
    case connected(resumed: Bool)
    case backingOff(seconds: Int)
    /// The server rejected the credential (ping FAIL 401 or upgrade 401).
    case authenticationRequired
    /// Permanently stopped (sign-out or session teardown).
    case stopped
}

/// Why Core must reconcile through REST instead of trusting event continuity.
public enum ResynchronizationReason: Sendable, Hashable {
    /// First connection of this session.
    case initialConnection
    /// The server issued a new connection id (resume unavailable or failed).
    case newConnection
    /// An event sequence gap that server replay could not repair.
    case sequenceGap
    /// Durable events arrived faster than Core consumed them; the mailbox dropped them
    /// deliberately and invalidated state instead of growing without bound.
    case mailboxOverflow
    /// A single event exceeded the WebSocket message ceiling and was not processed.
    case oversizedEvent
    /// A durable event (post, reaction, channel, membership, team, read or thread
    /// state, preferences) or an unreadable frame could not be decoded. It was not
    /// silently ignored: state it may have changed must be reconciled through REST.
    case malformedEvent
}

/// One item delivered from the realtime connection to its single consumer.
public enum RealtimeDelivery: Sendable {
    case state(RealtimeState)
    case event(RealtimeEvent)
    case resynchronize(ResynchronizationReason)
}

/// Why a reconnect was requested from outside the connection's own liveness logic.
public enum ReconnectReason: Sendable, Hashable {
    case systemWake
    case networkPathChanged
    case userRequested
}

/// The realtime connection for one authenticated server session. One receive loop,
/// one liveness controller, one bounded outbound mailbox, one consumer.
public protocol RealtimeConnection: Sendable {
    /// Starts connecting (idempotent). Deliveries begin with `.state(.connecting)`.
    func start() async
    /// Permanently stops: closes the socket, cancels timers, finishes the mailbox.
    func stop() async
    /// Coalesced: several requests while one attempt is pending schedule one attempt.
    func requestReconnect(_ reason: ReconnectReason) async
    /// Throttled per channel/thread to the server's typing interval.
    func sendTyping(channel: ChannelID, parent: PostID?) async
    /// Reports genuine user activity (`user_update_active_status`), throttled.
    func reportUserActivity(isActive: Bool) async
    /// The single consumer awaits deliveries here. Returns `nil` once stopped.
    func nextDelivery() async -> RealtimeDelivery?
}
