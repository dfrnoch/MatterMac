public import Foundation
public import MatterMacModels

/// Production `MattermostService`: the authenticated REST surface for one account
/// session on one server (SPEC §8, §9, §12, §14). Endpoints, parameters and quirks
/// follow docs/research/{auth,channels,posts}.md (verified against server source
/// v11.11.1 and v10.11.24).
///
/// Every call goes through `RequestPipeline` (GET coalescing, safe-read retry,
/// per-server/global admission) and a bounded transport. Responses are decoded with
/// `WireJSON.decoder()` from bodies capped at `budget.apiResponseBytes` (lists) or
/// `budget.smallResponseBytes` (single entities, config, status replies).
///
/// Lifetime: create through `DefaultMattermostServiceFactory`; call `shutdown()` at
/// sign-out (after an optional `logout()`). Shutdown cancels queued and in-flight
/// work, invalidates the URLSession and releases the credential's transport.
public final class MattermostHTTPClient: MattermostService {
    public let endpoint: ServerEndpoint
    private let credential: BearerCredential
    private let pipeline: RequestPipeline
    private let budget: ResourceBudget

    /// Largest id batch per request for `POST /users/ids`, `/users/status/ids`,
    /// `/posts/ids`.
    public static let idBatchSize = 200
    /// `per_page` bounds for history, threads and search.
    public static let pageSizeRange = 1...200

    init(endpoint: ServerEndpoint, credential: BearerCredential, pipeline: RequestPipeline, budget: ResourceBudget) {
        self.endpoint = endpoint
        self.credential = credential
        self.pipeline = pipeline
        self.budget = budget
    }

    public func shutdown() async {
        await pipeline.shutdown()
    }

    // MARK: Identity and configuration

    public func currentUser() async throws(APIError) -> User {
        try await get(UserWire.self, ["users", "me"], limit: small, priority: .interactive).user
    }

    public func fullConfiguration() async throws(APIError) -> ClientConfigWire {
        try await get(ClientConfigWire.self, ["config", "client"], query: [URLQueryItem(name: "format", value: "old")],
                      limit: small, priority: .interactive)
    }

    public func logout() async throws(APIError) {
        _ = try await perform(.post, ["users", "logout"], limit: small, priority: .interactive)
    }

    public func preferences() async throws(APIError) -> [Preference] {
        try await get(PreferenceListWire.self, ["users", "me", "preferences"], limit: large, priority: .interactive)
            .preferences
    }

    public func savePreferences(_ preferences: [Preference], me: UserID) async throws(APIError) {
        guard !preferences.isEmpty else { return }
        guard preferences.count <= 100 else { throw .overloaded }
        _ = try await perform(.put, ["users", me.rawValue, "preferences"],
                              body: try RequestBodyEncoding.encode(Self.preferenceBodies(preferences, me: me)),
                              limit: small, priority: .interactive)
    }

    public func deletePreferences(_ preferences: [Preference], me: UserID) async throws(APIError) {
        guard !preferences.isEmpty else { return }
        guard preferences.count <= 100 else { throw .overloaded }
        _ = try await perform(.post, ["users", me.rawValue, "preferences", "delete"],
                              body: try RequestBodyEncoding.encode(Self.preferenceBodies(preferences, me: me)),
                              limit: small, priority: .interactive)
    }

    private static func preferenceBodies(_ preferences: [Preference], me: UserID) -> [PreferenceBody] {
        preferences.map { PreferenceBody(user_id: me.rawValue, category: $0.category, name: $0.name, value: $0.value) }
    }

    // MARK: Teams and channels

    public func teams() async throws(APIError) -> [Team] {
        try await get(LossyArray<TeamWire>.self, ["users", "me", "teams"], limit: large, priority: .interactive)
            .elements.map(\.team)
    }

    public func teamMemberships() async throws(APIError) -> [TeamMemberWire] {
        // The server includes deleted memberships here; keep active ones only.
        try await get(LossyArray<TeamMemberWire>.self, ["users", "me", "teams", "members"], limit: large,
                      priority: .interactive)
            .elements.filter(\.deleteAt.isZero)
    }

