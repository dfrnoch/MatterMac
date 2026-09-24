import Foundation
public import MatterMacModels
public import MatterMacCore

/// Sheets for finding and creating conversations (sidebar "+" menu, File menu).
public enum DirectorySheet: Hashable, Identifiable, Sendable {
    case browseChannels
    case createChannel
    case newMessage
    case addMembers(ChannelID)

    public var id: Self { self }
}

// Sidebar navigation, categories and the directory sheets' server operations.
extension SessionViewModel {
    // MARK: - Keyboard navigation

    /// ⌥↑/⌥↓ (any channel) and ⌥⇧↑/⌥⇧↓ (unread channels), in sidebar order.
    public func selectAdjacentChannel(_ offset: Int, unreadOnly: Bool) {
        guard !isDetached, !requiresAuthentication,
              let target = sidebar?.adjacentChannel(to: selectedChannel, offset: offset, unreadOnly: unreadOnly)
        else { return }
        select(channel: target)
    }

    /// ⌘1…⌘9: the team at `index` in the rail.
    public func selectTeam(at index: Int) {
        guard !isDetached, !requiresAuthentication, let teams = sidebar?.teams, teams.indices.contains(index) else { return }
        selectTeam(teams[index].id)
    }

    // MARK: - Categories

    /// Collapsing a category is saved on the server (the user's other clients follow).
    public func setCategoryCollapsed(_ section: SidebarSection, collapsed: Bool) {
        guard let id = section.categoryID, !isDetached, !requiresAuthentication else { return }
        let session = session
        Task {
            do throws(UserFacingError) {
                try await session.setCategoryCollapsed(id, collapsed: collapsed)
            } catch {
                if !isDetached, error != .cancelled { inlineError = UserFacingErrorText.describe(error) }
            }
        }
    }

    /// Local and in-memory only; nothing is written to the server.
    public func setGroupsUnreads(_ value: Bool) {
        guard !isDetached else { return }
        let session = session
        Task { await session.setGroupsUnreads(value) }
    }

    // MARK: - Directory operations (used by the sheets)

    func browseChannels(term: String, archived: Bool, page: Int) async throws(UserFacingError) -> BrowseChannelsPage {
        guard !isDetached, !requiresAuthentication else { throw .authenticationRequired }
        return try await session.browseChannels(term: term, archived: archived, page: page)
    }

    /// Joins (when needed) and shows the channel.
    func joinAndOpen(_ channel: ChannelID) async throws(UserFacingError) {
        guard !isDetached, !requiresAuthentication else { throw .authenticationRequired }
        let id = try await session.joinAndLoadChannel(channel)
        guard !isDetached else { return }
        select(channel: id)
    }

    func createChannel(displayName: String, name: String, purpose: String, isPrivate: Bool)
        async throws(ChannelCreationError) {
        guard !isDetached, !requiresAuthentication else { throw .failed(.authenticationRequired) }
        let id = try await session.createChannel(displayName: displayName, name: name, purpose: purpose,
                                                 isPrivate: isPrivate)
        guard !isDetached else { return }
        select(channel: id)
    }

    /// A DM for one person, a group message for 2–7.
    func openConversation(with users: [UserID]) async throws(UserFacingError) {
        guard !isDetached, !requiresAuthentication else { throw .authenticationRequired }
        let id = try await session.conversation(with: users)
        guard !isDetached else { return }
        select(channel: id)
    }

    func addMembers(_ users: [UserID], to channel: ChannelID) async throws(UserFacingError) {
        guard !isDetached, !requiresAuthentication else { throw .authenticationRequired }
        try await session.addMembers(users, to: channel)
        bumpChannelInfoRevision()
    }

    func searchUsers(_ term: String, notInChannel channel: ChannelID?) async throws(UserFacingError) -> [UserPickerItem] {
        guard !isDetached, !requiresAuthentication else { throw .authenticationRequired }
        return try await session.searchUsers(term, notInChannel: channel)
    }

    func recentDirectMessagePartners() async -> [UserPickerItem] {
        guard !isDetached, !requiresAuthentication else { return [] }
        return await session.recentDirectMessagePartners()
    }
}
