import Foundation
public import MatterMacModels
import MattermostAPI

/// A message as plain data, for the assistant's day summary and for agent control.
public struct PlainPost: Hashable, Sendable {
    public var id: PostID
    public var channelID: ChannelID
    public var rootID: PostID?
    public var userID: UserID
    public var username: String
    public var displayName: String
    public var createdAt: MattermostTimestamp
    public var message: String
    public var fileCount: Int
    public var replyCount: Int
    public var isSystem: Bool
}

public struct PlainChannel: Hashable, Sendable {
    public var id: ChannelID
    /// URL name (`town-square`); for direct messages the partner's `@username`.
    public var name: String
    public var displayName: String
    /// `public`, `private`, `direct` or `group`.
    public var kind: String
    public var team: String?
    public var unreadMessages: Int64
    public var mentions: Int64
    public var lastPostAt: MattermostTimestamp
}

/// What happened to a message handed to `sendPlain`.
public enum PlainSendResult: Hashable, Sendable {
    /// The server confirmed it.
    case sent(PostID)
    /// Still in the send queue (shown as pending in the app).
    case queued(PendingPostID)
    /// Refused before queuing (empty, too long, archived channel, unsent-text budget).
    case rejected(ServerSession.SendRejection)
    case failed(UserFacingError)
    /// The request may or may not have arrived; the app shows it for the user to decide.
    case outcomeUnknown(PendingPostID)
}

/// Read and send by plain values, without opening windows: nothing here changes which
/// conversation is shown or marks anything read. Results are bounded by `limit`.
extension ServerSession {
    public static let plainPageLimit = 200

    public func plainChannels() -> [PlainChannel] {
        guard isActiveSessionAlive else { return [] }
        let crt = collapsedThreadsActive
        return directory.channels.values.compactMap { channel -> PlainChannel? in
            guard directory.memberships[channel.id] != nil, !channel.isArchived else { return nil }
            let unread = directory.unread(for: channel.id, collapsedThreads: crt)
            let kind: String
            var name = channel.name
            switch channel.type {
            case .open: kind = "public"
            case .private: kind = "private"
            case .group: kind = "group"
            case .direct:
                kind = "direct"
                if let partner = channel.directPartner(of: me.id), let user = directory.peekUser(partner) {
                    name = "@" + user.username
                }
            case .unknown: kind = "other"
            }
            return PlainChannel(id: channel.id, name: name, displayName: displayName(of: channel), kind: kind,
                                team: channel.teamID.flatMap { directory.teams[$0]?.name },
                                unreadMessages: unread.isUnread ? max(unread.messages, 1) : 0, mentions: unread.mentions,
                                lastPostAt: channel.lastPostAt)
        }
        .sorted { $0.lastPostAt > $1.lastPostAt }
    }

    /// A channel by id, URL name, display name, or `@username` (the direct message
    /// with that person, opened if needed).
    public func resolvePlainChannel(_ reference: String) async throws(UserFacingError) -> ChannelID {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 256 else { throw .notFoundOrInaccessible }
        if let id = ChannelID(rawValue: text), directory.memberships[id] != nil { return id }
        if text.hasPrefix("@") {
            let username = String(text.dropFirst()).lowercased()
            var user = directory.peekUsers(usernames: [username])[username]
            if user == nil {
                do { user = try await service.users(usernames: [username]).first } catch { throw Self.userFacing(error) }
            }
            guard let user else { throw .notFoundOrInaccessible }
            return try await directMessageChannel(with: user.id)
        }
        let name = text.hasPrefix("#") || text.hasPrefix("~") ? String(text.dropFirst()) : text
        let channels = plainChannels()
        if let match = channels.first(where: { $0.name == name.lowercased() }) { return match.id }
        let lowered = name.lowercased()
        let byTitle = channels.filter { $0.displayName.lowercased() == lowered }
        // An ambiguous display name is not guessed.
        if byTitle.count == 1 { return byTitle[0].id }
        throw .notFoundOrInaccessible
    }

