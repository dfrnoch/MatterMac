public import Foundation

// Presentation-neutral domain values. Wire DTOs live in MattermostAPI and are mapped
// explicitly into these types; nothing here retains raw server responses.

public enum ChannelType: Hashable, Sendable {
    case open
    case `private`
    case direct
    case group
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "O": self = .open
        case "P": self = .private
        case "D": self = .direct
        case "G": self = .group
        default: self = .unknown(String(wire.prefix(8)))
        }
    }

    public var wireValue: String {
        switch self {
        case .open: "O"
        case .private: "P"
        case .direct: "D"
        case .group: "G"
        case .unknown(let raw): raw
        }
    }

    public var isDirectOrGroup: Bool { self == .direct || self == .group }
}

public struct Team: Hashable, Sendable, Identifiable {
    public let id: TeamID
    public var name: String
    public var displayName: String
    public var isOpenInvite: Bool
    public var deleteAt: MattermostTimestamp
    /// `last_team_icon_update`; 0 means the team has no custom icon.
    public var iconRevision: Int64

    public init(id: TeamID, name: String, displayName: String, isOpenInvite: Bool = false,
                deleteAt: MattermostTimestamp = .zero, iconRevision: Int64 = 0) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.isOpenInvite = isOpenInvite
        self.deleteAt = deleteAt
        self.iconRevision = iconRevision
    }
}

public struct Channel: Hashable, Sendable, Identifiable {
    public let id: ChannelID
    /// Empty for direct and group messages.
    public var teamID: TeamID?
    public var type: ChannelType
    public var name: String
    public var displayName: String
    public var header: String
    public var purpose: String
    public var lastPostAt: MattermostTimestamp
    public var lastRootPostAt: MattermostTimestamp
    public var totalMessageCount: Int64
    public var totalMessageCountRoot: Int64
    public var deleteAt: MattermostTimestamp
    public var creatorID: UserID?
    public var isGroupConstrained: Bool
    public var isShared: Bool

    public init(id: ChannelID, teamID: TeamID?, type: ChannelType, name: String, displayName: String,
                header: String = "", purpose: String = "",
                lastPostAt: MattermostTimestamp = .zero, lastRootPostAt: MattermostTimestamp = .zero,
                totalMessageCount: Int64 = 0, totalMessageCountRoot: Int64 = 0,
                deleteAt: MattermostTimestamp = .zero, creatorID: UserID? = nil,
                isGroupConstrained: Bool = false, isShared: Bool = false) {
        self.id = id
        self.teamID = teamID
        self.type = type
        self.name = name
        self.displayName = displayName
        self.header = header
        self.purpose = purpose
        self.lastPostAt = lastPostAt
        self.lastRootPostAt = lastRootPostAt
        self.totalMessageCount = totalMessageCount
        self.totalMessageCountRoot = totalMessageCountRoot
        self.deleteAt = deleteAt
        self.creatorID = creatorID
        self.isGroupConstrained = isGroupConstrained
        self.isShared = isShared
    }

    public var isArchived: Bool { !deleteAt.isZero }

    /// For a direct channel named `<userA>__<userB>`, the other participant.
    public func directPartner(of me: UserID) -> UserID? {
        guard type == .direct else { return nil }
        let parts = name.components(separatedBy: "__")
        guard parts.count == 2 else { return nil }
        let ids = parts.compactMap { UserID(rawValue: $0) }
        guard ids.count == 2 else { return nil }
        if ids[0] == me { return ids[1] }
        if ids[1] == me { return ids[0] }
        return nil
    }
}

public enum MarkUnreadLevel: Hashable, Sendable {
    case all
    case mention
}

public struct ChannelMembership: Hashable, Sendable {
    public let channelID: ChannelID
    public let userID: UserID
    public var roles: [String]
    public var lastViewedAt: MattermostTimestamp
    public var messageCount: Int64
    public var messageCountRoot: Int64
    public var mentionCount: Int64
    public var mentionCountRoot: Int64
    public var urgentMentionCount: Int64
    public var lastUpdateAt: MattermostTimestamp
    public var markUnread: MarkUnreadLevel
    /// `notify_props.desktop` for this channel.
    public var desktop: ChannelDesktopLevel
    /// `notify_props.ignore_channel_mentions`.
    public var ignoreChannelMentions: IgnoreChannelMentions

