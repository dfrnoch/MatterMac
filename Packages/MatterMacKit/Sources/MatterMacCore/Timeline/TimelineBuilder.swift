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
    /// Link previews may show a thumbnail: the server proxies external images
    /// (`HasImageProxy`). Without a proxy, previews are text-only and nothing is fetched
    /// from third-party sites.
    public var linkPreviewImages: Bool
    /// The server has custom emoji on (`EnableCustomEmoji`): non-system `:name:` are
    /// resolved and reported in `Output.missingEmojiNames` until known.
    public var customEmojiEnabled = false

    public init(scope: AccountScope, me: UserID, channel: Channel?, teamName: String?, endpoint: ServerEndpoint,
                collapsedThreads: Bool, editTimeLimitSeconds: Int?, canDeleteOthers: Bool, now: MattermostTimestamp,
                collapsedMessageCharacters: Int, timeZone: TimeZone = .current,
                lastViewedAtOnOpen: MattermostTimestamp? = nil, linkPreviewImages: Bool = false) {
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
        self.linkPreviewImages = linkPreviewImages
    }
}

public enum TimelineBuilder {
    /// Posts by the same author within this interval are grouped (no repeated header).
    public static let groupingIntervalMilliseconds: Int64 = 5 * 60 * 1_000

    public struct Output {
        public var items: [TimelineItem]
        /// Authors whose profiles are not retained; the session fetches them.
        public var missingUsers: Set<UserID>
        /// Custom emoji candidate names not looked up yet (bounded, first-seen order).
        public var missingEmojiNames: [String] = []
    }

    /// Most names reported missing by one build.
    public static let maximumMissingEmojiNames = 200

