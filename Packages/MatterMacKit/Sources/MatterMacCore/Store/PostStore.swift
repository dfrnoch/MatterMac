public import MatterMacModels

/// Normalized storage of retained posts for one session: one canonical `Post` (plus
/// its parsed `MessageDocument`) per post ID, shared by the channel timeline, thread
/// panel, and search results. Entries are reference-counted by windows; an entry that
/// no window references is removed by `collectUnreferenced()`.
///
/// Merge rules (SPEC §10 snapshot/event races):
/// - Deletion is sticky: once `deleteAt > 0`, a later snapshot cannot resurrect it.
/// - An incoming copy with an older `updateAt` never replaces a newer stored copy.
/// - Equal `updateAt` keeps the stored copy (which may already include locally
///   applied realtime reactions) but fills in metadata the stored copy lacks.
/// - `pendingPostID` is kept from whichever copy has it (fetched posts carry "").
public struct PostStore: Sendable {
    public struct Entry: Sendable {
        public var post: Post
        public var document: MessageDocument
        /// Monotonic, store-unique revision; changes on every mutation of this entry.
        public var revision: UInt64
        public var cost: Int
        public var references: Int
        /// `:name:` in the document that are not system emoji (possible custom emoji),
        /// computed once per parse (`MessageDocument.customEmojiCandidates`).
        public var customEmojiCandidates: [String] = []
    }

    public enum UpsertResult: Equatable {
        case inserted
        case updated
        case unchanged
        case ignoredStale
        case notPresent
    }

    private(set) var entries: [PostID: Entry] = [:]
    public private(set) var usage = RetentionLedger.Usage()
    private var revisionCounter: UInt64 = 0
    /// Builds the display document for a post (message + basic attachments). Runs on
    /// the owning session actor, never on the main actor.
    private let render: @Sendable (Post) -> MessageDocument

    public init(render: @escaping @Sendable (Post) -> MessageDocument) {
        self.render = render
    }

    public var count: Int { entries.count }
    public func entry(_ id: PostID) -> Entry? { entries[id] }
    public func post(_ id: PostID) -> Post? { entries[id]?.post }
    public func contains(_ id: PostID) -> Bool { entries[id] != nil }

    /// Inserts or merges a post. With `insertIfMissing == false`, an unknown post is
    /// left alone (used for realtime edits of posts we do not retain).
    @discardableResult
    public mutating func upsert(_ incoming: Post, insertIfMissing: Bool = true) -> UpsertResult {
        guard var entry = entries[incoming.id] else {
            guard insertIfMissing else { return .notPresent }
            let document = incoming.isDeleted ? .empty : render(incoming)
            let cost = Self.estimatedCost(of: incoming, document: document)
            entries[incoming.id] = Entry(post: incoming, document: document, revision: nextRevision(),
                                         cost: cost, references: 0,
                                         customEmojiCandidates: document.customEmojiCandidates())
            usage.count += 1
            usage.bytes += cost
            return .inserted
        }
        let stored = entry.post
        var merged: Post
        if stored.isDeleted {
            // Sticky deletion; allow only metadata-neutral fields to refresh.
            if incoming.isDeleted && incoming.deleteAt > stored.deleteAt {
                merged = stored
                merged.deleteAt = incoming.deleteAt
            } else {
                return .unchanged
            }
        } else if incoming.isDeleted {
            merged = Self.tombstone(of: stored, deleteAt: incoming.deleteAt)
        } else if incoming.updateAt < stored.updateAt {
            return .ignoredStale
        } else if incoming.updateAt == stored.updateAt {
            merged = stored
            if merged.files.isEmpty && !incoming.files.isEmpty { merged.files = incoming.files }
            if merged.replyCount == 0 && incoming.replyCount > 0 { merged.replyCount = incoming.replyCount }
            if merged.lastReplyAt < incoming.lastReplyAt { merged.lastReplyAt = incoming.lastReplyAt }
            if merged.linkPreview == nil, let preview = incoming.linkPreview { merged.linkPreview = preview }
            if merged.customEmojis.isEmpty && !incoming.customEmojis.isEmpty { merged.customEmojis = incoming.customEmojis }
            if merged == stored { return .unchanged }
        } else {
            merged = incoming
            // The dedup-return path and list endpoints may omit metadata.
            if merged.files.isEmpty && !merged.fileIDs.isEmpty && !stored.files.isEmpty { merged.files = stored.files }
            // Posts in `since`/thread lists may lack metadata; keep a preview for the same text.
            if merged.linkPreview == nil, merged.message == stored.message { merged.linkPreview = stored.linkPreview }
            if merged.customEmojis.isEmpty { merged.customEmojis = stored.customEmojis }
        }
        if merged.pendingPostID == nil { merged.pendingPostID = stored.pendingPostID }
        let reparse = merged.message != stored.message || merged.isDeleted != stored.isDeleted
            || merged.props.attachments != stored.props.attachments
        if reparse {
            entry.document = merged.isDeleted ? .empty : render(merged)
            entry.customEmojiCandidates = entry.document.customEmojiCandidates()
        }
        entry.post = merged
        replaceCost(of: &entry)
        entry.revision = nextRevision()
        entries[incoming.id] = entry
        return .updated
    }

