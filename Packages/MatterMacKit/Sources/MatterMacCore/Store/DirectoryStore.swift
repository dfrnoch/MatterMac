public import MatterMacModels
public import MattermostAPI

/// How teammates' names are displayed (server preference `display_settings/name_format`,
/// falling back to the server's `TeammateNameDisplay`).
public enum NameFormat: String, Sendable, Hashable, Codable {
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
    /// Saved posts (`flagged_post` preferences, name = post id), capped at
    /// `ResourceBudget.savedPostIDs`; `savedPostsTruncated` records that the cap was hit.
    public private(set) var savedPosts: Set<PostID> = []
    public private(set) var savedPostsTruncated = false
    /// `display_settings/link_previews` ("false" hides website previews; default on).
    public var showsLinkPreviews = true
    private let savedPostLimit: Int
    private let channelLimit: Int
    /// Users that must not be evicted (current user, visible DM partners).
    public var pinnedUsers: [UserID: User] = [:]
    /// Server sidebar categories per team, in display order. Kept for at most
    /// `categoryTeamLimit` teams (least recently stored dropped first).
    public private(set) var categories: [TeamID: [SidebarCategory]] = [:]
    private var categoryTeamOrder: [TeamID] = []
    /// Teams whose categories could not be loaded; their sidebar is synthesized.
    public var categoriesUnavailable: Set<TeamID> = []
    /// `/users/me/teams/unread`, for teams whose channels are not loaded.
    public var teamUnreads: [TeamID: TeamUnread] = [:]
    /// Whether archived channels can be browsed (v10 setting; always on in v11).
    public var viewArchivedChannels = true
    /// Local, in-memory presentation choice ("Group unread channels separately").
    public var groupsUnreads = false
    /// The active channel stays in the Unreads group until the user leaves it.
    public var stickyUnread: ChannelID?
    /// Emoji the user reacted with, most recent first (bounded; kept in the cache).
    public private(set) var recentReactions: [String] = []
    public static let recentReactionLimit = 24
    /// Collapse changes being written to the server (at most one per category).
    public var pendingCollapse: [SidebarCategoryID: Bool] = [:]
    public static let categoryTeamLimit = 8
    public static let categoriesPerTeam = 500

    /// What the on-device cache keeps of the directory: enough to draw the sidebar,
    /// names and avatars before the network answers. Presence, typing, pending
    /// collapse writes and load state are not kept.
    public struct CacheSnapshot: Codable, Sendable {
        var teams: [Team]
        var channels: [Channel]
        var memberships: [ChannelMembership]
        /// Most recently used first.
        var users: [User]
        var categories: [TeamID: [SidebarCategory]]
        var categoryTeamOrder: [TeamID]
        var categoriesUnavailable: Set<TeamID>
        var teamUnreads: [TeamID: TeamUnread]
        var preferredNameFormat: NameFormat?
        var serverNameFormat: NameFormat
        var isNameFormatLocked: Bool
        var favorites: Set<ChannelID>
        var hiddenDirectPartners: Set<UserID>
        var hiddenGroups: Set<ChannelID>
        var collapsedThreadsPreference: Bool?
        var militaryTime: Bool
        var militaryTimePreference: Bool?
        var savedPosts: Set<PostID>
        var savedPostsTruncated: Bool
        var showsLinkPreviews: Bool
        var viewArchivedChannels: Bool
        /// Optional so caches written before it existed still decode.
        var recentReactions: [String]?
    }

    public func cacheSnapshot() -> CacheSnapshot {
        var cachedUsers = Array(pinnedUsers.values)
        let pinned = Set(pinnedUsers.keys)
        for id in users.keysByRecency where !pinned.contains(id) {
            if let user = users.peek(id) { cachedUsers.append(user) }
        }
        return CacheSnapshot(
            teams: Array(teams.values), channels: Array(channels.values), memberships: Array(memberships.values),
            users: cachedUsers, categories: categories, categoryTeamOrder: categoryTeamOrder,
            categoriesUnavailable: categoriesUnavailable, teamUnreads: teamUnreads,
            preferredNameFormat: preferredNameFormat, serverNameFormat: serverNameFormat,
            isNameFormatLocked: isNameFormatLocked, favorites: favorites, hiddenDirectPartners: hiddenDirectPartners,
            hiddenGroups: hiddenGroups, collapsedThreadsPreference: collapsedThreadsPreference,
            militaryTime: militaryTime, militaryTimePreference: militaryTimePreference, savedPosts: savedPosts,
            savedPostsTruncated: savedPostsTruncated, showsLinkPreviews: showsLinkPreviews,
            viewArchivedChannels: viewArchivedChannels, recentReactions: recentReactions)
    }