    public func channels(team: TeamID) async throws(APIError) -> [Channel] {
        do {
            return try await get(LossyArray<ChannelWire>.self, ["users", "me", "teams", team.rawValue, "channels"],
                                 limit: large, priority: .interactive)
                .elements.map(\.channel).filter(Self.isMessageChannel)
        } catch {
            // Zero channels is reported as this specific 404; it means "empty".
            if case .notFound(let info) = error, info.id == ServerErrorID.channelsNotFound { return [] }
            throw error
        }
    }

    public func channelMemberships(team: TeamID) async throws(APIError) -> [ChannelMembership] {
        try await get(LossyArray<ChannelMemberWire>.self,
                      ["users", "me", "teams", team.rawValue, "channels", "members"], limit: large, priority: .interactive)
            .elements.map(\.membership)
    }

    public func channel(_ id: ChannelID) async throws(APIError) -> Channel {
        try await get(ChannelWire.self, ["channels", id.rawValue], limit: small, priority: .interactive).channel
    }

    public func channelMembership(_ id: ChannelID) async throws(APIError) -> ChannelMembership {
        try await get(ChannelMemberWire.self, ["channels", id.rawValue, "members", "me"], limit: small,
                      priority: .interactive).membership
    }

    public func channelStats(_ id: ChannelID) async throws(APIError) -> ChannelStats {
        let wire = try await get(ChannelStatsWire.self, ["channels", id.rawValue, "stats"],
                                 query: [URLQueryItem(name: "exclude_files_count", value: "true")], limit: small,
                                 priority: .interactive)
        return ChannelStats(memberCount: wire.memberCount, pinnedPostCount: wire.pinnedPostCount)
    }

    public func channelMembers(_ id: ChannelID, page: Int, perPage: Int) async throws(APIError) -> [User] {
        let size = min(max(perPage, 1), Self.pageSizeRange.upperBound)
        return try await get(LossyArray<UserWire>.self, ["users"], query: [
            URLQueryItem(name: "in_channel", value: id.rawValue),
            URLQueryItem(name: "page", value: String(max(0, page))),
            URLQueryItem(name: "per_page", value: String(size)),
            URLQueryItem(name: "active", value: "true"),
        ], limit: large, priority: .interactive).elements.map(\.user)
    }

    public func setChannelMarkUnread(_ id: ChannelID, level: MarkUnreadLevel, me: UserID) async throws(APIError) {
        let body = ChannelNotifyPropsBody(channel_id: id.rawValue, user_id: me.rawValue,
                                          mark_unread: level == .mention ? "mention" : "all")
        _ = try await perform(.put, ["channels", id.rawValue, "members", me.rawValue, "notify_props"],
                              body: try RequestBodyEncoding.encode(body), limit: small, priority: .interactive)
    }

    public func createDirectChannel(with other: UserID, me: UserID) async throws(APIError) -> Channel {
        let ids = other == me ? [me.rawValue] : [me.rawValue, other.rawValue]
        return try await send(.post, ["channels", "direct"], body: ids, decode: ChannelWire.self, limit: small).channel
    }

    public func joinChannel(_ id: ChannelID, me: UserID) async throws(APIError) {
        _ = try await perform(.post, ["channels", id.rawValue, "members"],
                              body: try RequestBodyEncoding.encode(AddChannelMemberBody(user_id: me.rawValue)),
                              limit: small, priority: .interactive)
    }

    public func leaveChannel(_ id: ChannelID, me: UserID) async throws(APIError) {
        _ = try await perform(.delete, ["channels", id.rawValue, "members", me.rawValue], limit: small,
                              priority: .interactive)
    }

    public func viewChannel(_ id: ChannelID?, previous: ChannelID?, collapsedThreadsSupported: Bool)
        async throws(APIError) -> [ChannelID: MattermostTimestamp] {
        let body = ViewChannelBody(channel_id: id?.rawValue ?? "", prev_channel_id: previous?.rawValue ?? "",
                                   collapsed_threads_supported: collapsedThreadsSupported)
        return try await send(.post, ["channels", "members", "me", "view"], body: body,
                              decode: ChannelViewResponseWire.self, limit: small).lastViewedAt
    }

