public import Foundation
public import MatterMacModels

/// Everything the builder needs besides the window itself. Plain values; the builder
/// is a pure function so it is unit-testable and runs on the session actor.
public struct TimelineBuildContext {
    public var scope: AccountScope
    public var me: UserID
    public var channel: Channel?
    public var teamName: String?
    public var endpoint: ServerEndpoint
    /// Collapsed reply threads active: channel timelines contain root posts only.
    public var collapsedThreads: Bool
    public var editTimeLimitSeconds: Int?
    public var canDeleteOthers: Bool
    public var now: MattermostTimestamp
    public var collapsedMessageCharacters: Int
    public var timeZone: TimeZone
    public var lastViewedAtOnOpen: MattermostTimestamp?

    public init(scope: AccountScope, me: UserID, channel: Channel?, teamName: String?, endpoint: ServerEndpoint,
                collapsedThreads: Bool, editTimeLimitSeconds: Int?, canDeleteOthers: Bool, now: MattermostTimestamp,
                collapsedMessageCharacters: Int, timeZone: TimeZone = .current,
                lastViewedAtOnOpen: MattermostTimestamp? = nil) {
        self.scope = scope
        self.me = me
        self.channel = channel
        self.teamName = teamName
        self.endpoint = endpoint
        self.collapsedThreads = collapsedThreads
        self.editTimeLimitSeconds = editTimeLimitSeconds
        self.canDeleteOthers = canDeleteOthers
        self.now = now
        self.collapsedMessageCharacters = collapsedMessageCharacters
        self.timeZone = timeZone
        self.lastViewedAtOnOpen = lastViewedAtOnOpen
    }
}

public enum TimelineBuilder {
    /// Posts by the same author within this interval are grouped (no repeated header).
    public static let groupingIntervalMilliseconds: Int64 = 5 * 60 * 1_000

    public struct Output {
        public var items: [TimelineItem]
        /// Authors whose profiles are not retained; the session fetches them.
        public var missingUsers: Set<UserID>
    }