    public init(channelID: ChannelID, userID: UserID, roles: [String] = [],
                lastViewedAt: MattermostTimestamp = .zero, messageCount: Int64 = 0,
                messageCountRoot: Int64 = 0, mentionCount: Int64 = 0, mentionCountRoot: Int64 = 0,
                urgentMentionCount: Int64 = 0, lastUpdateAt: MattermostTimestamp = .zero,
                markUnread: MarkUnreadLevel = .all, desktop: ChannelDesktopLevel = .default,
                ignoreChannelMentions: IgnoreChannelMentions = .default) {
        self.channelID = channelID
        self.userID = userID
        self.roles = roles
        self.lastViewedAt = lastViewedAt
        self.messageCount = messageCount
        self.messageCountRoot = messageCountRoot
        self.mentionCount = mentionCount
        self.mentionCountRoot = mentionCountRoot
        self.urgentMentionCount = urgentMentionCount
        self.lastUpdateAt = lastUpdateAt
        self.markUnread = markUnread
        self.desktop = desktop
        self.ignoreChannelMentions = ignoreChannelMentions
    }

    public var isChannelAdmin: Bool { roles.contains("channel_admin") }
}

public struct User: Hashable, Sendable, Identifiable {
    public let id: UserID
    public var username: String
    public var firstName: String
    public var lastName: String
    public var nickname: String
    public var position: String
    public var isBot: Bool
    public var deleteAt: MattermostTimestamp
    public var lastPictureUpdate: MattermostTimestamp
    public var locale: String
    public var roles: [String]
    /// Empty unless the server's privacy settings expose it to this account.
    public var email: String
    /// Effective IANA time zone (automatic or manual per the user's setting).
    public var timeZoneIdentifier: String?
    public var customStatus: CustomStatus?
    /// Only present for the signed-in user (the server sanitizes it for others).
    public var notifyProps: UserNotifyProps?

    public init(id: UserID, username: String, firstName: String = "", lastName: String = "",
                nickname: String = "", position: String = "", isBot: Bool = false,
                deleteAt: MattermostTimestamp = .zero, lastPictureUpdate: MattermostTimestamp = .zero,
                locale: String = "", roles: [String] = [], email: String = "", timeZoneIdentifier: String? = nil,
                customStatus: CustomStatus? = nil, notifyProps: UserNotifyProps? = nil) {
        self.id = id
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.position = position
        self.isBot = isBot
        self.deleteAt = deleteAt
        self.lastPictureUpdate = lastPictureUpdate
        self.locale = locale
        self.roles = roles
        self.email = email
        self.timeZoneIdentifier = timeZoneIdentifier
        self.customStatus = customStatus
        self.notifyProps = notifyProps
    }

    public var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isDeactivated: Bool { !deleteAt.isZero }
    public var isSystemAdmin: Bool { roles.contains("system_admin") }
    public var isGuest: Bool { roles.contains("system_guest") }
}

/// "Clear after" choices offered by the official clients (`CustomStatus.duration`).
public enum CustomStatusDuration: String, CaseIterable, Hashable, Sendable {
    case dontClear = ""
    case thirtyMinutes = "thirty_minutes"
    case oneHour = "one_hour"
    case fourHours = "four_hours"
    case today
    case thisWeek = "this_week"

    /// Expiry in the user's time zone; `nil` for "don't clear".
    public func expiry(from now: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch self {
        case .dontClear: return nil
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .fourHours: return now.addingTimeInterval(4 * 60 * 60)
        case .today: return calendar.dateInterval(of: .day, for: now).map { $0.end.addingTimeInterval(-1) }
        case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now).map { $0.end.addingTimeInterval(-1) }
        }
    }
}

/// `user.props["customStatus"]`. Expired statuses must be hidden by the presenter.
public struct CustomStatus: Hashable, Sendable {
    public var emoji: String
    public var text: String
    /// `nil` means the status does not expire.
    public var expiresAt: Date?

    public init(emoji: String, text: String, expiresAt: Date? = nil) {
        self.emoji = emoji
        self.text = text
        self.expiresAt = expiresAt
    }

    public func isVisible(at now: Date) -> Bool {
        guard !emoji.isEmpty || !text.isEmpty else { return false }
        return expiresAt.map { $0 > now } ?? true
    }
}

public enum PresenceStatus: Hashable, Sendable {
    case online
    case away
    case doNotDisturb
    case offline
    case unknown

