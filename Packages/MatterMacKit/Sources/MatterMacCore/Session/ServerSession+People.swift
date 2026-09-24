import Foundation
public import MatterMacModels
public import MattermostAPI

// Profiles, channel details, membership-aware channel settings and the signed-in
// user's status (SPEC §3 "basic user profiles, channel information, membership-aware
// actions"). Results are returned to the caller and not retained beyond the bounded
// directory; every mutation is an explicit, user-initiated server change (SPEC §4).
extension ServerSession {
    /// Members fetched per page for the details panel.
    public static let channelMembersPageSize = 60

    // MARK: - Profiles

    public func profile(username: String) async -> UserProfilePresentation? {
        let name = username.lowercased()
        guard isActiveSessionAlive, !name.isEmpty, !["here", "channel", "all"].contains(name) else { return nil }
        if name == me.username.lowercased() { return await profile(for: me.id) }
        let epoch = epoch
        guard let user = try? await service.users(usernames: [name]).first(where: { $0.username.lowercased() == name }),
              self.epoch == epoch, isActiveSessionAlive else { return nil }
        directory.upsertUser(user)
        return await profile(for: user.id)
    }

    /// A profile picture for cards and member lists. The server enforces visibility;
    /// the decoded image is charged to the shared image budget while the caller holds it.
    public func profileImage(_ user: UserID, revision: Int64, maxPixelSize: Int,
                             pipeline: ImagePipeline) async -> ImagePipeline.Decoded? {
        guard isActiveSessionAlive else { return nil }
        let epoch = epoch
        let key = ImagePipeline.Key(scope: scope, resource: .profileImage(user, revision: revision), maxPixelSize: maxPixelSize)
        let image = await pipeline.image(for: key, using: service)
        guard isActiveSessionAlive, self.epoch == epoch, !Task.isCancelled else { return nil }
        return image
    }

    /// The member channel with this URL name on the selected team.
    public func memberChannel(named name: String) -> ChannelID? {
        let needle = name.lowercased()
        let team = selectedTeam
        return directory.channels.values.first {
            ($0.type == .open || $0.type == .private) && $0.teamID == team && $0.name == needle
        }?.id
    }

    // MARK: - Channel details

    public func channelDetails(_ id: ChannelID) async throws(UserFacingError) -> ChannelDetailsPresentation {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let epoch = epoch
        guard directory.channels[id] != nil else { throw .notFoundOrInaccessible }
        var stats: ChannelStats?
        if let type = directory.channels[id]?.type, type != .direct {
            do { stats = try await service.channelStats(id) } catch {
                handleAuthenticationFailureIfNeeded(error)
                if case .forbidden = error { throw .permissionDenied }
            }
        }
        guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
        // The channel may have been removed while the request was in flight.
        guard let channel = directory.channels[id] else { throw .notFoundOrInaccessible }
        if let stats {
            if memberCounts.count > 256 { memberCounts.removeAll() }
            memberCounts[id] = stats.memberCount
            markDirty(.header)
        }
        let team = teamName(for: channel)
        let link = team.map { endpoint.url(path: [$0, "channels", channel.name]) }
        return ChannelDetailsPresentation(
            channelID: id, name: channel.name, displayName: displayName(of: channel), type: channel.type,
            header: channel.header, purpose: channel.purpose, memberCount: stats?.memberCount ?? memberCounts[id],
            pinnedPostCount: stats?.pinnedPostCount, isArchived: channel.isArchived,
            isFavorite: directory.favorites.contains(id),
            isMuted: directory.memberships[id]?.markUnread == .mention,
            canLeave: (channel.type == .open || channel.type == .private) && channel.name != "town-square",
            directPartner: channel.directPartner(of: me.id),
            link: channel.type.isDirectOrGroup ? nil : link)
    }

