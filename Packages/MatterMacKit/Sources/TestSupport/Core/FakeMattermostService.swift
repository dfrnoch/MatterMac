public import Foundation
import os
public import MatterMacModels
public import MattermostAPI

/// Scriptable in-memory `MattermostService` for Core tests. Each operation can be
/// overridden with a handler; unscripted operations use simple in-memory behavior.
/// `Gate`s let a test suspend a response to reproduce event/response races.
public final class FakeMattermostService: MattermostService {
    public let endpoint: ServerEndpoint
    private let lock: OSAllocatedUnfairLock<State>
    /// Sidebar categories, browsing and membership fakes (FakeMattermostService+Directory.swift).
    let directory = OSAllocatedUnfairLock(initialState: DirectoryState())
    /// Custom emoji and slash-command fakes (FakeMattermostService+Emoji.swift).
    let emojiCommands = OSAllocatedUnfairLock(initialState: EmojiCommandState())
    /// Own-profile, detailed status and file search fakes (FakeMattermostService+Profile.swift).
    let profileState = OSAllocatedUnfairLock(initialState: ProfileFakeState())

    public struct State: Sendable {
        public var me: User
        public var attachmentsEnabled: Bool? = true
        public var teams: [Team] = []
        public var channels: [ChannelID: Channel] = [:]
        public var memberships: [ChannelID: ChannelMembership] = [:]
        public var posts: [PostID: Post] = [:]
        public var users: [UserID: User] = [:]
        public var calls: [String] = []
        public var createdPosts: [OutgoingPost] = []
        public var viewedChannels: [ChannelID] = []
        public var statuses: [UserID: PresenceStatus] = [:]
        public var executedCommands: [String] = []
        public var threads: [UserThread] = []
        /// Saved (flagged) post ids, newest first.
        public var flagged: [PostID] = []
        public var threadReadMarks: [PostID?] = []
        public var commandHandler: (@Sendable (String) async throws -> CommandResult)?
        public var savedPreferences: [Preference] = []
        public var deletedPreferences: [Preference] = []
        public var imageHandler: (@Sendable (ImageResource, Int) async throws -> Data)?
        public var uploadHandler: (@Sendable (UploadSource, ChannelID) async throws -> FileInfo)?
        public var downloadHandler: (@Sendable (FileID, URL) async throws -> Void)?
        public var createPostHandler: (@Sendable (OutgoingPost, Int) async throws -> Post)?
        public var editPostHandler: (@Sendable (PostID, String) async throws -> Post)?
        public var postsHandler: (@Sendable (ChannelID, PostPageQuery) async throws -> PostPage)?
        public var unreadHandler: (@Sendable (ChannelID) async throws -> PostPage)?
        public var postsByIDsHandler: (@Sendable ([PostID]) async throws -> [Post])?
        /// Returned by `preferences()`; saves and deletes update it.
        public var preferences: [Preference] = []
        public var channelNotifyChanges: [(ChannelID, ChannelNotifyPropsChange)] = []
        public var patchedNotifyProps: [UserNotifyProps] = []
        public var collapsedThreadsConfig = "disabled"
        public var nextID: Int = 1
        public var pinChanges: [(PostID, Bool)] = []
        public var unreadMarks: [PostID] = []
        public var markUnreadHandler: (@Sendable (PostID) async throws -> ChannelUnreadState)?
        public var pinHandler: (@Sendable (PostID, Bool) async throws -> Void)?

        init(me: User) { self.me = me }
    }

    public init(endpoint: ServerEndpoint, me: User) {
        self.endpoint = endpoint
        var initial = State(me: me)
        initial.users[me.id] = me
        self.lock = OSAllocatedUnfairLock(initialState: initial)
    }

    public func withState<T: Sendable>(_ body: @Sendable (inout State) -> T) -> T {
        lock.withLock { body(&$0) }
    }

    public var calls: [String] { withState { $0.calls } }

    private func record(_ call: String) { withState { $0.calls.append(call) } }

    public func makeID(_ prefix: String = "p") -> String {
        withState { state in
            let n = state.nextID
            state.nextID += 1
            let base = prefix + String(n)
            return base + String(repeating: "x", count: max(0, 26 - base.count))
        }
    }