    public static func build(window: HistoryWindow, store: PostStore, directory: DirectoryStore,
                             pending: [PendingSend], context: TimelineBuildContext,
                             customEmoji: CustomEmojiStore? = nil) -> Output {
        var missingEmoji: [String] = []
        var missingEmojiSet = Set<String>()
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
                continues(prev, with: post, isThread: isThread, showsThreadContext: showsThreadContext)
            } ?? false
            var presentation = postPresentation(
                post: post, document: stored.document, author: author, isContinuation: isContinuation,
                showsThreadContext: showsThreadContext, expanded: window.expanded.contains(post.id),
                context: context, isThread: isThread, directory: directory, missing: &missing)
            if context.customEmojiEnabled, let customEmoji {
                resolveCustomEmoji(in: &presentation, post: post, candidates: stored.customEmojiCandidates,
                                   store: customEmoji, now: context.now.date, missing: &missingEmoji,
                                   missingSet: &missingEmojiSet)
            }
            var hasher = Hasher()
            hasher.combine(stored.revision)
            hasher.combine(isContinuation)
            hasher.combine(author)
            hasher.combine(presentation.actions)
            hasher.combine(window.expanded.contains(post.id))
            hasher.combine(showsThreadContext)
            // Directory-derived state (reactor names, saved flag, preview visibility).
            hasher.combine(presentation.reactions)
            hasher.combine(presentation.isSaved)
            hasher.combine(presentation.linkPreview)
            hasher.combine(presentation.customEmoji)
            items.append(TimelineItem(id: TimelineItemID(.post(post.id)), revision: UInt64(bitPattern: Int64(hasher.finalize())),
                                      content: .post(presentation)))
            previous = post
        }

        if window.hasNewer {
            items.append(TimelineItem(
                id: TimelineItemID(.newerGap), revision: revision(of: window.newerState),
                content: .gap(GapPresentation(direction: .newer, state: gapState(window.newerState)))))
        } else {
            // Pending sends appear only at the live edge, after confirmed history. Like the
            // official client, a pending send continues the user's own recent group.
            var groupStart: MattermostTimestamp? = previous.flatMap { prev in
                prev.userID == context.me && !prev.type.isSystem && !prev.isDeleted && prev.props.overrideUsername == nil
                    ? prev.createAt : nil
            }
            var groupRoot = previous?.rootID
            for send in pending {
                let sameDay = previousDay == nil || previousDay == dayNumber(send.createdAt, timeZone: context.timeZone)
                let continuesGroup = sameDay && (groupRoot == send.rootID || isThread) && groupStart.map {
                    send.createdAt.milliseconds - $0.milliseconds < groupingIntervalMilliseconds
                        && send.createdAt >= $0
                } == true
                groupStart = send.createdAt
                groupRoot = send.rootID
                let author = authorPresentation(context.me, post: nil, directory: directory, me: context.me,
                                                missing: &missing)
                var blocks: [MarkupBlock] = [.paragraph([.text(send.message)])]
                if !send.attachments.isEmpty {
                    blocks.append(.paragraph([.emphasis([.text("Attachments: \(send.attachments.count) (not yet sent)")])]))
                }
                let document = MessageDocument(blocks: blocks)
                let presentation = PostPresentation(
                    postID: nil, pendingID: send.pendingID, channelID: send.channelID, rootID: send.rootID,
                    author: author, createdAt: send.createdAt, isContinuation: continuesGroup,
                    body: .document(document, isCollapsed: send.message.count > context.collapsedMessageCharacters),
                    isEdited: false, isPinned: false, files: [], reactions: [], replyCount: 0,
                    showsThreadContext: false, sendState: send.presentationState, actions: .none, permalink: nil)
                var hasher = Hasher()
                hasher.combine(send.presentationState)
                hasher.combine(send.attachments.count)
                hasher.combine(continuesGroup)
                items.append(TimelineItem(id: TimelineItemID(.pending(send.pendingID)),
                                          revision: UInt64(bitPattern: Int64(hasher.finalize())),
                                          content: .post(presentation)))
            }
        }
        return Output(items: items, missingUsers: missing, missingEmojiNames: missingEmoji)
    }

    /// Fills `customEmoji` (message) and `customEmojiID` (reactions) from the post's
    /// own `metadata.emojis` first, then the session store; unknown names are reported.
    static func resolveCustomEmoji(in presentation: inout PostPresentation, post: Post, candidates: [String],
                                   store: CustomEmojiStore, now: Date, missing: inout [String],
                                   missingSet: inout Set<String>) {
        guard case .document = presentation.body else {
            if !presentation.reactions.isEmpty {
                resolveReactions(&presentation, post: post, store: store, now: now, missing: &missing, missingSet: &missingSet)
            }
            return
        }
        func lookup(_ name: String) -> String? {
            if let own = post.customEmojis.first(where: { $0.name == name }) { return own.id }
            switch store.peekResolution(name, now: now) {
            case .custom(let emoji): return emoji.id
            case .missing: return nil
            case .unknown:
                if missing.count < maximumMissingEmojiNames, missingSet.insert(name).inserted { missing.append(name) }
                return nil
            }
        }
        var resolved: [String: String] = [:]
        for name in candidates { if let id = lookup(name) { resolved[name] = id } }
        presentation.customEmoji = resolved
        resolveReactions(&presentation, post: post, store: store, now: now, missing: &missing, missingSet: &missingSet)
    }

    private static func resolveReactions(_ presentation: inout PostPresentation, post: Post, store: CustomEmojiStore,
                                         now: Date, missing: inout [String], missingSet: inout Set<String>) {
        guard !presentation.reactions.isEmpty else { return }
        var reactions = presentation.reactions
        for index in reactions.indices where CustomEmoji.isCandidateName(reactions[index].emojiName) {
            let name = reactions[index].emojiName
            if let own = post.customEmojis.first(where: { $0.name == name }) {
                reactions[index].customEmojiID = own.id
                continue
            }
            switch store.peekResolution(name, now: now) {
            case .custom(let emoji): reactions[index].customEmojiID = emoji.id
            case .missing: continue
            case .unknown:
                if missing.count < maximumMissingEmojiNames, missingSet.insert(name).inserted { missing.append(name) }
            }
        }
        presentation.reactions = reactions
    }

    // MARK: - Pieces

    /// Same author within `groupingIntervalMilliseconds`, neither a system post, same
    /// thread (channel timelines), no reply context shown, same webhook override name.
    static func continues(_ prev: Post, with post: Post, isThread: Bool, showsThreadContext: Bool) -> Bool {
        prev.userID == post.userID && !prev.type.isSystem && !post.type.isSystem
            && post.createAt.milliseconds - prev.createAt.milliseconds < groupingIntervalMilliseconds
            && post.createAt >= prev.createAt
            && (prev.rootID == post.rootID || isThread)
            && !showsThreadContext
            && prev.props.overrideUsername == post.props.overrideUsername
            && prev.props.fromWebhook == post.props.fromWebhook
    }

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
                                 isThread: Bool, directory: DirectoryStore,
                                 missing: inout Set<UserID>) -> PostPresentation {
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
        let isPlugin = post.type.isCustomPlugin
        let actions = PostActionHints(canReply: interactive, canReact: interactive,
                                      canEdit: canEdit, canDelete: canDelete, canCopyLink: permalink != nil,
                                      canPin: interactive && !isPlugin, canSave: !post.isDeleted && !post.type.isSystem,
                                      canMarkUnread: !isThread && !post.isDeleted)
        return PostPresentation(
            postID: post.id, pendingID: nil, channelID: post.channelID, rootID: post.rootID, author: author,
            createdAt: post.createAt, isContinuation: isContinuation, body: body, isEdited: post.isEdited,
            isPinned: post.isPinned, files: post.files,
            reactions: reactionGroups(post.reactions, me: context.me, directory: directory, missing: &missing),
            replyCount: post.rootID == nil ? post.replyCount : 0, showsThreadContext: showsThreadContext,
            sendState: nil, actions: actions, permalink: permalink,
            isSaved: directory.savedPosts.contains(post.id), editedAt: post.isEdited ? post.editAt : nil,
            linkPreview: visiblePreview(post, directory: directory, context: context))
    }

    /// The link preview to show, honoring `display_settings/link_previews` for website
    /// previews and dropping thumbnails that cannot go through the server's image proxy.
    static func visiblePreview(_ post: Post, directory: DirectoryStore, context: TimelineBuildContext) -> LinkPreview? {
        guard var preview = post.linkPreview, !post.isDeleted, !post.type.isSystem, !post.type.isCustomPlugin else {
            return nil
        }
        if preview.kind == .website, !directory.showsLinkPreviews { return nil }
        if !context.linkPreviewImages { preview.image = nil }
        return preview
    }

    static func unsupportedSummary(for type: PostType) -> String {
        if type == .calls {
            return String(localized: "Mattermost Calls post. Calls are not supported natively in MatterMac; use “Open in Browser” to join.")
        }
        return String(localized: "This message was created by a plugin that MatterMac cannot display natively.")
    }

    /// Groups reactions by emoji in first-appearance order.
    public static func reactionGroups(_ reactions: [Reaction], me: UserID) -> [ReactionGroup] {
        var missing = Set<UserID>()
        return reactionGroups(reactions, me: me, directory: nil, missing: &missing)
    }

    /// Groups reactions by emoji and resolves up to `ReactionGroup.maximumReactorNames`
    /// reactor names per emoji from the directory ("You" first). Unknown reactors among
    /// those are reported in `missing` so the session fetches their profiles.
    public static func reactionGroups(_ reactions: [Reaction], me: UserID, directory: DirectoryStore?,
                                      missing: inout Set<UserID>) -> [ReactionGroup] {
        struct Group {
            var count = 0
            var mine = false
            var reactors: [UserID] = []
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for reaction in reactions {
            if groups[reaction.emojiName] == nil { order.append(reaction.emojiName) }
            var group = groups[reaction.emojiName] ?? Group()
            group.count += 1
            if reaction.userID == me {
                group.mine = true
            } else if group.reactors.count < ReactionGroup.maximumReactorNames {
                group.reactors.append(reaction.userID)
            }
            groups[reaction.emojiName] = group
        }
        return order.map { name in
            let group = groups[name] ?? Group()
            var names: [String] = []
            if let directory {
                if group.mine { names.append(String(localized: "You")) }
                for id in group.reactors where names.count < ReactionGroup.maximumReactorNames {
                    if let user = directory.peekUser(id) {
                        names.append(directory.nameFormat.displayName(for: user))
                    } else {
                        missing.insert(id)
                    }
                }
            }
            return ReactionGroup(emojiName: name, count: group.count, includesCurrentUser: group.mine, reactorNames: names)
        }
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