    /// Restores a cached directory into an empty store. No team counts as loaded, so
    /// every channel list is still fetched; the cached one is shown meanwhile. The
    /// usual limits apply to the restored values.
    public mutating func restore(_ snapshot: CacheSnapshot) {
        replaceTeams(snapshot.teams)
        for channel in snapshot.channels.prefix(channelLimit) where channel.teamID.map({ teams[$0] != nil }) ?? true {
            channels[channel.id] = channel
        }
        for membership in snapshot.memberships where channels[membership.channelID] != nil {
            memberships[membership.channelID] = membership
        }
        for user in snapshot.users.reversed() where pinnedUsers[user.id] == nil { upsertUser(user) }
        for team in snapshot.categoryTeamOrder where teams[team] != nil {
            if let list = snapshot.categories[team] { replaceCategories(team: team, list) }
        }
        categoriesUnavailable = snapshot.categoriesUnavailable.filter { teams[$0] != nil }
        teamUnreads = snapshot.teamUnreads.filter { teams[$0.key] != nil }
        preferredNameFormat = snapshot.preferredNameFormat
        serverNameFormat = snapshot.serverNameFormat
        isNameFormatLocked = snapshot.isNameFormatLocked
        favorites = snapshot.favorites
        hiddenDirectPartners = snapshot.hiddenDirectPartners
        hiddenGroups = snapshot.hiddenGroups
        collapsedThreadsPreference = snapshot.collapsedThreadsPreference
        militaryTime = snapshot.militaryTime
        militaryTimePreference = snapshot.militaryTimePreference
        savedPosts = Set(snapshot.savedPosts.prefix(savedPostLimit))
        savedPostsTruncated = snapshot.savedPostsTruncated || snapshot.savedPosts.count > savedPostLimit
        showsLinkPreviews = snapshot.showsLinkPreviews
        viewArchivedChannels = snapshot.viewArchivedChannels
        recentReactions = []
        for name in (snapshot.recentReactions ?? []).reversed() { noteReaction(name) }
    }

    /// Records a reaction the user added (moves it to the front).
    public mutating func noteReaction(_ name: String) {
        let name = name.lowercased()
        guard Reaction.isValidEmojiName(name) else { return }
        recentReactions.removeAll { $0 == name }
        recentReactions.insert(name, at: 0)
        if recentReactions.count > Self.recentReactionLimit { recentReactions.removeLast() }
    }

    public init(budget: ResourceBudget) {
        self.users = CostLRU(countLimit: budget.directoryDetails.count, costLimit: budget.directoryDetails.bytes)
        self.statuses = CostLRU(countLimit: max(64, budget.directoryDetails.count / 2),
                                costLimit: max(64, budget.directoryDetails.count / 2) * 64)
        self.channelLimit = budget.sidebarChannelsPerSession
        self.savedPostLimit = max(0, budget.savedPostIDs)
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
        removeCategories(team: id)
        teamUnreads[id] = nil
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

    // MARK: Sidebar categories

    /// Stores a team's categories (bounded per team and in total ids); the number of
    /// teams with retained categories is bounded by `categoryTeamLimit`.
    public mutating func replaceCategories(team: TeamID, _ list: [SidebarCategory]) {
        var budget = channelLimit
        var kept: [SidebarCategory] = []
        for var category in list.prefix(Self.categoriesPerTeam) where category.teamID == team {
            // A collapse change still being saved wins over an older server copy.
            if let collapsed = pendingCollapse[category.id] { category.isCollapsed = collapsed }
            if category.channelIDs.count > budget {
                category.channelIDs = Array(category.channelIDs.prefix(budget))
                // A truncated list must never be written back to the server.
                category.droppedChannelIDs += 1
            }
            budget -= category.channelIDs.count
            kept.append(category)
        }
        categories[team] = kept
        categoriesUnavailable.remove(team)
        categoryTeamOrder.removeAll { $0 == team }
        categoryTeamOrder.append(team)
        while categoryTeamOrder.count > Self.categoryTeamLimit {
            categories[categoryTeamOrder.removeFirst()] = nil
        }
    }

    public mutating func updateCategory(_ id: SidebarCategoryID, team: TeamID, _ body: (inout SidebarCategory) -> Void) {
        guard var list = categories[team], let index = list.firstIndex(where: { $0.id == id }) else { return }
        body(&list[index])
        categories[team] = list
    }

    public mutating func removeCategories(team: TeamID) {
        categories[team] = nil
        categoryTeamOrder.removeAll { $0 == team }
        categoriesUnavailable.remove(team)
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

    /// Known users among lowercased `usernames`, keyed by lowercased username. One
    /// pass over the bounded directory; recency is not touched and nothing is fetched.
    public func peekUsers(usernames: Set<String>) -> [String: User] {
        guard !usernames.isEmpty else { return [:] }
        var found: [String: User] = [:]
        func consider(_ user: User) {
            let key = user.username.lowercased()
            if found[key] == nil, usernames.contains(key) { found[key] = user }
        }
        for user in pinnedUsers.values { consider(user) }
        for id in users.keysByRecency {
            guard found.count < usernames.count else { break }
            if let user = users.peek(id) { consider(user) }
        }
        return found
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
            savedPosts.removeAll()
            savedPostsTruncated = false
            showsLinkPreviews = true
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
            case "link_previews":
                showsLinkPreviews = deleted || preference.value != "false"
            default:
                break
            }
        case "favorite_channel":
            if let id = ChannelID(rawValue: preference.name) {
                if !deleted && preference.value == "true" { favorites.insert(id) } else { favorites.remove(id) }
            }
        case "flagged_post":
            if let id = PostID(rawValue: preference.name) {
                if !deleted && preference.value == "true" {
                    if savedPosts.count < savedPostLimit || savedPosts.contains(id) { savedPosts.insert(id) }
                    else { savedPostsTruncated = true }
                } else {
                    savedPosts.remove(id)
                }
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
        savedPosts.removeAll()
        savedPostsTruncated = false
        categories.removeAll()
        categoryTeamOrder.removeAll()
        categoriesUnavailable.removeAll()
        teamUnreads.removeAll()
        stickyUnread = nil
        recentReactions.removeAll()
    }
}