    public func searchChannels(team: TeamID, term: String) async throws(APIError) -> [Channel] {
        try await send(.post, ["teams", team.rawValue, "channels", "search"], body: ChannelSearchBody(term: term),
                       decode: LossyArray<ChannelWire>.self, limit: large)
            .elements.map(\.channel).filter(Self.isMessageChannel)
    }

    /// v11 adds non-message channel types (`S`, `BO`, `BP`); they are not shown.
    static func isMessageChannel(_ channel: Channel) -> Bool {
        if case .unknown = channel.type { return false }
        return true
    }

    // MARK: Sidebar categories, browsing and membership

    public func sidebarCategories(team: TeamID, me: UserID) async throws(APIError) -> [SidebarCategory] {
        try await get(OrderedSidebarCategoriesWire.self, ["users", me.rawValue, "teams", team.rawValue, "channels", "categories"],
                      limit: large, priority: .interactive).categories
    }

    public func sidebarCategory(_ id: SidebarCategoryID, team: TeamID, me: UserID) async throws(APIError) -> SidebarCategory {
        try await get(SidebarCategoryWire.self,
                      ["users", me.rawValue, "teams", team.rawValue, "channels", "categories", id.rawValue],
                      limit: large, priority: .interactive).category
    }

    public func updateSidebarCategory(_ category: SidebarCategory) async throws(APIError) -> SidebarCategory {
        guard category.droppedChannelIDs == 0 else { throw .badRequest(Self.clientError("mattermac.client.unreadable_category")) }
        return try await send(.put, ["users", category.userID.rawValue, "teams", category.teamID.rawValue, "channels",
                                     "categories", category.id.rawValue],
                              body: SidebarCategoryBody(category), decode: SidebarCategoryWire.self, limit: large).category
    }

    public func teamUnreads(includeCollapsedThreads: Bool) async throws(APIError) -> [TeamUnread] {
        var query: [URLQueryItem] = []
        if includeCollapsedThreads { query.append(URLQueryItem(name: "include_collapsed_threads", value: "true")) }
        return try await get(LossyArray<TeamUnreadWire>.self, ["users", "me", "teams", "unread"], query: query,
                             limit: large, priority: .background).elements.map(\.unread)
    }

    public func publicChannels(team: TeamID, page: Int, perPage: Int) async throws(APIError) -> [Channel] {
        try await get(LossyArray<ChannelWire>.self, ["teams", team.rawValue, "channels"],
                      query: Self.pageQuery(page: page, perPage: perPage), limit: large, priority: .interactive)
            .elements.map(\.channel).filter(Self.isMessageChannel)
    }

    public func archivedChannels(team: TeamID, page: Int, perPage: Int) async throws(APIError) -> [Channel] {
        do {
            return try await get(LossyArray<ChannelWire>.self, ["teams", team.rawValue, "channels", "deleted"],
                                 query: Self.pageQuery(page: page, perPage: perPage), limit: large, priority: .interactive)
                .elements.map(\.channel).filter(Self.isMessageChannel)
        } catch {
            if case .notFound(let info) = error, info.id == ServerErrorID.deletedChannelsNotFound { return [] }
            throw error
        }
    }

    /// `DELETE /channels/{id}` (archive; `permanent` needs an administrator and
    /// `EnableAPIChannelDeletion`). Not exposed in the app; live-test cleanup only.
    func deleteChannel(_ id: ChannelID, permanent: Bool) async throws(APIError) {
        _ = try await perform(.delete, ["channels", id.rawValue],
                              query: permanent ? [URLQueryItem(name: "permanent", value: "true")] : [],
                              limit: small, priority: .interactive)
    }

