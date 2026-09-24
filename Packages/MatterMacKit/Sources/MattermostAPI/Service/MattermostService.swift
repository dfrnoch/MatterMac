public import Foundation
public import MatterMacModels

// The REST surface MatterMac uses, as domain-level operations. Core depends on these
// protocols only; `MattermostHTTPClient` is the production implementation and
// TestSupport provides fakes. Every method is cancellable and bounded (response
// byte budgets, per-server concurrency limits). See docs/compatibility.md for the
// endpoint matrix.

public enum RequestPriority: Sendable, Hashable {
    /// User-initiated (send, open channel, react). Uses reserved capacity.
    case interactive
    /// Prefetch, reconciliation, presence refresh.
    case background
}

public struct LoginRequest: Sendable {
    /// Email, username, or LDAP identifier as typed by the user.
    public var loginID: String
    public var password: String
    /// One-time MFA code when the server requires it.
    public var mfaToken: String?
    public var ldapOnly: Bool

    public init(loginID: String, password: String, mfaToken: String? = nil, ldapOnly: Bool = false) {
        self.loginID = loginID
        self.password = password
        self.mfaToken = mfaToken
        self.ldapOnly = ldapOnly
    }
}

public enum LoginFailure: Error, Sendable, Hashable {
    case invalidCredentials
    case mfaRequired
    case invalidMFACode
    case accountLocked
    case accountDeactivated
    case loginMethodDisabled
    /// e.g. the account uses SSO and cannot sign in with a password.
    case ssoAccountRequiresBrowser
    case emailNotVerified
    case api(APIError)
}

public struct LoginResult: Sendable {
    public let credential: BearerCredential
    public let user: User
    public init(credential: BearerCredential, user: User) {
        self.credential = credential
        self.user = user
    }
}

/// Anchor-based history query for `GET /channels/{id}/posts`. `since` is deliberately
/// not offered here: it is not interchangeable with pagination (see
/// `MattermostService.postsChangedSince`).
public enum PostPageQuery: Sendable, Hashable {
    /// Newest page.
    case latest(perPage: Int)
    /// Posts older than `postID` (exclusive), newest first.
    case before(PostID, perPage: Int)
    /// Posts newer than `postID` (exclusive), newest first.
    case after(PostID, perPage: Int)
}

public struct PostPage: Sendable {
    /// Posts in server `order` (newest first for channel queries).
    public let posts: [Post]
    /// Additional posts from the response map that are not in `order` (e.g. thread
    /// roots of replies). Useful for reply context; not part of the window.
    public let related: [Post]
    public let nextPostID: PostID?
    public let previousPostID: PostID?
    public let hasNext: Bool?
    public let skippedMalformed: Int

    public init(posts: [Post], related: [Post] = [], nextPostID: PostID? = nil, previousPostID: PostID? = nil,
                hasNext: Bool? = nil, skippedMalformed: Int = 0) {
        self.posts = posts
        self.related = related
        self.nextPostID = nextPostID
        self.previousPostID = previousPostID
        self.hasNext = hasNext
        self.skippedMalformed = skippedMalformed
    }

    public init(wire: PostListWire) {
        let ordered = wire.orderedPosts
        let orderSet = Set(wire.order)
        self.init(posts: ordered,
                  related: wire.posts.values.filter { !orderSet.contains($0.id) }.sorted { $0.createAt > $1.createAt },
                  nextPostID: wire.nextPostID, previousPostID: wire.previousPostID, hasNext: wire.hasNext,
                  skippedMalformed: wire.skippedMalformed)
    }
}

public struct ThreadPageQuery: Sendable, Hashable {
    /// Continue after this reply (ascending); `nil` for the first page.
    public var after: (postID: PostID, createAt: MattermostTimestamp)?
    public var perPage: Int
    public var collapsedThreads: Bool

