import Foundation
public import MatterMacModels

/// Bounds applied while decoding posts from untrusted server JSON.
public enum PostDecodingLimits {
    /// Server maximum is 16,383 runes by default but can be larger with a wider DB
    /// column; retained text above this is cut and flagged (display only — never used
    /// for sends).
    public static let maximumMessageBytes = 256 * 1_024
    public static let maximumFileIDs = 10
    public static let maximumFiles = 10
    public static let maximumReactions = 500
    public static let maximumAttachments = 10
    public static let maximumAttachmentFields = 20
    public static let maximumSystemContextEntries = 16
    public static let maximumSystemContextValueBytes = 1_024
    public static let maximumMiniPreviewBytes = 4 * 1_024
}

/// `Post` as sent by the server. Decodes directly into the domain value; nothing else
/// from the wire payload (plugin props, translations, other embed types) is retained.
/// The first OpenGraph or image embed is kept as a bounded `LinkPreview`.
public struct PostWire: Decodable, Sendable {
    public let post: Post
    /// `original_id` non-empty marks a hidden edit-history row (returned by `since`
    /// queries). Callers must drop these.
    public let isEditHistoryRow: Bool
    /// The message was longer than we retain for display.
    public let messageTruncated: Bool

    enum Keys: String, CodingKey {
        case id, channel_id, user_id, root_id, original_id, message, message_source, type
        case create_at, update_at, edit_at, delete_at, is_pinned, file_ids, pending_post_id
        case has_reactions, reply_count, last_reply_at, props, metadata
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = try c.requiredID(PostID.self, .id)
        let channelID = try c.requiredID(ChannelID.self, .channel_id)
        let userID = try c.requiredID(UserID.self, .user_id)
        var message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        // When the image proxy rewrote `message`, `message_source` holds the original.
        if let source = try? c.decodeIfPresent(String.self, forKey: .message_source), !source.isEmpty {
            message = source
        }
        var truncated = false
        if message.utf8.count > PostDecodingLimits.maximumMessageBytes {
            message = String(decoding: message.utf8.prefix(PostDecodingLimits.maximumMessageBytes), as: UTF8.self)
            truncated = true
        }
        let type = PostType(rawValue: (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "")
        let metadata = try? c.decodeIfPresent(PostMetadataWire.self, forKey: .metadata)
        let props = (try? c.decodeIfPresent(PostPropsWire.self, forKey: .props))?.props ?? .empty

        var reactions = metadata?.reactions.elements ?? []
        var reactionsTruncated = false
        if reactions.count > PostDecodingLimits.maximumReactions {
            reactions = Array(reactions.prefix(PostDecodingLimits.maximumReactions))
            reactionsTruncated = true
        }
        let pending = (try? c.decodeIfPresent(String.self, forKey: .pending_post_id)).flatMap {
            $0.isEmpty ? nil : PendingPostID(rawValue: $0)
        }

        self.post = Post(
            id: id,
            channelID: channelID,
            userID: userID,
            rootID: c.optionalID(PostID.self, .root_id),
            message: message,
            type: type,
            createAt: c.timestamp(.create_at),
            updateAt: c.timestamp(.update_at),
            editAt: c.timestamp(.edit_at),
            deleteAt: c.timestamp(.delete_at),
            isPinned: c.lenientBool(.is_pinned) ?? false,
            fileIDs: c.idList(FileID.self, .file_ids, limit: PostDecodingLimits.maximumFileIDs),
            files: (metadata?.files.elements ?? []).prefix(PostDecodingLimits.maximumFiles).map(\.info),
            reactions: reactions.map(\.reaction),
            reactionsTruncated: reactionsTruncated,
            hasReactions: c.lenientBool(.has_reactions) ?? false,
            pendingPostID: pending,
            replyCount: Int(clamping: c.lenientInt64(.reply_count) ?? 0),
            lastReplyAt: c.timestamp(.last_reply_at),
            props: props,
            linkPreview: props.attachments.isEmpty ? metadata?.linkPreview : nil
        )
        self.isEditHistoryRow = !((try? c.decodeIfPresent(String.self, forKey: .original_id)) ?? "").isEmpty
        self.messageTruncated = truncated
    }
}

struct PostMetadataWire: Decodable, Sendable {
    var files: LossyArray<FileInfoWireElement>
    var reactions: LossyArray<ReactionWire>
    var linkPreview: LinkPreview?

