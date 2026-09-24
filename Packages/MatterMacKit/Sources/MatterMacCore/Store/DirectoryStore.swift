public import MatterMacModels
public import MattermostAPI

/// How teammates' names are displayed (server preference `display_settings/name_format`,
/// falling back to the server's `TeammateNameDisplay`).
public enum NameFormat: String, Sendable, Hashable {
    case username
    case nicknameFullName = "nickname_full_name"
    case fullName = "full_name"

    public func displayName(for user: User) -> String {
        switch self {
        case .username:
            return user.username
        case .nicknameFullName:
            if !user.nickname.isEmpty { return user.nickname }
            let full = user.fullName
            return full.isEmpty ? user.username : full
        case .fullName:
            let full = user.fullName
            return full.isEmpty ? user.username : full
        }
    }
}

/// Session-scoped summaries of teams, channels, memberships, users, and presence.
/// Everything is bounded: channel summaries by `sidebarChannelsPerSession`, user
/// details by `directoryDetails` (LRU with cost), presence by count.
public struct DirectoryStore: Sendable {
    public private(set) var teams: [TeamID: Team] = [:]
    public private(set) var channels: [ChannelID: Channel] = [:]
    public private(set) var memberships: [ChannelID: ChannelMembership] = [:]
    /// Teams whose channel list has been loaded at least once.
    public private(set) var loadedTeams: Set<TeamID> = []
    public private(set) var channelsTruncated = false
    private var users: CostLRU<UserID, User>
    private var statuses: CostLRU<UserID, PresenceStatus>
    /// The user's `display_settings/name_format` preference, when set.
    public private(set) var preferredNameFormat: NameFormat?
    /// The server's `TeammateNameDisplay` default and whether it is locked.
    public var serverNameFormat: NameFormat = .username
    public var isNameFormatLocked = false
    /// Effective format, as in the official client: a locked server setting wins,
    /// then the user's preference, then the server default.
    public var nameFormat: NameFormat {
        isNameFormatLocked ? serverNameFormat : (preferredNameFormat ?? serverNameFormat)
    }
    public var favorites: Set<ChannelID> = []
    /// DM partners hidden via `direct_channel_show=false` (name = teammate id).
    public var hiddenDirectPartners: Set<UserID> = []
    /// GMs hidden via `group_channel_show=false` (name = channel id).
    public var hiddenGroups: Set<ChannelID> = []
    public var collapsedThreadsPreference: Bool?
    public var militaryTime = false
    /// `use_military_time` when set; `nil` when the user never chose.
    public var militaryTimePreference: Bool?
    private let channelLimit: Int
    /// Users that must not be evicted (current user, visible DM partners).
    public var pinnedUsers: [UserID: User] = [:]

    public init(budget: ResourceBudget) {
        self.users = CostLRU(countLimit: budget.directoryDetails.count, costLimit: budget.directoryDetails.bytes)
        self.statuses = CostLRU(countLimit: max(64, budget.directoryDetails.count / 2),
                                costLimit: max(64, budget.directoryDetails.count / 2) * 64)
        self.channelLimit = budget.sidebarChannelsPerSession
    }

    // MARK: Teams

    public mutating func replaceTeams(_ list: [Team]) {
        teams = Dictionary(list.filter { $0.deleteAt.isZero }.prefix(500).map { ($0.id, $0) },
                           uniquingKeysWith: { first, _ in first })
    }

    public mutating func upsertTeam(_ team: Team) {
        if team.deleteAt.isZero { teams[team.id] = team } else { teams[team.id] = nil }
    }

    public mutating func removeTeam(_ id: TeamID) -> [ChannelID] {
        teams[id] = nil
        loadedTeams.remove(id)
        let removed = channels.values.filter { $0.teamID == id }.map(\.id)
        for channel in removed {
            channels[channel] = nil
            memberships[channel] = nil
        }
        return removed
    }