    static func pageQuery(page: Int, perPage: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(max(0, page))),
         URLQueryItem(name: "per_page", value: String(clampPage(perPage)))]
    }

    public func channelMemberCounts(_ ids: [ChannelID]) async throws(APIError) -> [ChannelID: Int] {
        var result: [ChannelID: Int] = [:]
        for chunk in Self.uniqueChunks(ids.map(\.rawValue)) {
            let wire = try await send(.post, ["channels", "stats", "member_count"], body: chunk,
                                      decode: ChannelMemberCountsWire.self, limit: small, priority: .background)
            result.merge(wire.counts) { first, _ in first }
        }
        return result
    }

    public func createChannel(_ request: NewChannelRequest) async throws(APIError) -> Channel {
        guard ChannelNameRules.problem(with: request.name) == nil else {
            throw .badRequest(Self.clientError("mattermac.client.invalid_channel_name"))
        }
        let body = CreateChannelBody(team_id: request.team.rawValue, name: request.name,
                                     display_name: request.displayName, purpose: request.purpose,
                                     type: request.isPrivate ? "P" : "O")
        return try await send(.post, ["channels"], body: body, decode: ChannelWire.self, limit: small).channel
    }

    public func createGroupChannel(with users: [UserID]) async throws(APIError) -> Channel {
        try await send(.post, ["channels", "group"], body: users.map(\.rawValue), decode: ChannelWire.self,
                       limit: small).channel
    }

    public func addChannelMembers(_ id: ChannelID, users: [UserID]) async throws(APIError) {
        guard !users.isEmpty else { return }
        guard users.count <= 1_000 else { throw .overloaded }
        let body = users.count == 1
            ? AddChannelMembersBody(user_id: users[0].rawValue, user_ids: nil)
            : AddChannelMembersBody(user_id: nil, user_ids: users.map(\.rawValue))
        _ = try await perform(.post, ["channels", id.rawValue, "members"], body: try RequestBodyEncoding.encode(body),
                              limit: large, priority: .interactive)
    }

    public func searchUsers(_ query: UserSearchQuery) async throws(APIError) -> [User] {
        let term = String(query.term.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !term.isEmpty else { return [] }
        let body = UserSearchBody(term: term, team_id: query.team.rawValue, not_in_channel_id: query.notInChannel?.rawValue,
                                  allow_inactive: false, limit: min(max(query.limit, 1), 100))
        return try await send(.post, ["users", "search"], body: body, decode: LossyArray<UserWire>.self, limit: large)
            .elements.map(\.user)
    }

    // MARK: Posts

    public func posts(channel: ChannelID, query: PostPageQuery, collapsedThreads: Bool, priority: RequestPriority)
        async throws(APIError) -> PostPage {
        try await get(PostListWire.self, ["channels", channel.rawValue, "posts"],
                      query: Self.postPageQueryItems(query, collapsedThreads: collapsedThreads), limit: large,
                      priority: priority).page
    }

    /// Query items for `GET /channels/{id}/posts`. `since` is never sent (it is not
    /// interchangeable with anchored pagination), `before`/`after` are exclusive, and
    /// booleans are sent only as the literal `"true"` (v10 accepts nothing else).
    static func postPageQueryItems(_ query: PostPageQuery, collapsedThreads: Bool) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "page", value: "0")]
        switch query {
        case .latest(let perPage):
            items.append(URLQueryItem(name: "per_page", value: String(clampPage(perPage))))
        case .before(let id, let perPage):
            items.append(URLQueryItem(name: "per_page", value: String(clampPage(perPage))))
            items.append(URLQueryItem(name: "before", value: id.rawValue))
        case .after(let id, let perPage):
            items.append(URLQueryItem(name: "per_page", value: String(clampPage(perPage))))
            items.append(URLQueryItem(name: "after", value: id.rawValue))
        }
        // Only the root of each reply, not whole threads, keeps pages bounded (and the
        // non-CRT page query computes reply_count only in this mode).
        items.append(URLQueryItem(name: "skipFetchThreads", value: "true"))
        if collapsedThreads { items.append(URLQueryItem(name: "collapsedThreads", value: "true")) }
        return items
    }

    static func clampPage(_ value: Int) -> Int {
        min(max(value, pageSizeRange.lowerBound), pageSizeRange.upperBound)
    }

    public func postsAroundLastUnread(channel: ChannelID, me: UserID, limitBefore: Int, limitAfter: Int,
                                      collapsedThreads: Bool) async throws(APIError) -> PostPage {
        var query = [
            URLQueryItem(name: "limit_before", value: String(min(max(limitBefore, 0), 200))),
            // limit_after=0 is a 400 on both release lines.
            URLQueryItem(name: "limit_after", value: String(min(max(limitAfter, 1), 200))),
            URLQueryItem(name: "skipFetchThreads", value: "true"),
        ]
        if collapsedThreads { query.append(URLQueryItem(name: "collapsedThreads", value: "true")) }
        return try await get(PostListWire.self, ["users", me.rawValue, "channels", channel.rawValue, "posts", "unread"],
                             query: query, limit: large, priority: .interactive).page
    }

    public func thread(root: PostID, query: ThreadPageQuery) async throws(APIError) -> PostPage {
        try await get(PostListWire.self, ["posts", root.rawValue, "thread"], query: Self.threadQueryItems(query),
                      limit: large, priority: .interactive).page
    }

    /// `perPage` 1...200 (the server rejects >200 and treats 0 as "everything"),
    /// always `direction=down`, `fromPost` + `fromCreateAt` for continuation.
    static func threadQueryItems(_ query: ThreadPageQuery) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "perPage", value: String(clampPage(query.perPage))),
            URLQueryItem(name: "direction", value: "down"),
        ]
        if let after = query.after {
            items.append(URLQueryItem(name: "fromPost", value: after.postID.rawValue))
            items.append(URLQueryItem(name: "fromCreateAt", value: String(after.createAt.milliseconds)))
        }
        if query.collapsedThreads { items.append(URLQueryItem(name: "collapsedThreads", value: "true")) }
        return items
    }

    public func post(_ id: PostID) async throws(APIError) -> Post {
        try await get(PostWire.self, ["posts", id.rawValue], limit: small, priority: .interactive).post
    }

    public func posts(ids: [PostID]) async throws(APIError) -> [Post] {
        var result: [Post] = []
        for chunk in Self.uniqueChunks(ids.map(\.rawValue)) {
            do {
                let list = try await send(.post, ["posts", "ids"], body: chunk, decode: LossyArray<PostWire>.self,
                                          limit: large, priority: .background)
                result.append(contentsOf: list.elements.filter { !$0.isEditHistoryRow }.map(\.post))
            } catch {
                // 404 means none of this batch is visible (deleted permanently or
                // inaccessible); other batches are still reported.
                if case .notFound = error { continue }
                throw error
            }
        }
        return result
    }

    public func createPost(_ post: OutgoingPost) async throws(APIError) -> Post {
        let body = CreatePostBody(channel_id: post.channelID.rawValue, message: post.message, root_id: post.rootID?.rawValue,
                                  file_ids: post.fileIDs.map(\.rawValue), pending_post_id: post.pendingPostID.rawValue)
        return try await send(.post, ["posts"], body: body, decode: PostWire.self, limit: small).post
    }

    public func editPost(_ id: PostID, message: String) async throws(APIError) -> Post {
        try await send(.put, ["posts", id.rawValue, "patch"], body: PatchPostBody(message: message), decode: PostWire.self,
                       limit: small).post
    }

    public func deletePost(_ id: PostID) async throws(APIError) {
        _ = try await perform(.delete, ["posts", id.rawValue], limit: small, priority: .interactive)
    }

    public func addReaction(post: PostID, emojiName: String, me: UserID) async throws(APIError) -> Reaction {
        let name = try Self.validatedEmojiName(emojiName)
        let body = ReactionBody(user_id: me.rawValue, post_id: post.rawValue, emoji_name: name)
        return try await send(.post, ["reactions"], body: body, decode: ReactionWire.self, limit: small).reaction
    }

    public func removeReaction(post: PostID, emojiName: String, me: UserID) async throws(APIError) {
        let name = try Self.validatedEmojiName(emojiName)
        // `+` stays literal in the path (the route regex is [A-Za-z0-9_\-+]+).
        _ = try await perform(.delete, ["users", me.rawValue, "posts", post.rawValue, "reactions", name], limit: small,
                              priority: .interactive)
    }

    /// v11 lowercases emoji names server-side, v10 does not (mixed case fails the
    /// system-emoji lookup), so names are always sent lowercase.
    static func validatedEmojiName(_ raw: String) throws(APIError) -> String {
        guard Reaction.isValidEmojiName(raw) else { throw .badRequest(Self.clientError("mattermac.client.invalid_emoji_name")) }
        return raw.lowercased()
    }

    public func searchPosts(_ query: SearchQuery) async throws(APIError) -> PostPage {
        let perPage = min(Self.clampPage(query.perPage), max(1, budget.searchResults.count))
        let body = PostSearchBody(terms: query.terms, is_or_search: query.isOrSearch,
                                  time_zone_offset: query.timeZoneOffsetSeconds, page: max(0, query.page), per_page: perPage,
                                  include_deleted_channels: false)
        return try await send(.post, ["teams", query.team.rawValue, "posts", "search"], body: body,
                              decode: PostListWire.self, limit: large).page
    }

    // MARK: Users

    public func users(ids: [UserID]) async throws(APIError) -> [User] {
        var result: [User] = []
        for chunk in Self.uniqueChunks(ids.map(\.rawValue)) {
            let list = try await send(.post, ["users", "ids"], body: chunk, decode: LossyArray<UserWire>.self, limit: large,
                                      priority: .background)
            result.append(contentsOf: list.elements.map(\.user))
        }
        return result
    }

    public func statuses(ids: [UserID]) async throws(APIError) -> [UserID: PresenceStatus] {
        // The server rejects the whole request unless every id is exactly 26 chars.
        let valid = ids.map(\.rawValue).filter { $0.utf8.count == 26 }
        var result: [UserID: PresenceStatus] = [:]
        for chunk in Self.uniqueChunks(valid) {
            let list = try await send(.post, ["users", "status", "ids"], body: chunk, decode: LossyArray<StatusWire>.self,
                                      limit: large, priority: .background)
            for status in list.elements { result[status.userID] = status.status }
        }
        return result
    }

    public func executeCommand(_ command: String, channel: ChannelID, team: TeamID?, rootID: PostID?)
        async throws(APIError) -> CommandResult {
        let body = ExecuteCommandBody(channel_id: channel.rawValue, team_id: team?.rawValue ?? "",
                                      root_id: rootID?.rawValue ?? "", command: command)
        return try await send(.post, ["commands", "execute"], body: body, decode: CommandResponseWire.self,
                              limit: small).result
    }

    public func setStatus(_ status: PresenceStatus, me: UserID) async throws(APIError) {
        guard let value = status.wireValue else { throw .malformedResponse }
        _ = try await perform(.put, ["users", me.rawValue, "status"],
                              body: try RequestBodyEncoding.encode(StatusBody(user_id: me.rawValue, status: value)),
                              limit: small, priority: .interactive)
    }

    public func setCustomStatus(_ status: CustomStatus?, duration: String, me: UserID) async throws(APIError) {
        guard let status else {
            _ = try await perform(.delete, ["users", me.rawValue, "status", "custom"], limit: small, priority: .interactive)
            return
        }
        let body = CustomStatusBody(emoji: String(status.emoji.prefix(64)), text: String(status.text.prefix(100)),
                                    duration: duration,
                                    expires_at: status.expiresAt.map { $0.formatted(.iso8601) })
        _ = try await perform(.put, ["users", me.rawValue, "status", "custom"],
                              body: try RequestBodyEncoding.encode(body), limit: small, priority: .interactive)
    }

    public func users(usernames: [String]) async throws(APIError) -> [User] {
        var result: [User] = []
        for chunk in Self.uniqueChunks(usernames.map { $0.lowercased() }.filter { !$0.isEmpty && $0.utf8.count <= 64 }) {
            let list = try await send(.post, ["users", "usernames"], body: chunk, decode: LossyArray<UserWire>.self,
                                      limit: large, priority: .interactive)
            result.append(contentsOf: list.elements.map(\.user))
        }
        return result
    }

    public func autocompleteUsers(team: TeamID, channel: ChannelID?, name: String, limit: Int)
        async throws(APIError) -> [User] {
        let bounded = min(max(limit, 1), Self.pageSizeRange.upperBound)
        // `in_channel` requires `in_team` (else a 500 on both release lines); the team
        // is always sent.
        var query = [URLQueryItem(name: "in_team", value: team.rawValue)]
        if let channel { query.append(URLQueryItem(name: "in_channel", value: channel.rawValue)) }
        query.append(URLQueryItem(name: "name", value: name))
        query.append(URLQueryItem(name: "limit", value: String(bounded)))
        let wire = try await get(UserAutocompleteWire.self, ["users", "autocomplete"], query: query, limit: large,
                                 priority: .interactive)
        // Channel members first, then team members outside the channel (mentionable).
        var seen = Set<UserID>()
        var users: [User] = []
        for user in wire.users + wire.outOfChannel where users.count < bounded && seen.insert(user.id).inserted {
            users.append(user)
        }
        return users
    }

    // MARK: Files and media

    public func fileInfo(_ id: FileID) async throws(APIError) -> FileInfo {
        try await get(FileInfoWire.self, ["files", id.rawValue, "info"], limit: small, priority: .background).info
    }

    public func imageData(_ resource: ImageResource, maximumBytes: Int) async throws(APIError) -> Data {
        let (segments, query) = try Self.imagePath(resource)
        let limit = min(max(0, maximumBytes), budget.apiResponseBytes)
        let request = HTTPRequest(method: .get, url: apiURL(segments, query), headers: ["Accept": "image/*"],
                                  credential: credential)
        let response = try await pipeline.execute(request, priority: .background,
                                                  limits: ResponseLimits(maximumBodyBytes: limit))
        guard let type = response.mediaType, type.hasPrefix("image/") else { throw .malformedResponse }
        return response.body
    }

    static func imagePath(_ resource: ImageResource) throws(APIError) -> ([String], [URLQueryItem]) {
        switch resource {
        case .profileImage(let user, let revision):
            // `_` is only a cache-buster (matches the web client).
            return (["users", user.rawValue, "image"], [URLQueryItem(name: "_", value: String(revision))])
        case .fileThumbnail(let id):
            return (["files", id.rawValue, "thumbnail"], [])
        case .filePreview(let id):
            return (["files", id.rawValue, "preview"], [])
        case .customEmoji(let id):
            guard IdentifierValidation.isValid(id) else { throw .badRequest(clientError("mattermac.client.invalid_emoji_id")) }
            return (["emoji", id, "image"], [])
        case .teamIcon(let team, let revision):
            return (["teams", team.rawValue, "image"], [URLQueryItem(name: "_", value: String(revision))])
        }
    }

    /// Raw-body upload: `POST /files?channel_id=&filename=&client_id=` streaming the
    /// user-selected file directly (no multipart assembly, no staging copy). The
    /// server's reported size must equal the local size; otherwise the upload is
    /// reported as `.localFileUnavailable` (the orphaned server file is left for the
    /// server's own cleanup — there is no client cleanup endpoint).
    public func upload(_ source: UploadSource, channel: ChannelID, clientID: String,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> FileInfo {
        guard let fileName = Self.uploadFileName(source.fileName) else {
            throw .badRequest(Self.clientError("mattermac.client.invalid_file_name"))
        }
        guard Self.isValidClientID(clientID) else { throw .badRequest(Self.clientError("mattermac.client.invalid_client_id")) }
        let url = apiURL(["files"], [
            URLQueryItem(name: "channel_id", value: channel.rawValue),
            URLQueryItem(name: "filename", value: fileName),
            URLQueryItem(name: "client_id", value: clientID),
        ])
        let request = HTTPRequest(method: .post, url: url, headers: ["Content-Type": "application/octet-stream"],
                                  credential: credential, timeout: HTTPRequest.transferTimeout, allowsRedirects: false)
        let transport = pipeline.transport
        let limits = ResponseLimits(maximumBodyBytes: budget.smallResponseBytes)
        let response = try await pipeline.transfer { () async throws(APIError) -> HTTPResponse in
            switch source.content {
            case .file(let url, let revision):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try await transport.upload(request, file: UploadFile(url: url, expectedLength: source.expectedSize,
                    expectedRevision: revision), limits: limits, progress: progress)
            case .memory(let memory):
                defer { withExtendedLifetime(memory) {} }
                let data = memory.data
                guard data.count <= budget.pastedImageBytes else { throw .responseTooLarge(limitBytes: budget.pastedImageBytes) }
                var request = request
                request.body = data
                request.headers.set("Content-Length", String(data.count))
                return try await transport.send(request, limits: limits)
            }
        }
        if let error = HTTPStatusMapping.error(for: response) { throw error }
        let wire: FileUploadResponseWire = try Self.decode(response.body)
        guard let info = wire.fileInfos.first else { throw .malformedResponse }
        guard info.size == source.expectedSize else { throw .localFileUnavailable }
        return info
    }

    /// The server stores the name it is given; send only the last path component,
    /// without control characters, bounded.
    static func uploadFileName(_ raw: String) -> String? {
        let last = raw.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", trimmed.utf8.count <= 1_024 else { return nil }
        return trimmed
    }

    static func isValidClientID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f }
    }

    /// `GET /files/{id}?download=1` streamed in ≤ 64 KiB writes into a partial file
    /// next to `destination`, then atomically renamed into place (see
    /// `DownloadStaging`). Memory stays bounded by URLSession's delivery chunks.
    public func download(_ id: FileID, to destination: URL,
                         progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) {
        guard pipeline.isOpen else { throw .cancelled }
        let request = HTTPRequest(method: .get, url: apiURL(["files", id.rawValue], [URLQueryItem(name: "download", value: "1")]),
                                  headers: ["Accept": "*/*"], credential: credential, timeout: HTTPRequest.transferTimeout)
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let staging = try DownloadStaging.prepare(destination: destination)
        let transport = pipeline.transport
        let handle = staging.handle
        do throws(APIError) {
            let response = try await pipeline.transfer { () async throws(APIError) -> HTTPResponse in
                try await transport.download(request, to: handle, limits: ResponseLimits(maximumBodyBytes: Int64.max),
                                             progress: progress)
            }
            if let error = HTTPStatusMapping.error(for: response) { throw error }
            guard !Task.isCancelled else { throw .cancelled }
            try staging.commit()
        } catch {
            staging.discard()
            throw error
        }
    }

    // MARK: Request helpers

    private var small: Int { budget.smallResponseBytes }
    private var large: Int { budget.apiResponseBytes }

    private func apiURL(_ segments: [String], _ query: [URLQueryItem] = []) -> URL {
        endpoint.url(path: ["api", "v4"] + segments, query: query)
    }

    private func get<T: Decodable>(_ type: T.Type, _ segments: [String], query: [URLQueryItem] = [], limit: Int,
                                   priority: RequestPriority) async throws(APIError) -> T {
        let response = try await perform(.get, segments, query: query, limit: limit, priority: priority)
        return try Self.decode(response.body)
    }

    private func send<Body: Encodable, T: Decodable>(_ method: HTTPMethod, _ segments: [String], body: Body,
                                                     decode type: T.Type, limit: Int,
                                                     priority: RequestPriority = .interactive) async throws(APIError) -> T {
        let data = try RequestBodyEncoding.encode(body)
        let response = try await perform(method, segments, body: data, limit: limit, priority: priority)
        return try Self.decode(response.body)
    }

    private func perform(_ method: HTTPMethod, _ segments: [String], query: [URLQueryItem] = [], body: Data? = nil,
                         limit: Int, priority: RequestPriority) async throws(APIError) -> HTTPResponse {
        let request = HTTPRequest(method: method, url: apiURL(segments, query), body: body, credential: credential)
        return try await pipeline.execute(request, priority: priority, limits: ResponseLimits(maximumBodyBytes: limit))
    }

    static func decode<T: Decodable>(_ data: Data) throws(APIError) -> T {
        do {
            return try WireJSON.decoder().decode(T.self, from: data)
        } catch {
            throw .malformedResponse
        }
    }

    /// Client-side validation failures use ids in the `mattermac.client.` namespace
    /// with status 0 (no request was sent).
    static func clientError(_ id: String) -> ServerErrorInfo {
        ServerErrorInfo(id: id, statusCode: 0, requestID: nil)
    }

    /// Splits into de-duplicated batches of at most `idBatchSize`, preserving order.
    static func uniqueChunks(_ ids: [String]) -> [[String]] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: idBatchSize).map {
            Array(unique[$0..<min($0 + idBatchSize, unique.count)])
        }
    }
}

extension PostListWire {
    var page: PostPage { PostPage(wire: self) }
}