    enum Keys: String, CodingKey { case files, reactions, embeds, images }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        files = (try? c.decodeIfPresent(LossyArray<FileInfoWireElement>.self, forKey: .files)) ?? LossyArray(elements: [])
        reactions = (try? c.decodeIfPresent(LossyArray<ReactionWire>.self, forKey: .reactions)) ?? LossyArray(elements: [])
        linkPreview = nil
        // The server adds at most one link embed (for the first link). Only the first
        // few entries are examined; permalink, boards and plain link embeds are ignored.
        let embeds = (try? c.decodeIfPresent(LossyArray<EmbedWire>.self, forKey: .embeds))?.elements ?? []
        guard let embed = embeds.prefix(4).first(where: { $0.preview != nil }), var preview = embed.preview else { return }
        if var image = preview.image {
            // `metadata.images` is keyed by the exact image URL; only that one entry is read.
            if let images = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: .images),
               let measured = try? images.decodeIfPresent(PostImageWire.self, forKey: DynamicKey(image.url)) {
                if measured.isSVG {
                    preview.image = nil
                } else {
                    image.width = measured.width ?? image.width
                    image.height = measured.height ?? image.height
                    preview.image = image
                }
            } else {
                preview.image = image
            }
        }
        if preview.kind == .image && preview.image == nil { return }
        linkPreview = preview
    }
}

/// One `metadata.embeds` entry. `opengraph` and `image` become a `LinkPreview`.
struct EmbedWire: Decodable, Sendable {
    let preview: LinkPreview?

    enum Keys: String, CodingKey { case type, url, data }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = c.lenientString(.type, maxBytes: 32) ?? ""
        guard let raw = c.lenientString(.url, maxBytes: LinkPreview.maximumURLBytes), let link = SafeLink(raw),
              link.kind == .web else {
            preview = nil
            return
        }
        switch type {
        case "image":
            preview = LinkPreview(kind: .image, link: link, image: LinkPreview.Image(url: link.url.absoluteString))
        case "opengraph":
            guard let data = try? c.decodeIfPresent(OpenGraphWire.self, forKey: .data),
                  !data.title.isEmpty || !data.description.isEmpty else {
                preview = nil
                return
            }
            preview = LinkPreview(kind: .website, link: link, title: data.title, description: data.description,
                                  siteName: data.siteName, image: data.image)
        default:
            preview = nil
        }
    }
}

/// The OpenGraph subset MatterMac shows (`github.com/dyatlov/go-opengraph` JSON).
struct OpenGraphWire: Decodable, Sendable {
    let title: String
    let description: String
    let siteName: String
    let image: LinkPreview.Image?

    enum Keys: String, CodingKey { case title, description, site_name, images }

    struct ImageWire: Decodable, Sendable {
        let image: LinkPreview.Image?
        enum Keys: String, CodingKey { case url, secure_url, width, height }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let secure = c.lenientString(.secure_url, maxBytes: LinkPreview.maximumURLBytes) ?? ""
            let plain = c.lenientString(.url, maxBytes: LinkPreview.maximumURLBytes) ?? ""
            // Only absolute http(s) URLs; the server keys `metadata.images` by this string.
            let raw = [secure, plain].first { SafeLink($0)?.kind == .web }
            func dimension(_ key: Keys) -> Int? {
                c.lenientInt64(key).flatMap { $0 > 0 && $0 < 100_000 ? Int($0) : nil }
            }
            image = raw.map { LinkPreview.Image(url: $0, width: dimension(.width), height: dimension(.height)) }
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // Read a little beyond the retained bound so `LinkPreview.bounded` can mark truncation.
        title = c.lenientString(.title, maxBytes: LinkPreview.maximumTitleBytes * 2) ?? ""
        description = c.lenientString(.description, maxBytes: LinkPreview.maximumDescriptionBytes * 2) ?? ""
        siteName = c.lenientString(.site_name, maxBytes: LinkPreview.maximumSiteNameBytes * 2) ?? ""
        let images = (try? c.decodeIfPresent(LossyArray<ImageWire>.self, forKey: .images))?.elements ?? []
        image = images.prefix(4).lazy.compactMap(\.image).first
    }
}

/// `metadata.images[url]`: `{width, height, format, frame_count}`.
struct PostImageWire: Decodable, Sendable {
    let width: Int?
    let height: Int?
    let isSVG: Bool

    enum Keys: String, CodingKey { case width, height, format }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        width = c.lenientInt64(.width).flatMap { $0 > 0 && $0 < 100_000 ? Int($0) : nil }
        height = c.lenientInt64(.height).flatMap { $0 > 0 && $0 < 100_000 ? Int($0) : nil }
        isSVG = (c.lenientString(.format, maxBytes: 16) ?? "").lowercased() == "svg"
    }
}