    public var sortedTeams: [Team] {
        teams.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: Channels

    /// Replaces the channel set of a team (plus DMs/GMs, which the server includes in
    /// every team's list). Returns channels that disappeared (membership revoked or
    /// left while we were not listening) so the caller can purge their content.
    public mutating func replaceChannels(team: TeamID, channels list: [Channel], memberships members: [ChannelMembership])
        -> [ChannelID]
    {
        let keep = list.filter { channel in
            switch channel.type {
            case .open, .private, .direct, .group: true
            case .unknown: false
            }
        }
        let memberSet = Dictionary(members.map { ($0.channelID, $0) }, uniquingKeysWith: { first, _ in first })
        // Only channels with a membership are ours.
        let owned = keep.filter { memberSet[$0.id] != nil }
        let newIDs = Set(owned.map(\.id))
        let previous = channels.values.filter { $0.teamID == team || ($0.teamID == nil && loadedTeams.contains(team)) }
        let vanished = previous.map(\.id).filter { !newIDs.contains($0) }
        for id in vanished {
            channels[id] = nil
            memberships[id] = nil
        }
        for channel in owned {
            guard channels.count < channelLimit || channels[channel.id] != nil else {
                channelsTruncated = true
                continue
            }
            channels[channel.id] = channel
            memberships[channel.id] = memberSet[channel.id]
        }
        loadedTeams.insert(team)
        return vanished
    }

    public mutating func upsertChannel(_ channel: Channel) {
        guard channels[channel.id] != nil || channels.count < channelLimit else {
            channelsTruncated = true
            return
        }
        channels[channel.id] = channel
    }

    public mutating func upsertMembership(_ membership: ChannelMembership) {
        guard channels[membership.channelID] != nil else { return }
        memberships[membership.channelID] = membership
    }

    @discardableResult
    public mutating func removeChannel(_ id: ChannelID) -> Channel? {
        memberships[id] = nil
        favorites.remove(id)
        return channels.removeValue(forKey: id)
    }

    public mutating func updateChannel(_ id: ChannelID, _ body: (inout Channel) -> Void) {
        guard var channel = channels[id] else { return }
        body(&channel)
        channels[id] = channel
    }

    public mutating func updateMembership(_ id: ChannelID, _ body: (inout ChannelMembership) -> Void) {
        guard var membership = memberships[id] else { return }
        body(&membership)
        memberships[id] = membership
    }

    /// Unread computation matching the official web client (channel_utils.ts).
    public func unread(for id: ChannelID, collapsedThreads: Bool) -> (isUnread: Bool, messages: Int64, mentions: Int64) {
        guard let channel = channels[id], let member = memberships[id] else { return (false, 0, 0) }
        let messages = collapsedThreads
            ? channel.totalMessageCountRoot - member.messageCountRoot
            : channel.totalMessageCount - member.messageCount
        let mentions = collapsedThreads ? member.mentionCountRoot : member.mentionCount
        let muted = member.markUnread == .mention
        return (mentions > 0 || (!muted && messages > 0), max(0, messages), max(0, mentions))
    }

    // MARK: Users

    public mutating func upsertUser(_ user: User) {
        if pinnedUsers[user.id] != nil { pinnedUsers[user.id] = user }
        users.set(user, for: user.id, cost: 256 + user.username.utf8.count + user.firstName.utf8.count
            + user.lastName.utf8.count + user.nickname.utf8.count + user.position.utf8.count + user.email.utf8.count
            + (user.timeZoneIdentifier?.utf8.count ?? 0)
            + (user.customStatus.map { $0.emoji.utf8.count + $0.text.utf8.count + 16 } ?? 0))
    }

    public mutating func pin(_ user: User) {
        pinnedUsers[user.id] = user
        upsertUser(user)
    }

    public mutating func user(_ id: UserID) -> User? {
        pinnedUsers[id] ?? users.value(for: id)
    }

    public func peekUser(_ id: UserID) -> User? {
        pinnedUsers[id] ?? users.peek(id)
    }

    public mutating func setStatus(_ status: PresenceStatus, for user: UserID) {
        statuses.set(status, for: user, cost: 64)
    }

    public func status(of user: UserID) -> PresenceStatus? { statuses.peek(user) }

    // MARK: Preferences

    public mutating func applyPreferences(_ preferences: [Preference], replacing: Bool) {
        if replacing {
            preferredNameFormat = nil
            collapsedThreadsPreference = nil
            militaryTime = false
            militaryTimePreference = nil
            favorites.removeAll()
            hiddenDirectPartners.removeAll()
            hiddenGroups.removeAll()
        }
        for preference in preferences { apply(preference, deleted: false) }
    }

    public mutating func apply(_ preference: Preference, deleted: Bool) {
        switch preference.category {
        case "display_settings":
            switch preference.name {
            case "name_format":
                preferredNameFormat = deleted ? nil : NameFormat(rawValue: preference.value)
            case "collapsed_reply_threads":
                collapsedThreadsPreference = deleted ? nil : (preference.value == "on")
            case "use_military_time":
                militaryTime = !deleted && preference.value == "true"
                militaryTimePreference = deleted ? nil : preference.value == "true"
            default:
                break
            }
        case "favorite_channel":
            if let id = ChannelID(rawValue: preference.name) {
                if !deleted && preference.value == "true" { favorites.insert(id) } else { favorites.remove(id) }
            }
        case "direct_channel_show":
            if let id = UserID(rawValue: preference.name) {
                if !deleted && preference.value == "false" { hiddenDirectPartners.insert(id) } else { hiddenDirectPartners.remove(id) }
            }
        case "group_channel_show":
            if let id = ChannelID(rawValue: preference.name) {
                if !deleted && preference.value == "false" { hiddenGroups.insert(id) } else { hiddenGroups.remove(id) }
            }
        default:
            break
        }
    }

    public mutating func removeAll() {
        teams.removeAll()
        channels.removeAll()
        memberships.removeAll()
        loadedTeams.removeAll()
        users.removeAll()
        statuses.removeAll()
        pinnedUsers.removeAll()
        favorites.removeAll()
    }
}