    /// The newest `limit` posts of a channel (or those before `before`), oldest first.
    public func plainPosts(channel: ChannelID, limit: Int, before: PostID? = nil,
                           background: Bool = false) async throws(UserFacingError) -> [PlainPost] {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard directory.memberships[channel] != nil else { throw .notFoundOrInaccessible }
        let count = min(max(limit, 1), Self.plainPageLimit)
        let page: PostPage
        do {
            page = try await service.posts(channel: channel,
                                           query: before.map { .before($0, perPage: count) } ?? .latest(perPage: count),
                                           collapsedThreads: false, priority: background ? .background : .interactive)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        return try await plain(page.posts.filter { $0.channelID == channel })
    }

    /// A whole thread (root first), up to `plainPageLimit` posts.
    public func plainThread(root: PostID) async throws(UserFacingError) -> [PlainPost] {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let page: PostPage
        do {
            page = try await service.thread(root: root, query: ThreadPageQuery(perPage: Self.plainPageLimit,
                                                                              collapsedThreads: false))
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        let posts = page.posts.filter { directory.memberships[$0.channelID] != nil }
        guard !posts.isEmpty else { throw .notFoundOrInaccessible }
        return try await plain(posts)
    }

    /// The thread a post belongs to (itself when it is a root) and its channel.
    public func plainThreadRoot(of id: PostID) async throws(UserFacingError) -> (root: PostID, channel: ChannelID) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        var post = store.post(id)
        if post == nil {
            do { post = try await service.post(id) } catch {
                handleAuthenticationFailureIfNeeded(error)
                throw Self.userFacing(error)
            }
        }
        guard let post, !post.isDeleted, directory.memberships[post.channelID] != nil else { throw .notFoundOrInaccessible }
        return (post.rootID ?? post.id, post.channelID)
    }

    public func plainSearch(_ terms: String, limit: Int) async throws(UserFacingError) -> [PlainPost] {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let team = selectedTeam else { throw .notFoundOrInaccessible }
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return [] }
        let page: PostPage
        do {
            page = try await service.searchPosts(SearchQuery(
                team: team, terms: trimmed, timeZoneOffsetSeconds: deps.timeZone().secondsFromGMT(),
                perPage: min(max(limit, 1), 100)))
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        return try await plain(page.posts.filter { directory.memberships[$0.channelID] != nil })
    }

    /// The signed-in user's own recent messages across their conversations, newest
    /// first (`from:username` search, a page of 100 at a time): what the assistant
    /// learns their writing style from.
    public func ownRecentMessages(limit: Int) async throws(UserFacingError) -> [String] {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let team = selectedTeam else { throw .notFoundOrInaccessible }
        var messages: [(at: MattermostTimestamp, text: String)] = []
        var seen = Set<PostID>()
        for page in 0..<max(1, min((limit + 99) / 100, 5)) {
            let result: PostPage
            do {
                result = try await service.searchPosts(SearchQuery(
                    team: team, terms: "from:" + me.username, timeZoneOffsetSeconds: deps.timeZone().secondsFromGMT(),
                    page: page, perPage: 100))
            } catch {
                handleAuthenticationFailureIfNeeded(error)
                throw Self.userFacing(error)
            }
            guard isActiveSessionAlive, !Task.isCancelled else { throw .cancelled }
            let own = result.posts.filter { $0.userID == me.id && !$0.type.isSystem && !$0.isDeleted && !$0.message.isEmpty }
            for post in own where seen.insert(post.id).inserted { messages.append((post.createAt, post.message)) }
            if result.posts.count < 100 || messages.count >= limit { break }
        }
        return messages.sorted { $0.at > $1.at }.prefix(limit).map(\.text)
    }

    /// Queues a message like the composer does (same validation, pending queue and
    /// retry rules), then waits briefly to report whether the server confirmed it.
    public func sendPlain(text: String, channel: ChannelID, rootID: PostID?,
                          wait: Duration = .seconds(8)) async -> PlainSendResult {
        let reservation: UnsentWorkLedger.Reservation
        do {
            try validateSend(text: text, channel: channel, attachments: [])
            reservation = try deps.unsent.convertDraftToPending(nil, bytes: text.utf8.count)
        } catch let rejection as SendRejection {
            return .rejected(rejection)
        } catch let refusal as UnsentWorkLedger.Refusal {
            return .rejected(.budget(refusal))
        } catch {
            return .failed(.unknown)
        }
        let pendingID: PendingPostID
        do {
            pendingID = try enqueueSend(text: text, channel: channel, rootID: rootID, attachments: [],
                                        reservation: reservation)
        } catch {
            deps.unsent.release(reservation)
            return .rejected(error)
        }
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline {
            guard let item = pending.item(pendingID) else {
                // Gone from the queue: confirmed (recorded below) or discarded in the app.
                if let confirmed = confirmedSends.last(where: { $0.pending == pendingID }) { return .sent(confirmed.post) }
                return .failed(.cancelled)
            }
            switch item.state {
            case .failed(let error): return .failed(error)
            case .outcomeUnknown: return .outcomeUnknown(pendingID)
            default: break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .queued(pendingID)
    }

    /// Today's messages from the busiest conversations for the day summary: direct
    /// and mentioned conversations first, then by latest activity.
    public func todayConversations(maximumChannels: Int, perChannel: Int) async throws(UserFacingError)
        -> [AssistantConversation] {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let zone = deps.timeZone()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = MattermostTimestamp(date: calendar.startOfDay(for: now().date))
        let active = plainChannels().filter { $0.lastPostAt >= start }
        let ranked = active.sorted {
            let lhs = ($0.mentions > 0 ? 2 : 0) + ($0.kind == "direct" || $0.kind == "group" ? 1 : 0)
            let rhs = ($1.mentions > 0 ? 2 : 0) + ($1.kind == "direct" || $1.kind == "group" ? 1 : 0)
            return lhs != rhs ? lhs > rhs : $0.lastPostAt > $1.lastPostAt
        }
        var conversations: [AssistantConversation] = []
        for channel in ranked.prefix(maximumChannels) {
            if Task.isCancelled { throw .cancelled }
            let posts = try await plainPosts(channel: channel.id, limit: perChannel, background: true)
                .filter { $0.createdAt >= start && !$0.isSystem }
            let messages = posts.compactMap { post -> AssistantMessage? in
                var text = post.message.trimmingCharacters(in: .whitespacesAndNewlines)
                if post.fileCount > 0 { text += text.isEmpty ? "[attachment]" : " [attachment]" }
                guard !text.isEmpty else { return nil }
                return AssistantMessage(author: post.displayName, isCurrentUser: post.userID == me.id,
                                        date: post.createdAt.date, text: text)
            }
            guard !messages.isEmpty else { continue }
            let title: String
            switch channel.kind {
            case "direct": title = String(localized: "Direct message with \(channel.displayName)")
            case "group": title = String(localized: "Group message with \(channel.displayName)")
            default: title = "#" + channel.displayName
            }
            conversations.append(AssistantConversation(title: title, messages: messages))
        }
        return conversations
    }

    /// Oldest first, with author names (fetching profiles the directory lacks).
    private func plain(_ posts: [Post]) async throws(UserFacingError) -> [PlainPost] {
        let unknown = Set(posts.map(\.userID)).filter { directory.peekUser($0) == nil }
        if !unknown.isEmpty {
            let epoch = epoch
            if let users = try? await service.users(ids: Array(unknown.prefix(200))), self.epoch == epoch {
                for user in users { directory.upsertUser(user) }
            }
        }
        guard isActiveSessionAlive else { throw .authenticationRequired }
        return posts.filter { !$0.isDeleted }.sorted { $0.createAt < $1.createAt }.map { post in
            let user = directory.peekUser(post.userID)
            var name = user.map { directory.nameFormat.displayName(for: $0) } ?? String(localized: "Unknown user")
            if let override = post.props.overrideUsername, post.props.fromWebhook, !override.isEmpty { name = override }
            return PlainPost(id: post.id, channelID: post.channelID, rootID: post.rootID, userID: post.userID,
                             username: user?.username ?? "", displayName: name, createdAt: post.createAt,
                             message: post.message, fileCount: max(post.files.count, post.fileIDs.count),
                             replyCount: post.replyCount, isSystem: post.type.isSystem)
        }
    }
}
