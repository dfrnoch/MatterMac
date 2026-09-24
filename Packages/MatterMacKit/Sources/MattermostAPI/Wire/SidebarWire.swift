import Foundation
public import MatterMacModels

// Sidebar categories, team unread counts and channel member counts
// (docs/research/channels.md §1, §5, §9; model/channel_sidebar.go).

/// One `SidebarCategoryWithChannels`.
public struct SidebarCategoryWire: Decodable, Sendable {
    /// Upper bound on channel ids kept per category.
    public static let maximumChannels = 10_000
    public let category: SidebarCategory

    enum Keys: String, CodingKey {
        case id, user_id, team_id, sort_order, sorting, type, display_name, muted, collapsed, channel_ids
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = (c.lenientString(.id, maxBytes: 256)).flatMap(SidebarCategoryID.init(rawValue:)) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "invalid category id")
        }
        let raw = (try? c.decodeIfPresent([String].self, forKey: .channel_ids)) ?? []
        guard raw.count <= Self.maximumChannels else {
            throw DecodingError.dataCorruptedError(forKey: .channel_ids, in: c, debugDescription: "too many channels")
        }
        var seen = Set<ChannelID>()
        var channels: [ChannelID] = []
        var dropped = 0
        for value in raw {
            guard let channel = ChannelID(rawValue: value) else { dropped += 1; continue }
            if seen.insert(channel).inserted { channels.append(channel) }
        }
        category = SidebarCategory(
            id: id,
            userID: try c.requiredID(UserID.self, .user_id),
            teamID: try c.requiredID(TeamID.self, .team_id),
            kind: SidebarCategory.Kind(wire: c.lenientString(.type, maxBytes: 64) ?? ""),
            displayName: String((c.lenientString(.display_name, maxBytes: 1_024) ?? "").prefix(128)),
            sorting: SidebarCategory.Sorting(wire: c.lenientString(.sorting, maxBytes: 64) ?? ""),
            sortOrder: c.lenientInt64(.sort_order) ?? 0,
            isMuted: c.lenientBool(.muted) ?? false,
            isCollapsed: c.lenientBool(.collapsed) ?? false,
            channelIDs: channels,
            droppedChannelIDs: dropped)
    }
}

/// `OrderedSidebarCategories`: categories plus their display `order`. Categories are
/// returned in `order`; unknown or malformed entries are skipped, and categories
/// missing from `order` follow in response order.
public struct OrderedSidebarCategoriesWire: Decodable, Sendable {
    public static let maximumCategories = 500
    public let categories: [SidebarCategory]

    enum Keys: String, CodingKey { case categories, order }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let list = try c.decode(LossyArray<SidebarCategoryWire>.self, forKey: .categories).elements.map(\.category)
        guard list.count <= Self.maximumCategories else {
            throw DecodingError.dataCorruptedError(forKey: .categories, in: c, debugDescription: "too many categories")
        }
        let order = ((try? c.decodeIfPresent([String].self, forKey: .order)) ?? []).prefix(Self.maximumCategories)
        var byID: [SidebarCategoryID: SidebarCategory] = [:]
        for category in list where byID[category.id] == nil { byID[category.id] = category }
        var result: [SidebarCategory] = []
        var placed = Set<SidebarCategoryID>()
        for raw in order {
            guard let id = SidebarCategoryID(rawValue: raw), let category = byID[id], placed.insert(id).inserted else { continue }
            result.append(category)
        }
        for category in list where placed.insert(category.id).inserted { result.append(category) }
        categories = result
    }
}

/// `PUT …/categories/{id}` body: the whole category with its channel list.
struct SidebarCategoryBody: Encodable {
    let id: String
    let user_id: String
    let team_id: String
    let sort_order: Int64
    let sorting: String
    let type: String
    let display_name: String
    let muted: Bool
    let collapsed: Bool
    let channel_ids: [String]

    init(_ category: SidebarCategory) {
        id = category.id.rawValue
        user_id = category.userID.rawValue
        team_id = category.teamID.rawValue
        sort_order = category.sortOrder
        sorting = category.sorting.wireValue
        type = category.kind.wireValue
        display_name = category.displayName
        muted = category.isMuted
        collapsed = category.isCollapsed
        channel_ids = category.channelIDs.map(\.rawValue)
    }
}

public struct TeamUnreadWire: Decodable, Sendable {
    public let unread: TeamUnread
    enum Keys: String, CodingKey { case team_id, msg_count, mention_count, msg_count_root, mention_count_root }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        unread = TeamUnread(
            teamID: try c.requiredID(TeamID.self, .team_id),
            messageCount: max(0, c.lenientInt64(.msg_count) ?? 0),
            mentionCount: max(0, c.lenientInt64(.mention_count) ?? 0),
            messageCountRoot: max(0, c.lenientInt64(.msg_count_root) ?? 0),
            mentionCountRoot: max(0, c.lenientInt64(.mention_count_root) ?? 0))
    }
}

/// `POST /channels/stats/member_count` response: `{channel_id: count}`.
public struct ChannelMemberCountsWire: Decodable, Sendable {
    public let counts: [ChannelID: Int]
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Int64].self)
        var counts: [ChannelID: Int] = [:]
        for (key, value) in raw.prefix(1_000) {
            if let id = ChannelID(rawValue: key) { counts[id] = Int(clamping: max(0, value)) }
        }
        self.counts = counts
    }
}

/// `POST /channels` body. `type` is `O` or `P`.
struct CreateChannelBody: Encodable {
    let team_id: String
    let name: String
    let display_name: String
    let purpose: String
    let type: String
}

/// `POST /channels/{id}/members`: `user_id` for one user, `user_ids` for several.
struct AddChannelMembersBody: Encodable {
    let user_id: String?
    let user_ids: [String]?
}

/// `POST /users/search`.
struct UserSearchBody: Encodable {
    let term: String
    let team_id: String
    let not_in_channel_id: String?
    let allow_inactive: Bool
    let limit: Int
}