    public init(after: (postID: PostID, createAt: MattermostTimestamp)? = nil, perPage: Int = 60,
                collapsedThreads: Bool) {
        self.after = after
        self.perPage = perPage
        self.collapsedThreads = collapsedThreads
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.after?.postID == rhs.after?.postID && lhs.after?.createAt == rhs.after?.createAt
            && lhs.perPage == rhs.perPage && lhs.collapsedThreads == rhs.collapsedThreads
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(after?.postID)
        hasher.combine(after?.createAt)
        hasher.combine(perPage)
        hasher.combine(collapsedThreads)
    }
}

public struct OutgoingPost: Sendable, Hashable {
    public var channelID: ChannelID
    public var rootID: PostID?
    public var message: String
    public var fileIDs: [FileID]
    public var pendingPostID: PendingPostID

    public init(channelID: ChannelID, rootID: PostID?, message: String, fileIDs: [FileID], pendingPostID: PendingPostID) {
        self.channelID = channelID
        self.rootID = rootID
        self.message = message
        self.fileIDs = fileIDs
        self.pendingPostID = pendingPostID
    }
}

/// The synchronous part of a slash-command response. Ephemeral replies are for the
/// caller only; `in_channel` replies are also posted and arrive as normal posts.
public struct CommandResult: Sendable, Hashable {
    public let isEphemeral: Bool
    /// Bounded, unrendered response text (may contain Markdown).
    public let text: String
    public let gotoLocation: String?

    public init(isEphemeral: Bool, text: String, gotoLocation: String?) {
        self.isEphemeral = isEphemeral
        self.text = text
        self.gotoLocation = gotoLocation
    }
}

public struct ChannelStats: Sendable, Hashable {
    public let memberCount: Int
    public let pinnedPostCount: Int
    public init(memberCount: Int, pinnedPostCount: Int) {
        self.memberCount = memberCount
        self.pinnedPostCount = pinnedPostCount
    }
}

/// `ChannelUnreadAt`: the member's read state after `set_unread`. `messageCount` is the
/// member's *read* message count (the channel total minus the now-unread posts).
public struct ChannelUnreadState: Sendable, Hashable {
    public let channelID: ChannelID
    public let lastViewedAt: MattermostTimestamp
    public let messageCount: Int64
    public let messageCountRoot: Int64
    public let mentionCount: Int64
    public let mentionCountRoot: Int64
    public let urgentMentionCount: Int64

    public init(channelID: ChannelID, lastViewedAt: MattermostTimestamp, messageCount: Int64, messageCountRoot: Int64,
                mentionCount: Int64, mentionCountRoot: Int64, urgentMentionCount: Int64) {
        self.channelID = channelID
        self.lastViewedAt = lastViewedAt
        self.messageCount = messageCount
        self.messageCountRoot = messageCountRoot
        self.mentionCount = mentionCount
        self.mentionCountRoot = mentionCountRoot
        self.urgentMentionCount = urgentMentionCount
    }
}

public struct SearchQuery: Sendable, Hashable {
    public var team: TeamID
    public var terms: String
    public var isOrSearch: Bool
    public var timeZoneOffsetSeconds: Int
    public var page: Int
    public var perPage: Int

    public init(team: TeamID, terms: String, isOrSearch: Bool = false, timeZoneOffsetSeconds: Int, page: Int = 0,
                perPage: Int = 20) {
        self.team = team
        self.terms = terms
        self.isOrSearch = isOrSearch
        self.timeZoneOffsetSeconds = timeZoneOffsetSeconds
        self.page = page
        self.perPage = perPage
    }
}

/// Channel member notification properties to change; `nil` fields are not sent.
public struct ChannelNotifyPropsChange: Sendable, Hashable {
    public var desktop: ChannelDesktopLevel?
    public var markUnread: MarkUnreadLevel?
    public var ignoreChannelMentions: IgnoreChannelMentions?

