// Server-side sidebar organization (`GET /users/{id}/teams/{team}/channels/categories`,
// docs/research/channels.md §9) and team-level unread counts.

/// A sidebar category id: a normal 26-character id for custom categories, or
/// `{favorites|channels|direct_messages}_{userId}_{teamId}` for the default ones
/// (up to 69 characters). Used as a REST path component, so only `[a-z0-9_]` is
/// accepted.
public struct SidebarCategoryID: Hashable, Sendable, CustomStringConvertible, Comparable {
    public static let maximumLength = 96
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= Self.maximumLength,
              rawValue.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5f })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(unchecked rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SidebarCategory: Hashable, Sendable, Identifiable {
    /// `type`. Unknown values are kept verbatim so an update sends them back unchanged.
    public enum Kind: Hashable, Sendable {
        case favorites
        case channels
        case directMessages
        case custom
        /// v11 `managed` categories (feature flag `ManagedChannelCategories`).
        case managed
        case unknown(String)

        public init(wire: String) {
            switch wire {
            case "favorites": self = .favorites
            case "channels": self = .channels
            case "direct_messages": self = .directMessages
            case "custom": self = .custom
            case "managed": self = .managed
            default: self = .unknown(String(wire.prefix(32)))
            }
        }

        public var wireValue: String {
            switch self {
            case .favorites: "favorites"
            case .channels: "channels"
            case .directMessages: "direct_messages"
            case .custom: "custom"
            case .managed: "managed"
            case .unknown(let raw): raw
            }
        }
    }

    /// `sorting`. The server stores whatever an update sends, so unknown values are
    /// preserved verbatim.
    public enum Sorting: Hashable, Sendable {
        /// `""`: manual for every category except Direct Messages, which sorts by recency.
        case `default`
        case manual
        case recent
        case alphabetical
        case unknown(String)

        public init(wire: String) {
            switch wire {
            case "": self = .default
            case "manual": self = .manual
            case "recent": self = .recent
            case "alpha": self = .alphabetical
            default: self = .unknown(String(wire.prefix(32)))
            }
        }

        public var wireValue: String {
            switch self {
            case .default: ""
            case .manual: "manual"
            case .recent: "recent"
            case .alphabetical: "alpha"
            case .unknown(let raw): raw
            }
        }
    }

    public let id: SidebarCategoryID
    public let userID: UserID
    public let teamID: TeamID
    public var kind: Kind
    public var displayName: String
    public var sorting: Sorting
    public var sortOrder: Int64
    public var isMuted: Bool
    public var isCollapsed: Bool
    /// Channel order as stored on the server (the Channels and Direct Messages
    /// categories also include channels the server placed there implicitly).
    public var channelIDs: [ChannelID]
    /// Channel ids in the response that were not valid identifiers. A category with
    /// dropped ids is never written back: the server would remove those channels.
    public var droppedChannelIDs: Int

    public init(id: SidebarCategoryID, userID: UserID, teamID: TeamID, kind: Kind, displayName: String,
                sorting: Sorting = .default, sortOrder: Int64 = 0, isMuted: Bool = false, isCollapsed: Bool = false,
                channelIDs: [ChannelID] = [], droppedChannelIDs: Int = 0) {
        self.id = id
        self.userID = userID
        self.teamID = teamID
        self.kind = kind
        self.displayName = displayName
        self.sorting = sorting
        self.sortOrder = sortOrder
        self.isMuted = isMuted
        self.isCollapsed = isCollapsed
        self.channelIDs = channelIDs
        self.droppedChannelIDs = droppedChannelIDs
    }

    /// The sort actually applied: `""` behaves like manual, except for Direct Messages.
    public var effectiveSorting: Sorting {
        switch sorting {
        case .default, .unknown: kind == .directMessages ? .recent : .manual
        default: sorting
        }
    }
}

/// `GET /users/me/teams/unread` entry. Muted channels contribute mentions only.
public struct TeamUnread: Hashable, Sendable {
    public let teamID: TeamID
    public let messageCount: Int64
    public let mentionCount: Int64
    public let messageCountRoot: Int64
    public let mentionCountRoot: Int64

    public init(teamID: TeamID, messageCount: Int64, mentionCount: Int64, messageCountRoot: Int64 = 0,
                mentionCountRoot: Int64 = 0) {
        self.teamID = teamID
        self.messageCount = messageCount
        self.mentionCount = mentionCount
        self.messageCountRoot = messageCountRoot
        self.mentionCountRoot = mentionCountRoot
    }
}

/// Client-side channel URL-name rules, matching the server's
/// `IsValidChannelIdentifier` (`^[a-z0-9]+([a-z\-\_0-9]+|(__)?)[a-z0-9]*$`, at most
/// 64 bytes) and the official client's two-character minimum. Names that look like
/// DM (`<id>__<id>`) or GM (40 hex) names are refused by the server and here.
public enum ChannelNameRules {
    public static let minimumLength = 2
    public static let maximumLength = 64
    public static let maximumDisplayNameCharacters = 64
    public static let maximumPurposeCharacters = 250

    public enum Problem: Hashable, Sendable {
        case tooShort
        case tooLong
        case invalidCharacters
        /// Must start with a letter or digit.
        case invalidStart
        /// Reserved for direct and group message channels.
        case reserved
    }

    /// The official client's `cleanUpUrlable`: lowercase, runs of anything outside
    /// `[a-z0-9]` become one `-`, trimmed of leading/trailing `-`, at most 64 bytes.
    public static func slug(from displayName: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in displayName.lowercased().unicodeScalars {
            let isAlphanumeric = (scalar.value >= 0x61 && scalar.value <= 0x7a) || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isAlphanumeric || scalar == "_" {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
            if result.utf8.count >= maximumLength { break }
        }
        var trimmed = String(result.prefix(maximumLength))
        while trimmed.hasSuffix("-") || trimmed.hasSuffix("_") { trimmed.removeLast() }
        while trimmed.hasPrefix("_") { trimmed.removeFirst() }
        return trimmed
    }

    public static func problem(with name: String) -> Problem? {
        let bytes = Array(name.utf8)
        guard bytes.count >= minimumLength else { return .tooShort }
        guard bytes.count <= maximumLength else { return .tooLong }
        func alphanumeric(_ byte: UInt8) -> Bool { (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39) }
        guard bytes.allSatisfy({ alphanumeric($0) || $0 == 0x2d || $0 == 0x5f }) else { return .invalidCharacters }
        guard alphanumeric(bytes[0]) else { return .invalidStart }
        let parts = name.components(separatedBy: "__")
        if parts.count == 2, parts.allSatisfy({ $0.utf8.count == 26 }) { return .reserved }
        if bytes.count == 40, bytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) { return .reserved }
        return nil
    }
}