    // MARK: MattermostService

    public func currentUser() async throws(APIError) -> User {
        record("currentUser")
        return withState { $0.me }
    }

    public func fullConfiguration() async throws(APIError) -> ClientConfigWire {
        record("fullConfiguration")
        var values = ["Version": "11.11.1", "CollapsedThreads": withState { $0.collapsedThreadsConfig }, "MaxPostSize": "16383",
                      "EnableUserTypingMessages": "true"]
        if let enabled = withState({ $0.attachmentsEnabled }) { values["EnableFileAttachments"] = String(enabled) }
        let data: Data
        do { data = try JSONEncoder().encode(values) } catch { throw .malformedResponse }
        do { return try JSONDecoder().decode(ClientConfigWire.self, from: data) } catch { throw .malformedResponse }
    }

    public func logout() async throws(APIError) { record("logout") }
    public func preferences() async throws(APIError) -> [Preference] {
        record("preferences")
        return withState { $0.preferences }
    }
    public func savePreferences(_ preferences: [Preference], me: UserID) async throws(APIError) {
        record("savePreferences")
        withState { state in
            state.savedPreferences.append(contentsOf: preferences)
            for preference in preferences {
                state.preferences.removeAll { $0.category == preference.category && $0.name == preference.name }
                state.preferences.append(preference)
            }
        }
        syncFavorites(preferences, deleted: false)
    }
    public func deletePreferences(_ preferences: [Preference], me: UserID) async throws(APIError) {
        record("deletePreferences")
        withState { state in
            state.deletedPreferences.append(contentsOf: preferences)
            for preference in preferences {
                state.preferences.removeAll { $0.category == preference.category && $0.name == preference.name }
            }
        }
        syncFavorites(preferences, deleted: true)
    }

    /// The server keeps the Favorites category in sync with `favorite_channel`.
    private func syncFavorites(_ preferences: [Preference], deleted: Bool) {
        directory.withLock { state in
            for preference in preferences where preference.category == "favorite_channel" {
                guard let id = ChannelID(rawValue: preference.name) else { continue }
                if !deleted && preference.value == "true" { state.favorites.insert(id) } else { state.favorites.remove(id) }
                for (team, list) in state.categories {
                    state.categories[team] = list.map { category in
                        var category = category
                        category.channelIDs.removeAll { $0 == id }
                        if category.kind == .favorites, state.favorites.contains(id) { category.channelIDs.insert(id, at: 0) }
                        return category
                    }
                }
            }
        }
    }
    public func teams() async throws(APIError) -> [Team] { record("teams"); return withState { $0.teams } }
    public func teamMemberships() async throws(APIError) -> [TeamMemberWire] { [] }

    public func channels(team: TeamID) async throws(APIError) -> [Channel] {
        record("channels")
        return withState { state in state.channels.values.filter { $0.teamID == team || $0.teamID == nil } }
    }

    public func channelMemberships(team: TeamID) async throws(APIError) -> [ChannelMembership] {
        record("channelMemberships")
        return withState { state in
            state.memberships.values.filter { member in
                guard let channel = state.channels[member.channelID] else { return false }
                return channel.teamID == team || channel.teamID == nil
            }
        }
    }

    public func channel(_ id: ChannelID) async throws(APIError) -> Channel {
        guard let channel = withState({ $0.channels[id] }) else { throw .notFound(ServerErrorInfo(id: "", statusCode: 404, requestID: nil)) }
        return channel
    }

    public func channelMembership(_ id: ChannelID) async throws(APIError) -> ChannelMembership {
        guard let member = withState({ $0.memberships[id] }) else { throw .forbidden(ServerErrorInfo(id: ServerErrorID.permissions, statusCode: 403, requestID: nil)) }
        return member
    }

    public func channelStats(_ id: ChannelID) async throws(APIError) -> ChannelStats { ChannelStats(memberCount: 3, pinnedPostCount: 0) }