    public init(desktop: ChannelDesktopLevel? = nil, markUnread: MarkUnreadLevel? = nil,
                ignoreChannelMentions: IgnoreChannelMentions? = nil) {
        self.desktop = desktop
        self.markUnread = markUnread
        self.ignoreChannelMentions = ignoreChannelMentions
    }

    public var isEmpty: Bool { desktop == nil && markUnread == nil && ignoreChannelMentions == nil }
}

/// Image-like resources fetched into memory (bounded) for display.
public enum ImageResource: Sendable, Hashable {
    case profileImage(UserID, revision: Int64)
    case fileThumbnail(FileID)
    case filePreview(FileID)
    case customEmoji(id: String)
    /// An external image (link preview) fetched through the server's image proxy,
    /// `GET /api/v4/image?url=`. Only requested when the server reports `HasImageProxy`;
    /// redirects (the server's answer when the proxy is off) are never followed.
    case proxiedImage(url: String)
    /// `GET /teams/{id}/image`; `revision` is `last_team_icon_update`.
    case teamIcon(TeamID, revision: Int64)
}

/// A user-selected local file to upload, read through a scoped handle with bounded
/// streaming. Never copied to a staging directory.
public struct UploadSource: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        case file(URL, revision: String?)
        case memory(Memory)
    }
    /// Reference ownership keeps the shared budget charged until an in-flight
    /// request also releases its last copy, even after the pending item is discarded.
    public final class Memory: Sendable, Hashable {
        public let data: Data
        private let onRelease: @Sendable () -> Void
        init(data: Data, onRelease: @escaping @Sendable () -> Void) { self.data = data; self.onRelease = onRelease }
        deinit { onRelease() }
        public static func == (lhs: Memory, rhs: Memory) -> Bool { lhs === rhs }
        public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }
    public let id: String
    public let content: Content
    public let fileName: String
    public let expectedSize: Int64
    public var memoryBytes: Int { if case .memory(let memory) = content { memory.data.count } else { 0 } }
    public var metadataBytes: Int { id.utf8.count + fileName.utf8.count + 128 }

    public init(fileURL: URL, fileName: String, expectedSize: Int64, revision: String? = nil) {
        id = fileURL.absoluteString
        content = .file(fileURL, revision: revision)
        self.fileName = fileName
        self.expectedSize = expectedSize
    }

    /// No decoding, conversion, temporary file or persisted bookmark. The draft
    /// ledger must admit these bytes synchronously before the source is retained.
    public init(pastedImage data: Data, typeIdentifier: String, maximumBytes: Int, onRelease: @escaping @Sendable () -> Void) throws(APIError) {
        guard !data.isEmpty, data.count <= maximumBytes else { throw .responseTooLarge(limitBytes: maximumBytes) }
        let suffix: String
        switch typeIdentifier {
        case "public.png" where data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]): suffix = "png"
        case "public.tiff" where data.starts(with: [73, 73, 42, 0]) || data.starts(with: [77, 77, 0, 42]): suffix = "tiff"
        default: throw .malformedResponse
        }
        id = UUID().uuidString
        content = .memory(Memory(data: data, onRelease: onRelease))
        fileName = "Pasted image." + suffix
        expectedSize = Int64(data.count)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.expectedSize == rhs.expectedSize && lhs.fileName == rhs.fileName && lhs.content == rhs.content
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension UploadSource {
    /// Metadata only; selection never loads file contents or creates a staging copy.
    @concurrent
    public static func selected(_ urls: [URL], budget: ResourceBudget) async throws(APIError) -> [UploadSource] {
        guard urls.count <= budget.attachmentsPerPost else { throw .overloaded }
        return try urls.map { (url: URL) throws(APIError) -> UploadSource in
            guard url.isFileURL, url.absoluteString.utf8.count <= budget.attachmentPathBytes else { throw APIError.localFileUnavailable }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let snapshot = try FileSnapshot.open(url)
                defer { snapshot.close() }
                return UploadSource(fileURL: url, fileName: url.lastPathComponent, expectedSize: snapshot.size,
                                    revision: snapshot.revision)
            } catch { throw APIError.localFileUnavailable }
        }
    }
}

