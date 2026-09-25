import Foundation
public import MatterMacModels
import MattermostAPI

/// A channel in the Browse Channels sheet. Returned to the caller, never retained.
public struct BrowseChannelItem: Hashable, Sendable, Identifiable {
    public let channelID: ChannelID
    public let displayName: String
    public let name: String
    public let purpose: String
    public let type: ChannelType
    public let isArchived: Bool
    /// `nil` when the server did not report it (permissions).
    public let memberCount: Int?
    public let isMember: Bool
    public var id: ChannelID { channelID }

    public init(channelID: ChannelID, displayName: String, name: String, purpose: String, type: ChannelType,
                isArchived: Bool, memberCount: Int?, isMember: Bool) {
        self.channelID = channelID
        self.displayName = displayName
        self.name = name
        self.purpose = purpose
        self.type = type
        self.isArchived = isArchived
        self.memberCount = memberCount
        self.isMember = isMember
    }
}

public struct BrowseChannelsPage: Sendable {
    public let items: [BrowseChannelItem]
    public let hasMore: Bool
    public init(items: [BrowseChannelItem], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}

/// A person in the new-message and add-members pickers.
public struct UserPickerItem: Hashable, Sendable, Identifiable {
    public let userID: UserID
    public let displayName: String
    public let username: String
    public let avatarRevision: Int64
    public let isBot: Bool
    public var id: UserID { userID }

    public init(userID: UserID, displayName: String, username: String, avatarRevision: Int64, isBot: Bool) {
        self.userID = userID
        self.displayName = displayName
        self.username = username
        self.avatarRevision = avatarRevision
        self.isBot = isBot
    }
}

/// Why a channel could not be created. Server refusals are reported honestly;
/// message bodies are never shown.
public enum ChannelCreationError: Error, Hashable, Sendable {
    case invalidName(ChannelNameRules.Problem)
    case missingDisplayName
    case displayNameTooLong
    case purposeTooLong
    case nameTaken
    case nameUsedByArchivedChannel
    case channelLimitReached
    case permissionDenied(isPrivate: Bool)
    case failed(UserFacingError)
}

// Browse, create, direct/group messages and membership (SPEC §3 "channel
// creation/browsing, membership-aware actions"). Every mutation is an explicit,
// user-initiated server change whose failure is reported without fake success.
extension ServerSession {
    public static let browsePageSize = 50
    /// Largest group message: the server allows 3–8 members including the caller.
    public static let maximumGroupMessageMembers = 7
    public static let maximumMembersPerAdd = 50
    public static let userSearchLimit = 30

    // MARK: - Browse