    public static func build(window: HistoryWindow, store: PostStore, directory: DirectoryStore,
                             pending: [PendingSend], context: TimelineBuildContext) -> Output {
        var items: [TimelineItem] = []
        items.reserveCapacity(window.count + pending.count + 8)
        var missing = Set<UserID>()
        let isThread: Bool
        if case .thread = window.target { isThread = true } else { isThread = false }

        if window.isLoaded || !window.isEmpty {
            if window.hasOlder {
                items.append(TimelineItem(
                    id: TimelineItemID(.olderGap), revision: revision(of: window.olderState),
                    content: .gap(GapPresentation(direction: .older, state: gapState(window.olderState)))))
            } else if !isThread {
                let name = context.channel.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? ""
                items.append(TimelineItem(id: TimelineItemID(.historyStart), revision: 1,
                                          content: .historyStart(channelName: name)))
            }
        }

        var previous: Post?
        var previousDay: Int?
        var boundaryInserted = false
        let unreadCount = window.unreadBoundary.flatMap { boundary in
            window.entries.firstIndex { $0.id == boundary }.map { window.entries.count - $0 }
        } ?? 0

        for entry in window.entries {
            guard let stored = store.entry(entry.id) else { continue }
            let post = stored.post
            let day = dayNumber(post.createAt, timeZone: context.timeZone)
            var separated = false
            if day != previousDay {
                items.append(TimelineItem(id: TimelineItemID(.dateSeparator(day)), revision: UInt64(day),
                                          content: .dateSeparator(startOfDay(day, timeZone: context.timeZone))))
                previousDay = day
                separated = true
            }
            if !boundaryInserted, let boundary = window.unreadBoundary, boundary == post.id {
                items.append(TimelineItem(id: TimelineItemID(.unreadBoundary), revision: UInt64(unreadCount),
                                          content: .unreadBoundary(count: unreadCount)))
                boundaryInserted = true
                separated = true
            }
            let author = authorPresentation(post.userID, post: post, directory: directory, me: context.me,
                                            missing: &missing)
            let showsThreadContext = !isThread && !context.collapsedThreads && post.rootID != nil
            let isContinuation = !separated && previous.map { prev in
                prev.userID == post.userID && !prev.type.isSystem && !post.type.isSystem
                    && post.createAt.milliseconds - prev.createAt.milliseconds < groupingIntervalMilliseconds
                    && (prev.rootID == post.rootID || isThread)
                    && !showsThreadContext
                    && prev.props.overrideUsername == post.props.overrideUsername
            } ?? false
            let presentation = postPresentation(
                post: post, document: stored.document, author: author, isContinuation: isContinuation,
                showsThreadContext: showsThreadContext, expanded: window.expanded.contains(post.id),
                context: context, isThread: isThread)
            var hasher = Hasher()
            hasher.combine(stored.revision)
            hasher.combine(isContinuation)
            hasher.combine(author)
            hasher.combine(presentation.actions)
            hasher.combine(window.expanded.contains(post.id))
            hasher.combine(showsThreadContext)
            items.append(TimelineItem(id: TimelineItemID(.post(post.id)), revision: UInt64(bitPattern: Int64(hasher.finalize())),
                                      content: .post(presentation)))
            previous = post
        }

        if window.hasNewer {
            items.append(TimelineItem(
                id: TimelineItemID(.newerGap), revision: revision(of: window.newerState),
                content: .gap(GapPresentation(direction: .newer, state: gapState(window.newerState)))))
        } else {
            // Pending sends appear only at the live edge, after confirmed history.
            for send in pending {
                let author = authorPresentation(context.me, post: nil, directory: directory, me: context.me,
                                                missing: &missing)
                var blocks: [MarkupBlock] = [.paragraph([.text(send.message)])]
                if !send.attachments.isEmpty {
                    blocks.append(.paragraph([.emphasis([.text("Attachments: \(send.attachments.count) (not yet sent)")])]))
                }
                let document = MessageDocument(blocks: blocks)
                let presentation = PostPresentation(
                    postID: nil, pendingID: send.pendingID, channelID: send.channelID, rootID: send.rootID,
                    author: author, createdAt: send.createdAt, isContinuation: false,
                    body: .document(document, isCollapsed: send.message.count > context.collapsedMessageCharacters),
                    isEdited: false, isPinned: false, files: [], reactions: [], replyCount: 0,
                    showsThreadContext: false, sendState: send.presentationState, actions: .none, permalink: nil)
                var hasher = Hasher()
                hasher.combine(send.presentationState)
                hasher.combine(send.attachments.count)
                items.append(TimelineItem(id: TimelineItemID(.pending(send.pendingID)),
                                          revision: UInt64(bitPattern: Int64(hasher.finalize())),
                                          content: .post(presentation)))
            }
        }
        return Output(items: items, missingUsers: missing)
    }

    // MARK: - Pieces

    static func authorPresentation(_ userID: UserID, post: Post?, directory: DirectoryStore, me: UserID,
                                   missing: inout Set<UserID>) -> AuthorPresentation {
        let user = directory.peekUser(userID)
        if user == nil { missing.insert(userID) }
        var name = user.map { directory.nameFormat.displayName(for: $0) } ?? String(localized: "Unknown user")
        // Webhook/integration posts may override the display name; mark it clearly.
        if let override = post?.props.overrideUsername, post?.props.fromWebhook == true, !override.isEmpty {
            name = override
        }
        return AuthorPresentation(userID: userID, displayName: name, username: user?.username ?? "",
                                  isBot: user?.isBot ?? (post?.props.fromBot ?? false) || (post?.props.fromWebhook ?? false),
                                  isCurrentUser: userID == me,
                                  avatarRevision: user?.lastPictureUpdate.milliseconds ?? 0)
    }