public struct TransferProgress: Sendable, Hashable {
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// Unauthenticated discovery and login against one normalized server.
public protocol MattermostDiscoveryService: Sendable {
    var endpoint: ServerEndpoint { get }
    /// `GET /api/v4/system/ping`. Confirms a Mattermost server answers at this base.
    func ping() async throws(APIError) -> ServerVersion?
    /// `GET /api/v4/config/client?format=old` (limited, unauthenticated form).
    func limitedConfiguration() async throws(APIError) -> ServerCapabilities
    /// `POST /api/v4/users/login`. On success returns the `Token` header credential.
    func login(_ request: LoginRequest) async throws(LoginFailure) -> LoginResult
    func loginWithDesktopCode(_ code: DesktopLoginCode) async throws(APIError) -> LoginResult
    /// Cancels outstanding work and releases network resources (URLSession
    /// invalidation). Later calls fail with `.cancelled`. Idempotent.
    func shutdown() async
}

/// Authenticated REST operations for one account session.
public protocol MattermostService: Sendable {
    var endpoint: ServerEndpoint { get }

    // Identity and configuration
    func currentUser() async throws(APIError) -> User
    func fullConfiguration() async throws(APIError) -> ClientConfigWire
    /// `POST /api/v4/users/logout`: revokes this session server-side.
    func logout() async throws(APIError)
    func preferences() async throws(APIError) -> [Preference]
    /// `PUT /users/{id}/preferences` (1–100 items). An explicit server-side change.
    func savePreferences(_ preferences: [Preference], me: UserID) async throws(APIError)
    /// `POST /users/{id}/preferences/delete`.
    func deletePreferences(_ preferences: [Preference], me: UserID) async throws(APIError)

