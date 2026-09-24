import Foundation
import os
public import MatterMacModels
public import MattermostAPI

/// Scriptable state for sidebar categories, channel browsing and membership.
/// Without explicit categories the fake behaves like the server: it creates the
/// three default categories and places favorites (`favorite_channel` preferences),
/// team channels and DMs/GMs into them.
public struct DirectoryState: Sendable {
    public var categories: [TeamID: [SidebarCategory]] = [:]
    public var categoriesError: APIError?
    public var updateCategoryError: APIError?
    public var updatedCategories: [SidebarCategory] = []
    public var teamUnreads: [TeamUnread] = []
    /// Public channels of a team that the user may or may not belong to.
    public var publicChannels: [TeamID: [Channel]] = [:]
    public var archivedChannels: [TeamID: [Channel]] = [:]
    public var memberCounts: [ChannelID: Int] = [:]
    public var createdChannels: [NewChannelRequest] = []
    public var createChannelError: APIError?
    public var createdGroups: [[UserID]] = []
    public var addedMembers: [(ChannelID, [UserID])] = []
    public var addMembersError: APIError?
    public var userSearches: [UserSearchQuery] = []
    public var favorites: Set<ChannelID> = []

    public init() {}
}

extension FakeMattermostService {
    public func withDirectory<T: Sendable>(_ body: @Sendable (inout DirectoryState) -> T) -> T {
        directory.withLock { body(&$0) }
    }

    private func note(_ call: String) { withState { $0.calls.append(call) } }

    /// The categories the fake server would return now.
    public func currentCategories(team: TeamID) -> [SidebarCategory] {
        let explicit = directory.withLock { $0.categories[team] }
        let favorites = directory.withLock { $0.favorites }
        let (me, channels) = withState { ($0.me.id, Array($0.channels.values)) }
        let mine = channels.filter { $0.teamID == team || $0.teamID == nil }.sorted { $0.id < $1.id }
        if var list = explicit {
            // Orphans go to Channels or Direct Messages, like the server.
            let placed = Set(list.flatMap(\.channelIDs))
            for channel in mine where !placed.contains(channel.id) {
                let kind: SidebarCategory.Kind = channel.type.isDirectOrGroup ? .directMessages : .channels
                if let index = list.firstIndex(where: { $0.kind == kind }) { list[index].channelIDs.append(channel.id) }
            }
            return list
        }
        func id(_ kind: String) -> SidebarCategoryID {
            SidebarCategoryID(unchecked: kind + "_" + me.rawValue + "_" + team.rawValue)
        }
        let favorite = mine.filter { favorites.contains($0.id) }.map(\.id)
        let rest = mine.filter { !favorites.contains($0.id) }
        return [
            SidebarCategory(id: id("favorites"), userID: me, teamID: team, kind: .favorites, displayName: "Favorites",
                            sortOrder: 0, channelIDs: favorite),
            SidebarCategory(id: id("channels"), userID: me, teamID: team, kind: .channels, displayName: "Channels",
                            sortOrder: 10, channelIDs: rest.filter { !$0.type.isDirectOrGroup }.map(\.id)),
            SidebarCategory(id: id("direct_messages"), userID: me, teamID: team, kind: .directMessages,
                            displayName: "Direct Messages", sorting: .recent, sortOrder: 20,
                            channelIDs: rest.filter { $0.type.isDirectOrGroup }.map(\.id)),
        ]
    }

    public func sidebarCategories(team: TeamID, me: UserID) async throws(APIError) -> [SidebarCategory] {
        note("sidebarCategories")
        if let error = directory.withLock({ $0.categoriesError }) { throw error }
        return currentCategories(team: team)
    }

    public func sidebarCategory(_ id: SidebarCategoryID, team: TeamID, me: UserID) async throws(APIError) -> SidebarCategory {
        note("sidebarCategory")
        if let error = directory.withLock({ $0.categoriesError }) { throw error }
        guard let category = currentCategories(team: team).first(where: { $0.id == id }) else {
            throw .notFound(ServerErrorInfo(id: "app.channel.sidebar_categories.app_error", statusCode: 404, requestID: nil))
        }
        return category
    }

    public func updateSidebarCategory(_ category: SidebarCategory) async throws(APIError) -> SidebarCategory {
        note("updateSidebarCategory")
        if let error = directory.withLock({ $0.updateCategoryError }) { throw error }
        var list = currentCategories(team: category.teamID)
        guard let index = list.firstIndex(where: { $0.id == category.id }) else {
            throw .notFound(ServerErrorInfo(id: "app.channel.sidebar_categories.app_error", statusCode: 404, requestID: nil))
        }
        list[index] = category
        let updated = list
        directory.withLock { state in
            state.categories[category.teamID] = updated
            state.updatedCategories.append(category)
        }
        return category
    }