    static func postPresentation(post: Post, document: MessageDocument, author: AuthorPresentation, isContinuation: Bool,
                                 showsThreadContext: Bool, expanded: Bool, context: TimelineBuildContext,
                                 isThread: Bool) -> PostPresentation {
        let body: MessageBody
        if post.isDeleted {
            body = .deleted
        } else if post.type.isSystem {
            body = .system(post.message.isEmpty ? String(localized: "System message") : post.message)
        } else if post.type.isCustomPlugin {
            body = .unsupported(summary: unsupportedSummary(for: post.type), fallbackText: post.message)
        } else {
            let long = post.message.count > context.collapsedMessageCharacters
            body = .document(document, isCollapsed: long && !expanded)
        }
        let archived = context.channel?.isArchived ?? false
        let isMine = post.userID == context.me
        let interactive = !post.isDeleted && !post.type.isSystem && !archived
        var canEdit = interactive && isMine && !post.type.isCustomPlugin
        if canEdit, let limit = context.editTimeLimitSeconds, limit >= 0 {
            canEdit = context.now.milliseconds < post.createAt.milliseconds + Int64(limit) * 1_000
        }
        let canDelete = !post.isDeleted && !archived && (isMine || context.canDeleteOthers) && !post.type.isSystem
        let permalink = context.teamName.map { team in
            context.endpoint.url(path: [team, "pl", post.id.rawValue])
        }
        let actions = PostActionHints(canReply: interactive, canReact: interactive,
                                      canEdit: canEdit, canDelete: canDelete, canCopyLink: permalink != nil)
        return PostPresentation(
            postID: post.id, pendingID: nil, channelID: post.channelID, rootID: post.rootID, author: author,
            createdAt: post.createAt, isContinuation: isContinuation, body: body, isEdited: post.isEdited,
            isPinned: post.isPinned, files: post.files, reactions: reactionGroups(post.reactions, me: context.me),
            replyCount: post.rootID == nil ? post.replyCount : 0, showsThreadContext: showsThreadContext,
            sendState: nil, actions: actions, permalink: permalink)
    }

    static func unsupportedSummary(for type: PostType) -> String {
        if type == .calls {
            return String(localized: "Mattermost Calls post. Calls are not supported natively in MatterMac; use “Open in Browser” to join.")
        }
        return String(localized: "This message was created by a plugin that MatterMac cannot display natively.")
    }

    /// Groups reactions by emoji in first-appearance order.
    public static func reactionGroups(_ reactions: [Reaction], me: UserID) -> [ReactionGroup] {
        var order: [String] = []
        var counts: [String: (count: Int, mine: Bool)] = [:]
        for reaction in reactions {
            if counts[reaction.emojiName] == nil { order.append(reaction.emojiName) }
            let current = counts[reaction.emojiName] ?? (0, false)
            counts[reaction.emojiName] = (current.count + 1, current.mine || reaction.userID == me)
        }
        return order.map { ReactionGroup(emojiName: $0, count: counts[$0]!.count, includesCurrentUser: counts[$0]!.mine) }
    }

    static func gapState(_ state: HistoryWindow.EdgeState) -> GapPresentation.State {
        switch state {
        case .idle: .idle
        case .loading: .loading
        case .failed(let error): .failed(error)
        }
    }

    static func revision(of state: HistoryWindow.EdgeState) -> UInt64 {
        switch state {
        case .idle: 1
        case .loading: 2
        case .failed: 3
        }
    }

    public static func dayNumber(_ timestamp: MattermostTimestamp, timeZone: TimeZone) -> Int {
        let seconds = timestamp.milliseconds / 1_000
        let offset = Int64(timeZone.secondsFromGMT(for: timestamp.date))
        let local = seconds + offset
        return Int((local >= 0 ? local : local - 86_399) / 86_400)
    }

    static func startOfDay(_ day: Int, timeZone: TimeZone) -> Date {
        let utcMidnight = Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
        return utcMidnight.addingTimeInterval(-TimeInterval(timeZone.secondsFromGMT(for: utcMidnight)))
    }
}