    /// Applies a realtime reaction to a retained post. Returns `false` when the post is
    /// not retained (the event is still journaled for later snapshots).
    @discardableResult
    public mutating func applyReaction(_ reaction: Reaction, added: Bool, reactionCap: Int = 500) -> Bool {
        guard var entry = entries[reaction.postID], !entry.post.isDeleted else { return false }
        var reactions = entry.post.reactions
        let existing = reactions.firstIndex {
            $0.userID == reaction.userID && $0.emojiName == reaction.emojiName
        }
        if added {
            guard existing == nil else { return true }
            if reactions.count >= reactionCap {
                entry.post.reactionsTruncated = true
            } else {
                reactions.append(reaction)
            }
        } else {
            guard let existing else { return true }
            reactions.remove(at: existing)
        }
        entry.post.reactions = reactions
        entry.post.hasReactions = !reactions.isEmpty
        replaceCost(of: &entry)
        entry.revision = nextRevision()
        entries[reaction.postID] = entry
        return true
    }

    /// Marks a post deleted (message blanked; attachments dropped). For a thread root,
    /// callers also delete its retained replies.
    @discardableResult
    public mutating func markDeleted(_ id: PostID, at time: MattermostTimestamp) -> Bool {
        guard var entry = entries[id] else { return false }
        guard !entry.post.isDeleted else { return false }
        entry.post = Self.tombstone(of: entry.post, deleteAt: time.isZero ? MattermostTimestamp(milliseconds: 1) : time)
        entry.document = .empty
        entry.customEmojiCandidates = []
        replaceCost(of: &entry)
        entry.revision = nextRevision()
        entries[id] = entry
        return true
    }

    /// IDs of retained replies to `root`.
    public func replies(to root: PostID) -> [PostID] {
        entries.values.lazy.filter { $0.post.rootID == root }.map(\.post.id)
    }

    /// Applies a confirmed local change (e.g. pin state after `POST /posts/{id}/pin`)
    /// that the server's copy will also carry once it arrives with a newer `updateAt`.
    @discardableResult
    public mutating func setPinned(_ id: PostID, _ pinned: Bool) -> Bool {
        guard var entry = entries[id], !entry.post.isDeleted, entry.post.isPinned != pinned else { return false }
        entry.post.isPinned = pinned
        entry.revision = nextRevision()
        entries[id] = entry
        return true
    }

    public mutating func bumpRevision(_ id: PostID) {
        guard var entry = entries[id] else { return }
        entry.revision = nextRevision()
        entries[id] = entry
    }

    public mutating func retain(_ id: PostID) {
        entries[id]?.references += 1
    }

    public mutating func release(_ id: PostID) {
        guard var entry = entries[id] else { return }
        entry.references = max(0, entry.references - 1)
        entries[id] = entry
    }

    /// Removes entries no window references. Returns the number removed.
    @discardableResult
    public mutating func collectUnreferenced() -> Int {
        let unreferenced = entries.filter { $0.value.references == 0 }
        for (id, entry) in unreferenced {
            entries[id] = nil
            usage.count -= 1
            usage.bytes -= entry.cost
        }
        return unreferenced.count
    }

    /// Removes every post of a channel regardless of references (membership revoked).
    public mutating func purge(channel: ChannelID) -> [PostID] {
        let ids = entries.filter { $0.value.post.channelID == channel }.map(\.key)
        for id in ids {
            if let entry = entries.removeValue(forKey: id) {
                usage.count -= 1
                usage.bytes -= entry.cost
            }
        }
        return ids
    }

    public mutating func removeAll() {
        entries.removeAll()
        usage = RetentionLedger.Usage()
    }

    // MARK: - Cost

    /// Approximate retained heap cost of a post plus its parsed document. Used for
    /// deterministic eviction; whole-process footprint is measured separately.
    public static func estimatedCost(of post: Post, document: MessageDocument) -> Int {
        var cost = 480 + post.message.utf8.count
        cost += post.isDeleted ? 0 : post.message.utf8.count + 64 * min(document.blocks.count, 1_000)
        for file in post.files {
            cost += 256 + file.name.utf8.count + file.mimeType.utf8.count + (file.miniPreview?.count ?? 0)
        }
        cost += post.fileIDs.count * 48 + post.reactions.count * 96
        for attachment in post.props.attachments {
            cost += 256 + attachment.text.utf8.count + attachment.pretext.utf8.count + attachment.fallback.utf8.count
                + attachment.title.utf8.count + attachment.imageURL.utf8.count
            for field in attachment.fields { cost += 64 + field.title.utf8.count + field.value.utf8.count }
        }
        for (key, value) in post.props.systemContext { cost += 64 + key.utf8.count + value.utf8.count }
        cost += post.linkPreview?.estimatedCost ?? 0
        cost += post.customEmojis.reduce(0) { $0 + $1.estimatedCost }
        return cost
    }

    private mutating func replaceCost(of entry: inout Entry) {
        let newCost = Self.estimatedCost(of: entry.post, document: entry.document)
        usage.bytes += newCost - entry.cost
        entry.cost = newCost
    }

    private mutating func nextRevision() -> UInt64 {
        revisionCounter &+= 1
        return revisionCounter
    }

    static func tombstone(of post: Post, deleteAt: MattermostTimestamp) -> Post {
        var dead = post
        dead.deleteAt = deleteAt
        dead.message = ""
        dead.files = []
        dead.fileIDs = []
        dead.reactions = []
        dead.hasReactions = false
        dead.props = .empty
        dead.linkPreview = nil
        dead.customEmojis = []
        return dead
    }
}