    public init(wire: String) {
        switch wire {
        case "online": self = .online
        case "away": self = .away
        case "dnd": self = .doNotDisturb
        case "offline": self = .offline
        default: self = .unknown
        }
    }

    /// Value accepted by `PUT /users/{id}/status`; `nil` for `.unknown`.
    public var wireValue: String? {
        switch self {
        case .online: "online"
        case .away: "away"
        case .doNotDisturb: "dnd"
        case .offline: "offline"
        case .unknown: nil
        }
    }
}

public struct PostType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = String(rawValue.prefix(64)) }

    public static let normal = PostType(rawValue: "")
    public static let joinChannel = PostType(rawValue: "system_join_channel")
    public static let leaveChannel = PostType(rawValue: "system_leave_channel")
    public static let addToChannel = PostType(rawValue: "system_add_to_channel")
    public static let removeFromChannel = PostType(rawValue: "system_remove_from_channel")
    public static let joinTeam = PostType(rawValue: "system_join_team")
    public static let leaveTeam = PostType(rawValue: "system_leave_team")
    public static let addToTeam = PostType(rawValue: "system_add_to_team")
    public static let removeFromTeam = PostType(rawValue: "system_remove_from_team")
    public static let headerChange = PostType(rawValue: "system_header_change")
    public static let displayNameChange = PostType(rawValue: "system_displayname_change")
    public static let purposeChange = PostType(rawValue: "system_purpose_change")
    public static let channelDeleted = PostType(rawValue: "system_channel_deleted")
    public static let channelRestored = PostType(rawValue: "system_channel_restored")
    public static let ephemeral = PostType(rawValue: "system_ephemeral")
    public static let convertChannel = PostType(rawValue: "system_change_chan_privacy")
    public static let combinedUserActivity = PostType(rawValue: "system_combined_user_activity")
    public static let calls = PostType(rawValue: "custom_calls")

    public var isSystem: Bool { rawValue.hasPrefix("system_") }
    public var isCustomPlugin: Bool { rawValue.hasPrefix("custom_") }
}

public struct Reaction: Hashable, Sendable {
    public let userID: UserID
    public let postID: PostID
    public let emojiName: String
    public var createAt: MattermostTimestamp

    public init(userID: UserID, postID: PostID, emojiName: String, createAt: MattermostTimestamp = .zero) {
        self.userID = userID
        self.postID = postID
        self.emojiName = emojiName
        self.createAt = createAt
    }

    /// Mattermost emoji names are 1–64 chars of `[a-z0-9_+-]` (case-insensitive on
    /// input). Anything else is rejected before it is placed into a URL path.
    public static func isValidEmojiName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64 else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "+"):
                true
            default:
                false
            }
        }
    }
}

public struct FileInfo: Hashable, Sendable, Identifiable {
    public let id: FileID
    public var postID: PostID?
    public var channelID: ChannelID?
    public var name: String
    public var fileExtension: String
    public var size: Int64
    public var mimeType: String
    public var width: Int?
    public var height: Int?
    public var hasPreviewImage: Bool
    /// Tiny server-provided JPEG thumbnail. Bounded at decode time.
    public var miniPreview: Data?
    public var createAt: MattermostTimestamp
    public var deleteAt: MattermostTimestamp

    public init(id: FileID, postID: PostID? = nil, channelID: ChannelID? = nil, name: String,
                fileExtension: String = "", size: Int64 = 0, mimeType: String = "",
                width: Int? = nil, height: Int? = nil, hasPreviewImage: Bool = false,
                miniPreview: Data? = nil, createAt: MattermostTimestamp = .zero,
                deleteAt: MattermostTimestamp = .zero) {
        self.id = id
        self.postID = postID
        self.channelID = channelID
        self.name = name
        self.fileExtension = fileExtension
        self.size = size
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.hasPreviewImage = hasPreviewImage
        self.miniPreview = miniPreview
        self.createAt = createAt
        self.deleteAt = deleteAt
    }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// A basic Slack-style message attachment (`props.attachments`), reduced to the
/// fields MatterMac renders natively. Interactive actions are not executed.
public struct MessageAttachment: Hashable, Sendable {
    public struct Field: Hashable, Sendable {
        public var title: String
        public var value: String
        public var isShort: Bool
        public init(title: String, value: String, isShort: Bool) {
            self.title = title
            self.value = value
            self.isShort = isShort
        }
    }