    // Teams and channels
    func teams() async throws(APIError) -> [Team]
    func teamMemberships() async throws(APIError) -> [TeamMemberWire]
    /// Channels in a team *plus* the user's DMs/GMs. Returns `[]` for the server's
    /// "no channels" 404.
    func channels(team: TeamID) async throws(APIError) -> [Channel]
    func channelMemberships(team: TeamID) async throws(APIError) -> [ChannelMembership]
    func channel(_ id: ChannelID) async throws(APIError) -> Channel
    func channelMembership(_ id: ChannelID) async throws(APIError) -> ChannelMembership
    func channelStats(_ id: ChannelID) async throws(APIError) -> ChannelStats
    /// `GET /users?in_channel=` (active users, username order). Requires `read_channel`.
    func channelMembers(_ id: ChannelID, page: Int, perPage: Int) async throws(APIError) -> [User]
    /// `PUT /channels/{id}/members/{user}/notify_props`; only `mark_unread` is sent,
    /// other notification settings are left unchanged by the server.
    func setChannelMarkUnread(_ id: ChannelID, level: MarkUnreadLevel, me: UserID) async throws(APIError)
    func createDirectChannel(with other: UserID, me: UserID) async throws(APIError) -> Channel
    func joinChannel(_ id: ChannelID, me: UserID) async throws(APIError)
    func leaveChannel(_ id: ChannelID, me: UserID) async throws(APIError)
    /// `POST /channels/members/me/view`. Returns the server's resulting view times.
    func viewChannel(_ id: ChannelID?, previous: ChannelID?, collapsedThreadsSupported: Bool)
        async throws(APIError) -> [ChannelID: MattermostTimestamp]
    func searchChannels(team: TeamID, term: String) async throws(APIError) -> [Channel]
    /// `PUT /channels/{id}/members/{user}/notify_props` with only the changed keys;
    /// the server merges them into the member's existing properties.
    func updateChannelNotifyProps(_ id: ChannelID, _ change: ChannelNotifyPropsChange, me: UserID) async throws(APIError)
    /// `GET /users/{id}/teams/{team}/channels/categories`, in the server's `order`.
    func sidebarCategories(team: TeamID, me: UserID) async throws(APIError) -> [SidebarCategory]
    /// `GET /users/{id}/teams/{team}/channels/categories/{category}`.
    func sidebarCategory(_ id: SidebarCategoryID, team: TeamID, me: UserID) async throws(APIError) -> SidebarCategory
    /// `PUT /users/{id}/teams/{team}/channels/categories/{category}`. Replaces the
    /// category, including its channel list; send a freshly read category.
    func updateSidebarCategory(_ category: SidebarCategory) async throws(APIError) -> SidebarCategory
    /// `GET /users/me/teams/unread` (DMs/GMs are not included).
    func teamUnreads(includeCollapsedThreads: Bool) async throws(APIError) -> [TeamUnread]
    /// `GET /teams/{id}/channels` (public, not archived, display-name order).
    func publicChannels(team: TeamID, page: Int, perPage: Int) async throws(APIError) -> [Channel]
    /// `GET /teams/{id}/channels/deleted`. The server's "none" 404 is `[]`.
    func archivedChannels(team: TeamID, page: Int, perPage: Int) async throws(APIError) -> [Channel]
    /// `POST /channels/stats/member_count`.
    func channelMemberCounts(_ ids: [ChannelID]) async throws(APIError) -> [ChannelID: Int]
    /// `POST /channels` (public or private team channel).
    func createChannel(_ request: NewChannelRequest) async throws(APIError) -> Channel
    /// `POST /channels/group`: the server adds the caller; 3–8 members in total.
    func createGroupChannel(with users: [UserID]) async throws(APIError) -> Channel
    /// `POST /channels/{id}/members` for other users (`user_id` or `user_ids`).
    func addChannelMembers(_ id: ChannelID, users: [UserID]) async throws(APIError)
    /// `POST /users/search`.
    func searchUsers(_ query: UserSearchQuery) async throws(APIError) -> [User]

    // Posts
    func posts(channel: ChannelID, query: PostPageQuery, collapsedThreads: Bool, priority: RequestPriority)
        async throws(APIError) -> PostPage
    /// The window around the first unread post (`/posts/unread`).
    func postsAroundLastUnread(channel: ChannelID, me: UserID, limitBefore: Int, limitAfter: Int,
                               collapsedThreads: Bool) async throws(APIError) -> PostPage
    func thread(root: PostID, query: ThreadPageQuery) async throws(APIError) -> PostPage
    func post(_ id: PostID) async throws(APIError) -> Post
    /// `POST /posts/ids`; includes deleted posts (message blanked) for reconciliation.
    func posts(ids: [PostID]) async throws(APIError) -> [Post]
    /// `POST /api/v4/posts`. A transport failure after send maps to `.outcomeUnknown`.
    func createPost(_ post: OutgoingPost) async throws(APIError) -> Post
    func editPost(_ id: PostID, message: String) async throws(APIError) -> Post
    func deletePost(_ id: PostID) async throws(APIError)
    func addReaction(post: PostID, emojiName: String, me: UserID) async throws(APIError) -> Reaction
    func removeReaction(post: PostID, emojiName: String, me: UserID) async throws(APIError)
    func searchPosts(_ query: SearchQuery) async throws(APIError) -> PostPage
    /// `GET /users/{id}/teams/{team}/threads?extended=true`: followed threads, newest
    /// reply first. `before` pages older; `totalsOnly` returns only the unread totals.
    func userThreads(team: TeamID, me: UserID, before: PostID?, perPage: Int, unreadOnly: Bool, totalsOnly: Bool)
        async throws(APIError) -> UserThreadList
    /// `PUT` / `DELETE /users/{id}/teams/{team}/threads/{thread}/following`.
    func setThreadFollowing(_ thread: PostID, following: Bool, team: TeamID, me: UserID) async throws(APIError)
    /// `PUT /users/{id}/teams/{team}/threads/{thread}/read/{timestamp}`; `thread == nil` marks all read.
    func markThreadRead(_ thread: PostID?, at timestamp: MattermostTimestamp, team: TeamID, me: UserID) async throws(APIError)
    /// `PUT /channels/{id}/patch`; `nil` fields are left unchanged.
    func patchChannel(_ id: ChannelID, displayName: String?, header: String?, purpose: String?) async throws(APIError) -> Channel
    /// `GET /users/{id}/posts/flagged` (saved messages), newest first.
    func flaggedPosts(me: UserID, page: Int, perPage: Int) async throws(APIError) -> PostPage
    /// `GET /channels/{id}/pinned`.
    func pinnedPosts(channel: ChannelID) async throws(APIError) -> PostPage
    /// `POST /commands/execute`. Not idempotent: a lost response is `.outcomeUnknown`.
    func executeCommand(_ command: String, channel: ChannelID, team: TeamID?, rootID: PostID?)
        async throws(APIError) -> CommandResult
    /// `POST /posts/{id}/pin` (or `/unpin`). Needs read access; the edit time limit
    /// applies unless the call is a no-op.
    func setPinned(_ id: PostID, pinned: Bool) async throws(APIError)
    /// `POST /users/{me}/posts/{post}/set_unread` with `collapsed_threads_supported`.
    func markUnread(from post: PostID, me: UserID) async throws(APIError) -> ChannelUnreadState