    public func teamUnreads(includeCollapsedThreads: Bool) async throws(APIError) -> [TeamUnread] {
        note("teamUnreads")
        return directory.withLock { $0.teamUnreads }
    }

    public func publicChannels(team: TeamID, page: Int, perPage: Int) async throws(APIError) -> [Channel] {
        note("publicChannels")
        let all = directory.withLock { $0.publicChannels[team] ?? [] }
            .filter { !$0.isArchived }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return Array(all.dropFirst(page * perPage).prefix(perPage))
    }

    public func archivedChannels(team: TeamID, page: Int, perPage: Int) async throws(APIError) -> [Channel] {
        note("archivedChannels")
        let all = directory.withLock { $0.archivedChannels[team] ?? [] }
        return Array(all.dropFirst(page * perPage).prefix(perPage))
    }

    /// `POST /teams/{id}/channels/search`: public channels, including archived ones (v11).
    public func searchPublicChannels(team: TeamID, term: String) -> [Channel] {
        let needle = term.lowercased()
        return directory.withLock { ($0.publicChannels[team] ?? []) + ($0.archivedChannels[team] ?? []) }
            .filter { $0.name.contains(needle) || $0.displayName.lowercased().contains(needle) }
    }

    public func channelMemberCounts(_ ids: [ChannelID]) async throws(APIError) -> [ChannelID: Int] {
        note("channelMemberCounts")
        let counts = directory.withLock { $0.memberCounts }
        return Dictionary(ids.map { ($0, counts[$0] ?? 3) }, uniquingKeysWith: { first, _ in first })
    }

    public func createChannel(_ request: NewChannelRequest) async throws(APIError) -> Channel {
        note("createChannel")
        if let error = directory.withLock({ state -> APIError? in
            state.createdChannels.append(request)
            return state.createChannelError
        }) { throw error }
        let taken = withState { $0.channels.values.contains { $0.teamID == request.team && $0.name == request.name } }
            || directory.withLock { ($0.publicChannels[request.team] ?? []).contains { $0.name == request.name } }
        if taken { throw .badRequest(ServerErrorInfo(id: ServerErrorID.channelNameTaken, statusCode: 400, requestID: nil)) }
        let channel = Channel(id: ChannelID(unchecked: makeID("c")), teamID: request.team,
                              type: request.isPrivate ? .private : .open, name: request.name,
                              displayName: request.displayName, purpose: request.purpose)
        withState { state in
            state.channels[channel.id] = channel
            state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: state.me.id,
                                                              roles: ["channel_user", "channel_admin"])
        }
        return channel
    }

    public func createGroupChannel(with users: [UserID]) async throws(APIError) -> Channel {
        note("createGroupChannel")
        let (me, names) = withState { state in
            (state.me.id, (users + [state.me.id]).compactMap { state.users[$0]?.username }.sorted())
        }
        let all = Set(users + [me])
        guard (3...8).contains(all.count) else {
            throw .badRequest(ServerErrorInfo(id: "api.channel.create_group.bad_size.app_error", statusCode: 400, requestID: nil))
        }
        directory.withLock { $0.createdGroups.append(users) }
        let channel = Channel(id: ChannelID(unchecked: makeID("g")), teamID: nil, type: .group,
                              name: String(all.map(\.rawValue).sorted().joined().prefix(40)),
                              displayName: names.joined(separator: ", "))
        withState { state in
            state.channels[channel.id] = channel
            state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: me)
        }
        return channel
    }

    public func addChannelMembers(_ id: ChannelID, users: [UserID]) async throws(APIError) {
        note("addChannelMembers")
        if let error = directory.withLock({ state -> APIError? in
            state.addedMembers.append((id, users))
            return state.addMembersError
        }) { throw error }
    }

    public func searchUsers(_ query: UserSearchQuery) async throws(APIError) -> [User] {
        note("searchUsers")
        directory.withLock { $0.userSearches.append(query) }
        let needle = query.term.lowercased()
        return withState { state in
            state.users.values
                .filter { !$0.isDeactivated }
                .filter { $0.username.contains(needle) || $0.fullName.lowercased().contains(needle) }
                .sorted { $0.username < $1.username }
                .prefix(query.limit)
                .map { $0 }
        }
    }
}