    /// One page of active members with their presence. Users are cached in the
    /// bounded directory; the caller owns (and must bound) the accumulated list.
    public func channelMembers(_ id: ChannelID, page: Int) async throws(UserFacingError) -> ChannelMembersPage {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard directory.channels[id] != nil else { throw .notFoundOrInaccessible }
        let epoch = epoch
        let size = Self.channelMembersPageSize
        do {
            let users = try await service.channelMembers(id, page: page, perPage: size)
            guard self.epoch == epoch, isActiveSessionAlive else { throw UserFacingError.cancelled }
            let statuses = (try? await service.statuses(ids: users.map(\.id))) ?? [:]
            guard self.epoch == epoch, isActiveSessionAlive else { throw UserFacingError.cancelled }
            for user in users { directory.upsertUser(user) }
            for (user, status) in statuses { directory.setStatus(status, for: user) }
            let rows = users.map { user in
                ChannelMemberRow(userID: user.id, displayName: directory.nameFormat.displayName(for: user),
                                 username: user.username, status: statuses[user.id] ?? directory.status(of: user.id),
                                 isBot: user.isBot, isGuest: user.isGuest,
                                 avatarRevision: user.lastPictureUpdate.milliseconds)
            }
            return ChannelMembersPage(members: rows, hasMore: users.count >= size)
        } catch let error as UserFacingError {
            throw error
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    // MARK: - Channel settings (explicit server changes)

    /// Saves or deletes the `favorite_channel` preference; the server moves the
    /// channel into or out of the Favorites sidebar category accordingly.
    public func setFavorite(_ id: ChannelID, _ favorite: Bool) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard directory.channels[id] != nil else { throw .notFoundOrInaccessible }
        let preference = Preference(category: "favorite_channel", name: id.rawValue, value: favorite ? "true" : "false")
        do {
            if favorite { try await service.savePreferences([preference], me: me.id) }
            else { try await service.deletePreferences([preference], me: me.id) }
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard isActiveSessionAlive else { throw .cancelled }
        directory.apply(preference, deleted: !favorite)
        // The server moves the channel between categories; re-read them now rather
        // than waiting for the `sidebar_category_updated` event.
        if let team = directory.channels[id]?.teamID ?? selectedTeam, directory.categories[team] != nil {
            scheduleCategoryLoad(team: team, delay: .zero)
        }
        markDirty(.sidebar)
    }

    /// Renames the channel or changes its header/purpose (server permissions apply).
    public func updateChannel(_ id: ChannelID, displayName: String?, header: String?, purpose: String?)
        async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let channel = directory.channels[id] else { throw .notFoundOrInaccessible }
        if let displayName, displayName.trimmingCharacters(in: .whitespaces).isEmpty { throw .unsupportedCapability(String(localized: "an empty channel name")) }
        // Server limits (model/channel.go): display name 64, header 1024, purpose 250 runes.
        if let displayName, displayName.unicodeScalars.count > 64 { throw .messageTooLong(limitCharacters: 64) }
        if let header, header.unicodeScalars.count > 1024 { throw .messageTooLong(limitCharacters: 1024) }
        if let purpose, purpose.unicodeScalars.count > 250 { throw .messageTooLong(limitCharacters: 250) }
        do {
            let updated = try await service.patchChannel(id, displayName: displayName == channel.displayName ? nil : displayName,
                                                         header: header == channel.header ? nil : header,
                                                         purpose: purpose == channel.purpose ? nil : purpose)
            guard isActiveSessionAlive else { throw UserFacingError.cancelled }
            directory.upsertChannel(updated)
            markDirty([.sidebar, .header])
        } catch let error as UserFacingError {
            throw error
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    /// Explicit "Mark as Read" for channels (sidebar menu), without making any of them
    /// the server's active channel. `nil` marks every unread channel of the selected team
    /// and the user's direct/group messages.
    public func markChannelsRead(_ ids: [ChannelID]?) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let crt = collapsedThreadsActive
        let targets = (ids ?? directory.channels.values.filter { $0.teamID == selectedTeam || $0.type.isDirectOrGroup }.map(\.id))
            .filter { directory.unread(for: $0, collapsedThreads: crt).isUnread }
        guard !targets.isEmpty else { return }
        let epoch = epoch
        do {
            let times = try await service.markChannelsRead(targets, me: me.id)
            guard self.epoch == epoch, isActiveSessionAlive else { throw UserFacingError.cancelled }
            for id in targets {
                if manualUnreadHold == id { manualUnreadHold = nil }
                markViewedLocally(id, at: times[id] ?? now())
            }
            markDirty(.sidebar)
        } catch let error as UserFacingError {
            throw error
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    /// Muting maps to the channel member's `mark_unread` notify property.
    public func setMuted(_ id: ChannelID, _ muted: Bool) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard directory.memberships[id] != nil else { throw .notFoundOrInaccessible }
        do {
            try await service.setChannelMarkUnread(id, level: muted ? .mention : .all, me: me.id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard isActiveSessionAlive else { throw .cancelled }
        directory.updateMembership(id) { $0.markUnread = muted ? .mention : .all }
        markDirty([.sidebar, .header])
    }

    // MARK: - Slash commands

    /// Mattermost treats text that begins with "/" as a command; a leading space sends
    /// it as a message instead.
    public nonisolated static func isSlashCommand(_ text: String) -> Bool {
        text.hasPrefix("/") && text.count > 1
    }

    /// Runs a slash command in the channel (and thread) where it was typed. Results
    /// such as posts or header changes arrive through the normal realtime events; the
    /// synchronous reply is returned for display and is not retained.
    public func executeCommand(_ text: String, channel: ChannelID, rootID: PostID?) async throws(UserFacingError)
        -> CommandResult {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let current = directory.channels[channel], directory.memberships[channel] != nil else {
            throw .notFoundOrInaccessible
        }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSlashCommand(command) else { throw .commandNotFound }
        let limit = capabilities.maximumPostCharacters ?? 16_383
        guard command.unicodeScalars.count <= limit else { throw .messageTooLong(limitCharacters: limit) }
        let epoch = epoch
        do {
            let result = try await service.executeCommand(command, channel: channel, team: current.teamID ?? selectedTeam,
                                                          rootID: rootID)
            guard self.epoch == epoch, isActiveSessionAlive else { throw UserFacingError.cancelled }
            return result
        } catch let error as UserFacingError {
            throw error
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            guard let api = error as? APIError else { throw .unknown }
            switch api {
            case .notFound(let info) where info.id == ServerErrorID.commandNotFound: throw .commandNotFound
            case .outcomeUnknown: throw .commandOutcomeUnknown
            default: throw Self.userFacing(api)
            }
        }
    }

    // MARK: - Own status

    /// Sets (or with empty emoji and text, clears) the signed-in user's custom status.
    public func setCustomStatus(emoji: String, text: String, duration: CustomStatusDuration) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = emoji.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).lowercased()
        let status: CustomStatus? = name.isEmpty && trimmed.isEmpty ? nil : CustomStatus(
            emoji: name.isEmpty ? "speech_balloon" : String(name.prefix(64)), text: String(trimmed.prefix(100)),
            expiresAt: duration.expiry(from: deps.wallClock.now(), timeZone: deps.timeZone()))
        do {
            try await service.setCustomStatus(status, duration: duration.rawValue, me: me.id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard isActiveSessionAlive else { throw .cancelled }
        me.customStatus = status
        directory.pin(me)
        markDirty(.sidebar)
    }

    /// Sets a manual presence status on the server (visible to other users).
    public func setOwnStatus(_ status: PresenceStatus) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard status != .unknown else { throw .unsupportedCapability("status") }
        do {
            try await service.setStatus(status, me: me.id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard isActiveSessionAlive else { throw .cancelled }
        directory.setStatus(status, for: me.id)
        markDirty(.sidebar)
    }
}