    // Users
    func users(ids: [UserID]) async throws(APIError) -> [User]
    func statuses(ids: [UserID]) async throws(APIError) -> [UserID: PresenceStatus]
    /// `PUT /users/{id}/status`: a manual status visible to everyone on the server.
    func setStatus(_ status: PresenceStatus, me: UserID) async throws(APIError)
    /// `PUT /users/{id}/status/custom`; `nil` clears it (`DELETE`).
    func setCustomStatus(_ status: CustomStatus?, duration: String, me: UserID) async throws(APIError)
    /// `POST /users/usernames` (at most 200 names per request).
    func users(usernames: [String]) async throws(APIError) -> [User]
    func autocompleteUsers(team: TeamID, channel: ChannelID?, name: String, limit: Int)
        async throws(APIError) -> [User]
    /// `PUT /users/{id}/patch` with `notify_props` only. The server replaces the whole
    /// map, so `props` must be the complete, unmodified-except-for-the-change map.
    func patchNotifyProps(_ props: UserNotifyProps, me: UserID) async throws(APIError) -> User

    // Files and media
    func fileInfo(_ id: FileID) async throws(APIError) -> FileInfo
    /// Fetches an image into memory with a strict byte limit (compressed bytes).
    func imageData(_ resource: ImageResource, maximumBytes: Int) async throws(APIError) -> Data
    /// Streams a user-selected file to `POST /api/v4/files` without staging a copy.
    func upload(_ source: UploadSource, channel: ChannelID, clientID: String,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> FileInfo
    /// Streams a file download to a user-chosen destination with bounded memory.
    /// Partial output is removed on failure or cancellation.
    func download(_ id: FileID, to destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError)

    // Lifecycle
    /// Called at sign-out / session teardown (after an optional `logout()`): cancels
    /// queued and in-flight requests, invalidates the URLSession and releases the
    /// credential's transport. Later calls fail with `.cancelled`. Idempotent.
    func shutdown() async
}

extension MattermostDiscoveryService {
    /// Default for test doubles that own no network resources.
    public func shutdown() async {}
}

extension MattermostService {
    /// Default for test doubles that own no network resources.
    public func shutdown() async {}
}

/// Builds services for a normalized endpoint. The factory owns shared transport
/// configuration and the global concurrency limiter.
public protocol MattermostServiceFactory: Sendable {
    func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService
    func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService
}