    public func channelMembers(_ id: ChannelID, page: Int, perPage: Int) async throws(APIError) -> [User] {
        record("channelMembers")
        return withState { state in
            let all = state.users.values.filter { !$0.isDeactivated }.sorted { $0.username < $1.username }
            return Array(all.dropFirst(page * perPage).prefix(perPage))
        }
    }
    public func setChannelMarkUnread(_ id: ChannelID, level: MarkUnreadLevel, me: UserID) async throws(APIError) {
        record("setChannelMarkUnread")
        withState { $0.memberships[id]?.markUnread = level }
    }
    public func createDirectChannel(with other: UserID, me: UserID) async throws(APIError) -> Channel {
        let ids = [me.rawValue, other.rawValue].sorted()
        let channel = Channel(id: ChannelID(unchecked: makeID("d")), teamID: nil, type: .direct,
                              name: ids.joined(separator: "__"), displayName: "")
        withState { state in
            state.channels[channel.id] = channel
            state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: me)
        }
        return channel
    }

    public func joinChannel(_ id: ChannelID, me: UserID) async throws(APIError) {}
    public func leaveChannel(_ id: ChannelID, me: UserID) async throws(APIError) {}

    public func viewChannel(_ id: ChannelID?, previous: ChannelID?, collapsedThreadsSupported: Bool)
        async throws(APIError) -> [ChannelID: MattermostTimestamp]
    {
        record("viewChannel")
        guard let id else { return [:] }
        withState { $0.viewedChannels.append(id) }
        return [id: MattermostTimestamp(milliseconds: 1)]
    }

    public func searchChannels(team: TeamID, term: String) async throws(APIError) -> [Channel] {
        record("searchChannels")
        return searchPublicChannels(team: team, term: term)
    }

    public func updateChannelNotifyProps(_ id: ChannelID, _ change: ChannelNotifyPropsChange, me: UserID)
        async throws(APIError) {
        record("updateChannelNotifyProps")
        withState { state in
            state.channelNotifyChanges.append((id, change))
            if let desktop = change.desktop { state.memberships[id]?.desktop = desktop }
            if let markUnread = change.markUnread { state.memberships[id]?.markUnread = markUnread }
            if let ignore = change.ignoreChannelMentions { state.memberships[id]?.ignoreChannelMentions = ignore }
        }
    }

    public func posts(channel: ChannelID, query: PostPageQuery, collapsedThreads: Bool, priority: RequestPriority)
        async throws(APIError) -> PostPage
    {
        record("posts")
        if let handler = withState({ $0.postsHandler }) { return try await Self.typed { try await handler(channel, query) } }
        let all = withState { state in state.posts.values.filter { $0.channelID == channel && !$0.isDeleted } }
            .sorted { $0.createAt > $1.createAt }
        switch query {
        case .latest(let perPage):
            let page = Array(all.prefix(perPage))
            return PostPage(posts: page, previousPostID: all.count > perPage ? all[perPage].id : nil)
        case .before(let id, let perPage):
            guard let index = all.firstIndex(where: { $0.id == id }) else { return PostPage(posts: []) }
            let older = Array(all[(index + 1)...].prefix(perPage))
            let hasMore = all.count > index + 1 + perPage
            return PostPage(posts: older, nextPostID: id, previousPostID: hasMore ? all[index + 1 + perPage].id : nil)
        case .after(let id, let perPage):
            guard let index = all.firstIndex(where: { $0.id == id }) else { return PostPage(posts: []) }
            let newer = Array(all[..<index].suffix(perPage))
            let hasMore = index > perPage
            return PostPage(posts: newer, nextPostID: hasMore ? all[index - perPage - 1].id : nil, previousPostID: id)
        }
    }

    public func postsAroundLastUnread(channel: ChannelID, me: UserID, limitBefore: Int, limitAfter: Int,
                                      collapsedThreads: Bool) async throws(APIError) -> PostPage {
        record("postsAroundLastUnread")
        if let handler = withState({ $0.unreadHandler }) { return try await Self.typed { try await handler(channel) } }
        return try await posts(channel: channel, query: .latest(perPage: limitBefore + limitAfter),
                               collapsedThreads: collapsedThreads, priority: .interactive)
    }

    public func thread(root: PostID, query: ThreadPageQuery) async throws(APIError) -> PostPage {
        record("thread")
        let posts = withState { state in
            state.posts.values.filter { $0.id == root || $0.rootID == root }.sorted { $0.createAt < $1.createAt }
        }
        return PostPage(posts: posts, hasNext: false)
    }

    public func post(_ id: PostID) async throws(APIError) -> Post {
        guard let post = withState({ $0.posts[id] }) else { throw .notFound(ServerErrorInfo(id: ServerErrorID.postNotFound, statusCode: 404, requestID: nil)) }
        return post
    }

    public func posts(ids: [PostID]) async throws(APIError) -> [Post] {
        record("postsByIDs")
        if let handler = withState({ $0.postsByIDsHandler }) { return try await Self.typed { try await handler(ids) } }
        return withState { state in ids.compactMap { state.posts[$0] } }
    }

    public func createPost(_ post: OutgoingPost) async throws(APIError) -> Post {
        let attempt = withState { state -> Int in
            state.createdPosts.append(post)
            state.calls.append("createPost")
            return state.createdPosts.filter { $0.pendingPostID == post.pendingPostID }.count
        }
        if let handler = withState({ $0.createPostHandler }) { return try await Self.typed { try await handler(post, attempt) } }
        return storeCreated(post)
    }

    /// Bridges an untyped-throws handler (typed-throws closure *types* need the macOS 15
    /// runtime) back to `APIError`.
    static func typed<T: Sendable>(_ body: @Sendable () async throws -> T) async throws(APIError) -> T {
        do { return try await body() } catch let error as APIError { throw error } catch { throw .cancelled }
    }

    /// Default create behavior, also usable from custom handlers.
    public func storeCreated(_ outgoing: OutgoingPost, createAt: Int64 = 1_000) -> Post {
        withState { state in
            // Server-side dedup by pending_post_id.
            if let existing = state.posts.values.first(where: { $0.pendingPostID == outgoing.pendingPostID }) { return existing }
            let n = state.nextID
            state.nextID += 1
            let base = "srv" + String(n)
            let id = PostID(unchecked: base + String(repeating: "q", count: 26 - base.count))
            let post = Post(id: id, channelID: outgoing.channelID, userID: state.me.id, rootID: outgoing.rootID,
                            message: outgoing.message, createAt: MattermostTimestamp(milliseconds: createAt + Int64(n)),
                            fileIDs: outgoing.fileIDs, pendingPostID: outgoing.pendingPostID)
            state.posts[id] = post
            return post
        }
    }

    public func editPost(_ id: PostID, message: String) async throws(APIError) -> Post {
        record("editPost")
        if let handler = withState({ $0.editPostHandler }) { return try await Self.typed { try await handler(id, message) } }
        guard var post = withState({ $0.posts[id] }) else { throw .notFound(ServerErrorInfo(id: "", statusCode: 404, requestID: nil)) }
        post.message = message
        post.editAt = MattermostTimestamp(milliseconds: post.updateAt.milliseconds + 1)
        post.updateAt = post.editAt
        let edited = post
        withState { $0.posts[id] = edited }
        return edited
    }

    public func deletePost(_ id: PostID) async throws(APIError) {
        withState { state in state.posts[id]?.deleteAt = MattermostTimestamp(milliseconds: 9_999) }
    }

    public func addReaction(post: PostID, emojiName: String, me: UserID) async throws(APIError) -> Reaction {
        Reaction(userID: me, postID: post, emojiName: emojiName)
    }

    public func removeReaction(post: PostID, emojiName: String, me: UserID) async throws(APIError) {}

    public func searchPosts(_ query: SearchQuery) async throws(APIError) -> PostPage {
        record("searchPosts")
        let hits = withState { state in state.posts.values.filter { $0.message.contains(query.terms) } }
        return PostPage(posts: hits.sorted { $0.createAt > $1.createAt })
    }

    public func users(ids: [UserID]) async throws(APIError) -> [User] {
        record("users")
        return withState { state in ids.compactMap { state.users[$0] } }
    }

    public func statuses(ids: [UserID]) async throws(APIError) -> [UserID: PresenceStatus] {
        withState { state in Dictionary(ids.map { ($0, state.statuses[$0] ?? .online) }, uniquingKeysWith: { first, _ in first }) }
    }

    public func patchChannel(_ id: ChannelID, displayName: String?, header: String?, purpose: String?)
        async throws(APIError) -> Channel {
        record("patchChannel")
        let updated = withState { state -> Channel? in
            guard var channel = state.channels[id] else { return nil }
            if let displayName { channel.displayName = displayName }
            if let header { channel.header = header }
            if let purpose { channel.purpose = purpose }
            state.channels[id] = channel
            return channel
        }
        guard let updated else { throw .notFound(ServerErrorInfo(id: "", statusCode: 404, requestID: nil)) }
        return updated
    }

    public func markChannelsRead(_ ids: [ChannelID], me: UserID) async throws(APIError) -> [ChannelID: MattermostTimestamp] {
        record("markChannelsRead")
        return withState { state in
            var times: [ChannelID: MattermostTimestamp] = [:]
            for id in ids {
                guard let channel = state.channels[id] else { continue }
                state.memberships[id]?.messageCount = channel.totalMessageCount
                state.memberships[id]?.mentionCount = 0
                times[id] = channel.lastPostAt
            }
            return times
        }
    }

    public func flaggedPosts(me: UserID, page: Int, perPage: Int) async throws(APIError) -> PostPage {
        record("flaggedPosts")
        let posts = withState { state in state.flagged.compactMap { state.posts[$0] } }
        return PostPage(posts: Array(posts.dropFirst(page * perPage).prefix(perPage)))
    }

    public func pinnedPosts(channel: ChannelID) async throws(APIError) -> PostPage {
        record("pinnedPosts")
        return PostPage(posts: withState { state in state.posts.values.filter { $0.channelID == channel && $0.isPinned }
            .sorted { $0.createAt > $1.createAt } })
    }

    public func userThreads(team: TeamID, me: UserID, before: PostID?, perPage: Int, unreadOnly: Bool, totalsOnly: Bool)
        async throws(APIError) -> UserThreadList {
        record("userThreads")
        return withState { state in
            var threads = state.threads.filter { !unreadOnly || $0.unreadReplies > 0 }
                .sorted { $0.lastReplyAt > $1.lastReplyAt }
            if let before, let index = threads.firstIndex(where: { $0.root.id == before }) {
                threads = Array(threads[(index + 1)...])
            }
            return UserThreadList(threads: totalsOnly ? [] : Array(threads.prefix(perPage)),
                                  totalUnreadThreads: state.threads.filter { $0.unreadReplies > 0 }.count,
                                  totalUnreadMentions: state.threads.reduce(0) { $0 + $1.unreadMentions })
        }
    }

    public func userThread(_ thread: PostID, team: TeamID, me: UserID) async throws(APIError) -> UserThread? {
        record("userThread")
        return withState { state in state.threads.first { $0.root.id == thread } }
    }

    public func setThreadFollowing(_ thread: PostID, following: Bool, team: TeamID, me: UserID) async throws(APIError) {
        record(following ? "followThread" : "unfollowThread")
        withState { state in
            if !following { state.threads.removeAll { $0.root.id == thread } }
            else if !state.threads.contains(where: { $0.root.id == thread }), let root = state.posts[thread] {
                state.threads.append(UserThread(root: root, replyCount: root.replyCount, lastReplyAt: root.lastReplyAt,
                                                lastViewedAt: .zero, unreadReplies: 0, unreadMentions: 0, participants: []))
            }
        }
    }

    public func markThreadRead(_ thread: PostID?, at timestamp: MattermostTimestamp, team: TeamID, me: UserID)
        async throws(APIError) {
        record("markThreadRead")
        withState { state in
            state.threadReadMarks.append(thread)
            state.threads = state.threads.map { item in
                guard thread == nil || item.root.id == thread else { return item }
                return UserThread(root: item.root, replyCount: item.replyCount, lastReplyAt: item.lastReplyAt,
                                  lastViewedAt: timestamp, unreadReplies: 0, unreadMentions: 0, participants: item.participants)
            }
        }
    }

    public func executeCommand(_ command: String, channel: ChannelID, team: TeamID?, rootID: PostID?)
        async throws(APIError) -> CommandResult {
        record("executeCommand")
        withState { $0.executedCommands.append(command) }
        if let handler = withState({ $0.commandHandler }) { return try await Self.typed { try await handler(command) } }
        return CommandResult(isEphemeral: true, text: "", gotoLocation: nil)
    }

    public func setPinned(_ id: PostID, pinned: Bool) async throws(APIError) {
        record(pinned ? "pin" : "unpin")
        withState { $0.pinChanges.append((id, pinned)) }
        if let handler = withState({ $0.pinHandler }) { try await Self.typed { try await handler(id, pinned) } }
        withState { state in
            guard var post = state.posts[id] else { return }
            post.isPinned = pinned
            post.updateAt = MattermostTimestamp(milliseconds: post.updateAt.milliseconds + 1)
            state.posts[id] = post
        }
    }

    public func markUnread(from post: PostID, me: UserID) async throws(APIError) -> ChannelUnreadState {
        record("markUnread")
        withState { $0.unreadMarks.append(post) }
        if let handler = withState({ $0.markUnreadHandler }) { return try await Self.typed { try await handler(post) } }
        guard let stored = withState({ $0.posts[post] }) else {
            throw .notFound(ServerErrorInfo(id: ServerErrorID.postNotFound, statusCode: 404, requestID: nil))
        }
        return withState { state in
            let channel = state.channels[stored.channelID]
            let newer = state.posts.values.filter { $0.channelID == stored.channelID && $0.createAt >= stored.createAt }
            let total = channel?.totalMessageCount ?? Int64(newer.count)
            return ChannelUnreadState(channelID: stored.channelID,
                                      lastViewedAt: MattermostTimestamp(milliseconds: stored.createAt.milliseconds - 1),
                                      messageCount: max(0, total - Int64(newer.count)),
                                      messageCountRoot: max(0, (channel?.totalMessageCountRoot ?? total)
                                          - Int64(newer.filter { $0.rootID == nil }.count)),
                                      mentionCount: 0, mentionCountRoot: 0, urgentMentionCount: 0)
        }
    }

    public func setStatus(_ status: PresenceStatus, me: UserID) async throws(APIError) {
        record("setStatus")
        withState { $0.statuses[me] = status }
    }

    public func setCustomStatus(_ status: CustomStatus?, duration: String, me: UserID) async throws(APIError) {
        record("setCustomStatus")
        withState { $0.users[me]?.customStatus = status; if $0.me.id == me { $0.me.customStatus = status } }
    }

    public func users(usernames: [String]) async throws(APIError) -> [User] {
        record("usernames")
        return withState { state in state.users.values.filter { usernames.contains($0.username) } }
    }

    public func autocompleteUsers(team: TeamID, channel: ChannelID?, name: String, limit: Int)
        async throws(APIError) -> [User] {
        withState { state in Array(state.users.values.filter { $0.username.hasPrefix(name) }.prefix(limit)) }
    }

    public func patchNotifyProps(_ props: UserNotifyProps, me: UserID) async throws(APIError) -> User {
        record("patchNotifyProps")
        guard props.isComplete else { throw .malformedResponse }
        return withState { state in
            state.patchedNotifyProps.append(props)
            state.me.notifyProps = props
            state.users[me]?.notifyProps = props
            return state.me
        }
    }

    public func fileInfo(_ id: FileID) async throws(APIError) -> FileInfo {
        throw .notFound(ServerErrorInfo(id: "", statusCode: 404, requestID: nil))
    }

    public func imageData(_ resource: ImageResource, maximumBytes: Int) async throws(APIError) -> Data {
        record("imageData")
        if let handler = withState({ $0.imageHandler }) { return try await Self.typed { try await handler(resource, maximumBytes) } }
        throw .notFound(ServerErrorInfo(id: "", statusCode: 404, requestID: nil))
    }

    public func upload(_ source: UploadSource, channel: ChannelID, clientID: String,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> FileInfo {
        record("upload")
        if let handler = withState({ $0.uploadHandler }) { return try await Self.typed { try await handler(source, channel) } }
        return FileInfo(id: FileID(unchecked: makeID("f")), channelID: channel, name: source.fileName, size: source.expectedSize)
    }

    public func download(_ id: FileID, to destination: URL,
                         progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) {
        record("download")
        if let handler = withState({ $0.downloadHandler }) { try await Self.typed { try await handler(id, destination) } }
    }
}

/// A one-shot suspension point for race tests: `wait()` suspends until `open()`.
public actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