    /// One page of the team's public channels (or archived channels), or the search
    /// results for `term` (the server returns at most 100, unpaged).
    public func browseChannels(term: String, archived: Bool, page: Int) async throws(UserFacingError) -> BrowseChannelsPage {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let team = selectedTeam else { throw .notFoundOrInaccessible }
        guard !archived || directory.viewArchivedChannels else { throw .unsupportedCapability("archived channels") }
        let needle = String(term.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let epoch = epoch
        do {
            let channels: [Channel]
            var hasMore = false
            if needle.isEmpty {
                let size = Self.browsePageSize
                channels = archived
                    ? try await service.archivedChannels(team: team, page: page, perPage: size)
                    : try await service.publicChannels(team: team, page: page, perPage: size)
                hasMore = channels.count >= size
            } else {
                guard page == 0 else { return BrowseChannelsPage(items: [], hasMore: false) }
                channels = try await service.searchChannels(team: team, term: needle).filter { $0.isArchived == archived }
            }
            guard self.epoch == epoch, isActiveSessionAlive else { throw APIError.cancelled }
            let shown = channels.filter { $0.teamID == team && ($0.type == .open || $0.type == .private) }.prefix(200)
            // Counts are a nicety: a permission failure must not hide the list.
            let counts = (try? await service.channelMemberCounts(shown.map(\.id))) ?? [:]
            guard self.epoch == epoch, isActiveSessionAlive else { throw APIError.cancelled }
            let items = shown.map { channel in
                BrowseChannelItem(channelID: channel.id, displayName: displayName(of: channel), name: channel.name,
                                  purpose: String(channel.purpose.prefix(300)), type: channel.type,
                                  isArchived: channel.isArchived, memberCount: counts[channel.id],
                                  isMember: directory.memberships[channel.id] != nil)
            }
            return BrowseChannelsPage(items: items, hasMore: hasMore)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    /// Joins a public channel (unless already a member) and loads it so the caller
    /// can select it immediately.
    public func joinAndLoadChannel(_ id: ChannelID) async throws(UserFacingError) -> ChannelID {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        if directory.memberships[id] != nil { return id }
        do {
            try await service.joinChannel(id, me: me.id)
            try await loadMemberChannel(id)
            return id
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    /// Reads one channel and the user's membership into the directory.
    func loadMemberChannel(_ id: ChannelID) async throws(APIError) {
        let epoch = epoch
        let revision = membershipRevision
        let channel: Channel
        let membership: ChannelMembership
        do {
            async let channelRequest = service.channel(id)
            async let membershipRequest = service.channelMembership(id)
            (channel, membership) = try await (channelRequest, membershipRequest)
        } catch let error as APIError {
            throw error
        } catch {
            throw .cancelled
        }
        guard self.epoch == epoch, membershipRevision == revision, isActiveSessionAlive, !Task.isCancelled else { throw .cancelled }
        directory.upsertChannel(channel)
        directory.upsertMembership(membership)
        guard directory.memberships[id] != nil else { throw .overloaded }
        if let partner = channel.directPartner(of: me.id), directory.peekUser(partner) == nil { missingUsers.insert(partner) }
        markDirty([.sidebar, .header])
        // The server places the channel in a category; show it there soon.
        if let team = channel.teamID ?? selectedTeam, directory.categories[team] != nil {
            scheduleCategoryLoad(team: team, delay: Self.categoryEventDelay)
        }
    }

    // MARK: - Create

    /// Creates a public or private channel on the selected team and loads it.
    public func createChannel(displayName: String, name: String, purpose: String, isPrivate: Bool)
        async throws(ChannelCreationError) -> ChannelID {
        guard isActiveSessionAlive else { throw .failed(.authenticationRequired) }
        guard let team = selectedTeam else { throw .failed(.notFoundOrInaccessible) }
        let title = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw .missingDisplayName }
        guard title.count <= ChannelNameRules.maximumDisplayNameCharacters else { throw .displayNameTooLong }
        let about = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard about.count <= ChannelNameRules.maximumPurposeCharacters else { throw .purposeTooLong }
        if let problem = ChannelNameRules.problem(with: name) { throw .invalidName(problem) }
        do {
            let channel = try await service.createChannel(NewChannelRequest(team: team, name: name, displayName: title,
                                                                            purpose: about, isPrivate: isPrivate))
            try await loadMemberChannel(channel.id)
            return channel.id
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            switch error {
            case .forbidden: throw .permissionDenied(isPrivate: isPrivate)
            case .badRequest(let info), .server(let info):
                switch info.id {
                case ServerErrorID.channelNameTaken: throw .nameTaken
                case ServerErrorID.channelNameArchived: throw .nameUsedByArchivedChannel
                case ServerErrorID.channelLimitReached: throw .channelLimitReached
                case "model.channel.is_valid.display_name.app_error": throw .displayNameTooLong
                case "model.channel.is_valid.purpose.app_error": throw .purposeTooLong
                case "model.channel.is_valid.1_or_more.app_error", "model.channel.is_valid.name.app_error":
                    throw .invalidName(.invalidCharacters)
                default: throw .failed(Self.userFacing(error))
                }
            default:
                throw .failed(Self.userFacing(error))
            }
        }
    }

    // MARK: - Direct and group messages

    /// Opens (creating if needed) a DM for one person or a GM for 2–7 people.
    public func conversation(with users: [UserID]) async throws(UserFacingError) -> ChannelID {
        var seen: Set<UserID> = [me.id]
        let others = users.filter { seen.insert($0).inserted }
        guard !others.isEmpty else { throw .notFoundOrInaccessible }
        if others.count == 1 { return try await directMessageChannel(with: others[0]) }
        guard others.count <= Self.maximumGroupMessageMembers else {
            throw .unsupportedCapability("group messages with more than 8 people")
        }
        guard isActiveSessionAlive else { throw .authenticationRequired }
        do {
            // The server returns the existing GM for the same people.
            let channel = try await service.createGroupChannel(with: others)
            try await loadMemberChannel(channel.id)
            if directory.hiddenGroups.contains(channel.id) {
                // Reopening a closed GM shows it again, as in the official client.
                let preference = Preference(category: "group_channel_show", name: channel.id.rawValue, value: "true")
                if (try? await service.savePreferences([preference], me: me.id)) != nil {
                    directory.apply(preference, deleted: false)
                    markDirty(.sidebar)
                }
            }
            return channel.id
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    // MARK: - Members

    /// Adds people to a public or private channel. Requires the server's
    /// `manage_*_channel_members` permission, which is reported when missing.
    public func addMembers(_ users: [UserID], to channel: ChannelID) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let type = directory.channels[channel]?.type, type == .open || type == .private else {
            throw .notFoundOrInaccessible
        }
        var seen = Set<UserID>()
        let unique = users.filter { $0 != me.id && seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        guard unique.count <= Self.maximumMembersPerAdd else { throw .budgetExceeded(.attachmentCount) }
        let epoch = epoch
        do {
            try await service.addChannelMembers(channel, users: unique)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
        memberCounts[channel] = nil
        if channel == activeChannel { loadMemberCount(channel) }
    }

    // MARK: - People search

    /// Server user search on the selected team (or the channel's team, excluding its
    /// members). Deactivated users and the signed-in user are left out.
    public func searchUsers(_ term: String, notInChannel channel: ChannelID? = nil) async throws(UserFacingError)
        -> [UserPickerItem] {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        guard let team = channel.flatMap({ directory.channels[$0]?.teamID }) ?? selectedTeam else {
            throw .notFoundOrInaccessible
        }
        let epoch = epoch
        do {
            let users = try await service.searchUsers(UserSearchQuery(term: needle, team: team, notInChannel: channel,
                                                                      limit: Self.userSearchLimit))
            guard self.epoch == epoch, isActiveSessionAlive else { throw APIError.cancelled }
            return users.prefix(Self.userSearchLimit).compactMap { user in
                guard user.id != me.id, !user.isDeactivated else { return nil }
                directory.upsertUser(user)
                return pickerItem(user)
            }
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    /// Recent direct-message partners (most recent first) as initial suggestions.
    public func recentDirectMessagePartners(limit: Int = 10) -> [UserPickerItem] {
        directory.channels.values
            .filter { $0.type == .direct }
            .sorted { $0.lastPostAt > $1.lastPostAt }
            .compactMap { $0.directPartner(of: me.id).flatMap { directory.peekUser($0) } }
            .filter { !$0.isDeactivated }
            .prefix(max(0, limit))
            .map(pickerItem)
    }

    private func pickerItem(_ user: User) -> UserPickerItem {
        UserPickerItem(userID: user.id, displayName: directory.nameFormat.displayName(for: user), username: user.username,
                       avatarRevision: user.lastPictureUpdate.milliseconds, isBot: user.isBot)
    }
}