/// Wrapper so `LossyArray<FileInfo>` can decode through `FileInfoWire`.
struct FileInfoWireElement: Decodable, Sendable {
    let info: FileInfo
    init(from decoder: any Decoder) throws { info = try FileInfoWire(from: decoder).info }
}

public struct ReactionWire: Decodable, Sendable {
    public let reaction: Reaction

    enum Keys: String, CodingKey { case user_id, post_id, emoji_name, create_at, delete_at }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let name = try c.decode(String.self, forKey: .emoji_name)
        guard Reaction.isValidEmojiName(name) else {
            throw DecodingError.dataCorruptedError(forKey: .emoji_name, in: c, debugDescription: "invalid emoji name")
        }
        reaction = Reaction(
            userID: try c.requiredID(UserID.self, .user_id),
            postID: try c.requiredID(PostID.self, .post_id),
            emojiName: name.lowercased(),
            createAt: c.timestamp(.create_at)
        )
    }
}

public struct FileInfoWire: Decodable, Sendable {
    public let info: FileInfo

    enum Keys: String, CodingKey {
        case id, post_id, channel_id, name, `extension`, size, mime_type, width, height, has_preview_image
        case mini_preview, create_at, delete_at
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        var miniPreview: Data?
        if let base64 = try? c.decodeIfPresent(String.self, forKey: .mini_preview),
           base64.utf8.count <= PostDecodingLimits.maximumMiniPreviewBytes * 2,
           let data = Data(base64Encoded: base64), data.count <= PostDecodingLimits.maximumMiniPreviewBytes {
            miniPreview = data
        }
        let width = c.lenientInt64(.width).map { Int(clamping: $0) }
        let height = c.lenientInt64(.height).map { Int(clamping: $0) }
        info = FileInfo(
            id: try c.requiredID(FileID.self, .id),
            postID: c.optionalID(PostID.self, .post_id),
            channelID: c.optionalID(ChannelID.self, .channel_id),
            name: String(((try? c.decodeIfPresent(String.self, forKey: .name)) ?? "").prefix(512)),
            fileExtension: String(((try? c.decodeIfPresent(String.self, forKey: .`extension`)) ?? "").prefix(32)),
            size: max(0, c.lenientInt64(.size) ?? 0),
            mimeType: String(((try? c.decodeIfPresent(String.self, forKey: .mime_type)) ?? "").prefix(128)),
            width: width.flatMap { $0 > 0 ? $0 : nil },
            height: height.flatMap { $0 > 0 ? $0 : nil },
            hasPreviewImage: c.lenientBool(.has_preview_image) ?? false,
            miniPreview: miniPreview,
            createAt: c.timestamp(.create_at),
            deleteAt: c.timestamp(.delete_at)
        )
    }
}

/// Extracts only the understood keys from `post.props`.
struct PostPropsWire: Decodable, Sendable {
    let props: PostProps

    /// System-post context keys worth keeping (small strings).
    static let systemContextKeys: Set<String> = [
        "username", "addedUsername", "removedUsername", "old_header", "new_header",
        "old_displayname", "new_displayname", "old_purpose", "new_purpose", "userId", "addedUserId",
        "removedUserId", "deleteBy", "channel_name", "old_channel_name",
    ]
    /// Keys indicating interactive or plugin content we do not execute natively.
    static let unsupportedKeys: Set<String> = ["app_bindings", "blocks", "mm_blocks_actions", "card"]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var props = PostProps()
        for key in c.allKeys {
            switch key.stringValue {
            case "from_webhook":
                props.fromWebhook = c.lenientBool(key) ?? false
            case "from_bot":
                props.fromBot = c.lenientBool(key) ?? false
            case "override_username":
                props.overrideUsername = c.lenientString(key, maxBytes: 256)
            case "attachments":
                if let list = try? c.decode(LossyArray<AttachmentWire>.self, forKey: key) {
                    props.attachments = list.elements.prefix(PostDecodingLimits.maximumAttachments).map(\.attachment)
                    if list.elements.count > PostDecodingLimits.maximumAttachments || list.skipped > 0 {
                        props.hasUnsupportedContent = true
                    }
                    if props.attachments.contains(where: \.hasUnsupportedActions) { props.hasUnsupportedContent = true }
                }
            case let name where Self.unsupportedKeys.contains(name):
                props.hasUnsupportedContent = true
            case let name where Self.systemContextKeys.contains(name):
                if props.systemContext.count < PostDecodingLimits.maximumSystemContextEntries,
                   let value = c.lenientString(key, maxBytes: PostDecodingLimits.maximumSystemContextValueBytes) {
                    props.systemContext[name] = value
                }
            default:
                continue
            }
        }
        self.props = props
    }
}

