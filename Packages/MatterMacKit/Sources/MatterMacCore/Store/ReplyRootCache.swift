public import MatterMacModels

/// Short summaries of thread roots for the reply line drawn above replies in a channel
/// timeline (author and the start of the text). Roots usually arrive only as page
/// context and are dropped by `PostStore` retention, so the line keeps its own copy.
///
/// Bounded by `ResourceBudget.replyRootSummaries`: least recently recorded or read
/// summaries go first. Summaries live in memory only and are never persisted.
public struct ReplyRootCache: Sendable {
    public struct Summary: Hashable, Sendable {
        public var channelID: ChannelID?
        /// `nil` when the root could not be loaded (deleted or inaccessible).
        public var userID: UserID?
        /// Webhook display-name override, when the root carries one.
        public var nameOverride: String?
        public var fromWebhook: Bool
        /// Single-line plain text, at most `ReplyRootCache.previewCharacters`.
        public var preview: String
        public var fileCount: Int
        public var isDeleted: Bool
        public var updateAt: MattermostTimestamp

        public static let unavailable = Summary(channelID: nil, userID: nil, nameOverride: nil, fromWebhook: false,
                                                preview: "", fileCount: 0, isDeleted: false, updateAt: .zero)
    }

    public static let previewCharacters = 160
    /// Root ids queued for one fetch at most.
    public static let maximumWanted = 200

    private var entries: [PostID: (summary: Summary, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    private let capacity: Int
    /// Roots to fetch, first-asked order.
    public private(set) var wanted: [PostID] = []
    /// Roots already queued or fetched; cleared after a successful page load so a
    /// failed fetch is retried once the server is reachable again.
    private var requested: Set<PostID> = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }
    public func contains(_ id: PostID) -> Bool { entries[id] != nil }

    public func peek(_ id: PostID) -> Summary? { entries[id]?.summary }

    /// Marks summaries recently used (the ones a timeline just displayed).
    public mutating func touch(_ ids: [PostID]) {
        for id in ids {
            guard let entry = entries[id] else { continue }
            tick &+= 1
            entries[id] = (entry.summary, tick)
        }
    }

    /// Records (or refreshes) a root. `plainText` is the rendered document's text.
    /// Older copies never replace newer ones; deletion is sticky.
    public mutating func record(_ post: Post, plainText: String) {
        if let stored = entries[post.id]?.summary, stored.userID != nil {
            if stored.isDeleted || post.updateAt < stored.updateAt { return }
        }
        let summary = Summary(channelID: post.channelID, userID: post.userID,
                              nameOverride: post.props.overrideUsername, fromWebhook: post.props.fromWebhook,
                              preview: post.isDeleted ? "" : Self.preview(plainText),
                              fileCount: post.isDeleted ? 0 : max(post.files.count, post.fileIDs.count),
                              isDeleted: post.isDeleted, updateAt: post.updateAt)
        store(summary, for: post.id)
    }

    /// Remembers that a requested root did not come back from the server.
    public mutating func recordUnavailable(_ id: PostID) {
        guard entries[id] == nil else { return }
        store(.unavailable, for: id)
    }

    public mutating func markDeleted(_ id: PostID) {
        guard var summary = entries[id]?.summary, summary.userID != nil else { return }
        summary.isDeleted = true
        summary.preview = ""
        summary.fileCount = 0
        store(summary, for: id)
    }

    /// Queues roots that are neither cached nor already requested.
    public mutating func want(_ ids: [PostID]) {
        for id in ids where entries[id] == nil && wanted.count < Self.maximumWanted {
            if requested.insert(id).inserted { wanted.append(id) }
        }
    }

    /// Hands out up to `limit` queued roots.
    public mutating func takeWanted(_ limit: Int) -> [PostID] {
        let batch = Array(wanted.prefix(limit))
        wanted.removeFirst(batch.count)
        return batch
    }

    /// Lets roots whose fetch failed be asked for again (queued ones stay queued).
    public mutating func allowRetries() {
        requested = Set(wanted)
    }

    public mutating func purge(channel: ChannelID) {
        entries = entries.filter { $0.value.summary.channelID != channel }
    }

    public mutating func removeAll() {
        entries.removeAll()
        wanted.removeAll()
        requested.removeAll()
    }

    /// Collapses whitespace (including line breaks) and cuts to `previewCharacters`.
    static func preview(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                pendingSpace = !result.isEmpty
                continue
            }
            if result.count >= previewCharacters { break }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(character)
        }
        return result
    }

    private mutating func store(_ summary: Summary, for id: PostID) {
        tick &+= 1
        entries[id] = (summary, tick)
        guard entries.count > capacity else { return }
        // Evict the least recently used quarter at once so eviction stays amortized.
        let excess = entries.count - capacity + capacity / 4
        let oldest = entries.sorted { $0.value.tick < $1.value.tick }.prefix(excess).map(\.key)
        for key in oldest where key != id { entries[key] = nil }
    }
}