    public var fallback: String
    public var color: String
    public var pretext: String
    public var authorName: String
    public var title: String
    public var titleLink: String
    public var text: String
    public var fields: [Field]
    public var footer: String
    /// `true` when the attachment declared interactive actions we do not execute.
    public var hasUnsupportedActions: Bool

    public init(fallback: String = "", color: String = "", pretext: String = "", authorName: String = "",
                title: String = "", titleLink: String = "", text: String = "", fields: [Field] = [],
                footer: String = "", hasUnsupportedActions: Bool = false) {
        self.fallback = fallback
        self.color = color
        self.pretext = pretext
        self.authorName = authorName
        self.title = title
        self.titleLink = titleLink
        self.text = text
        self.fields = fields
        self.footer = footer
        self.hasUnsupportedActions = hasUnsupportedActions
    }
}

/// The subset of `post.props` MatterMac understands. Unknown plugin props are not
/// retained; `hasUnsupportedContent` records that something was not rendered.
public struct PostProps: Hashable, Sendable {
    public var fromWebhook: Bool
    public var fromBot: Bool
    public var overrideUsername: String?
    public var attachments: [MessageAttachment]
    /// Small string context for system posts (e.g. `username`, `addedUsername`,
    /// `old_header`, `new_header`). Bounded at decode time.
    public var systemContext: [String: String]
    public var hasUnsupportedContent: Bool

    public init(fromWebhook: Bool = false, fromBot: Bool = false, overrideUsername: String? = nil,
                attachments: [MessageAttachment] = [], systemContext: [String: String] = [:],
                hasUnsupportedContent: Bool = false) {
        self.fromWebhook = fromWebhook
        self.fromBot = fromBot
        self.overrideUsername = overrideUsername
        self.attachments = attachments
        self.systemContext = systemContext
        self.hasUnsupportedContent = hasUnsupportedContent
    }

    public static let empty = PostProps()
}

public struct Post: Hashable, Sendable, Identifiable {
    public let id: PostID
    public var channelID: ChannelID
    public var userID: UserID
    /// Root of the thread this post replies to; `nil` for root posts.
    public var rootID: PostID?
    public var message: String
    public var type: PostType
    public var createAt: MattermostTimestamp
    public var updateAt: MattermostTimestamp
    public var editAt: MattermostTimestamp
    public var deleteAt: MattermostTimestamp
    public var isPinned: Bool
    public var fileIDs: [FileID]
    public var files: [FileInfo]
    public var reactions: [Reaction]
    /// `true` when the server-reported reaction list exceeded our retention cap.
    public var reactionsTruncated: Bool
    public var hasReactions: Bool
    public var pendingPostID: PendingPostID?
    public var replyCount: Int
    public var lastReplyAt: MattermostTimestamp
    public var props: PostProps
    /// Server-provided preview of the post's first link (`metadata.embeds`), if any.
    public var linkPreview: LinkPreview?

    public init(id: PostID, channelID: ChannelID, userID: UserID, rootID: PostID? = nil, message: String,
                type: PostType = .normal, createAt: MattermostTimestamp,
                updateAt: MattermostTimestamp? = nil, editAt: MattermostTimestamp = .zero,
                deleteAt: MattermostTimestamp = .zero, isPinned: Bool = false, fileIDs: [FileID] = [],
                files: [FileInfo] = [], reactions: [Reaction] = [], reactionsTruncated: Bool = false,
                hasReactions: Bool = false, pendingPostID: PendingPostID? = nil, replyCount: Int = 0,
                lastReplyAt: MattermostTimestamp = .zero, props: PostProps = .empty, linkPreview: LinkPreview? = nil) {
        self.id = id
        self.channelID = channelID
        self.userID = userID
        self.rootID = rootID
        self.message = message
        self.type = type
        self.createAt = createAt
        self.updateAt = updateAt ?? createAt
        self.editAt = editAt
        self.deleteAt = deleteAt
        self.isPinned = isPinned
        self.fileIDs = fileIDs
        self.files = files
        self.reactions = reactions
        self.reactionsTruncated = reactionsTruncated
        self.hasReactions = hasReactions || !reactions.isEmpty
        self.pendingPostID = pendingPostID
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.props = props
        self.linkPreview = linkPreview
    }

    public var isDeleted: Bool { !deleteAt.isZero }
    public var isEdited: Bool { !editAt.isZero }
    public var isReply: Bool { rootID != nil }
    /// The thread root for this post (itself when it is a root).
    public var threadRootID: PostID { rootID ?? id }
}