struct AttachmentWire: Decodable, Sendable {
    let attachment: MessageAttachment

    enum Keys: String, CodingKey {
        case fallback, color, pretext, author_name, title, title_link, text, fields, footer, actions
    }

    struct FieldWire: Decodable, Sendable {
        let field: MessageAttachment.Field
        enum Keys: String, CodingKey { case title, value, short }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            field = MessageAttachment.Field(
                title: c.lenientString(.title, maxBytes: 1_024) ?? "",
                value: c.lenientString(.value, maxBytes: 8 * 1_024) ?? "",
                isShort: c.lenientBool(.short) ?? false)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let fields = (try? c.decodeIfPresent(LossyArray<FieldWire>.self, forKey: .fields))?.elements ?? []
        var hasActions = false
        if let actions = try? c.decodeIfPresent(LossyArray<BoundedJSONWire>.self, forKey: .actions) {
            hasActions = !actions.elements.isEmpty || actions.skipped > 0
        }
        attachment = MessageAttachment(
            fallback: c.lenientString(.fallback, maxBytes: 8 * 1_024) ?? "",
            color: c.lenientString(.color, maxBytes: 32) ?? "",
            pretext: c.lenientString(.pretext, maxBytes: 8 * 1_024) ?? "",
            authorName: c.lenientString(.author_name, maxBytes: 256) ?? "",
            title: c.lenientString(.title, maxBytes: 1_024) ?? "",
            titleLink: c.lenientString(.title_link, maxBytes: 2_048) ?? "",
            text: c.lenientString(.text, maxBytes: 32 * 1_024) ?? "",
            fields: Array(fields.prefix(PostDecodingLimits.maximumAttachmentFields).map(\.field)),
            footer: c.lenientString(.footer, maxBytes: 1_024) ?? "",
            hasUnsupportedActions: hasActions)
    }
}

/// Skips over any JSON value without retaining it.
struct BoundedJSONWire: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}

/// `PostList`: `order` (newest first for channel endpoints) plus a `posts` map. The
/// map is a superset of `order` (it can include roots of replies); dictionary
/// iteration order is never used as timeline order.
public struct PostListWire: Decodable, Sendable {
    public let order: [PostID]
    public let posts: [PostID: Post]
    public let nextPostID: PostID?
    public let previousPostID: PostID?
    public let hasNext: Bool?
    public let skippedMalformed: Int
    public let droppedEditHistoryRows: Int

    enum Keys: String, CodingKey { case order, posts, next_post_id, prev_post_id, has_next }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let rawOrder = (try? c.decodeIfPresent([String].self, forKey: .order)) ?? []
        var skipped = 0
        var editRows = 0
        var posts: [PostID: Post] = [:]
        if c.contains(.posts), (try? c.decodeNil(forKey: .posts)) != true {
            let map = try c.nestedContainer(keyedBy: DynamicKey.self, forKey: .posts)
            for key in map.allKeys {
                guard let wire = try? map.decode(PostWire.self, forKey: key) else {
                    skipped += 1
                    continue
                }
                if wire.isEditHistoryRow {
                    editRows += 1
                    continue
                }
                // The map key must match the embedded id; otherwise ignore the entry.
                guard wire.post.id.rawValue == key.stringValue else {
                    skipped += 1
                    continue
                }
                posts[wire.post.id] = wire.post
            }
        }
        var seen = Set<PostID>()
        var order: [PostID] = []
        order.reserveCapacity(rawOrder.count)
        for raw in rawOrder {
            guard let id = PostID(rawValue: raw), posts[id] != nil, seen.insert(id).inserted else { continue }
            order.append(id)
        }
        self.order = order
        self.posts = posts
        self.nextPostID = c.optionalID(PostID.self, .next_post_id)
        self.previousPostID = c.optionalID(PostID.self, .prev_post_id)
        self.hasNext = c.lenientBool(.has_next)
        self.skippedMalformed = skipped
        self.droppedEditHistoryRows = editRows
    }

    /// Posts in `order` sequence.
    public var orderedPosts: [Post] { order.compactMap { posts[$0] } }
}
