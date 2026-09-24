import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI

/// Opt-in only, against the repository-owned loopback test servers, as **bob**
/// (other live suites use alice). Every change is restored: the category collapse
/// flag is reset, the test channel is archived (and permanently deleted when the
/// server allows it). The group message with alice and carol is created once and
/// reused on later runs (the server returns the existing one).
@Suite("Live sidebar categories, browsing and membership", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveSidebarTests {
    enum Failure: Error { case missingCredentials, missingFixture }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func sidebarEndpoints(base: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let password = environment["MM_TEST_BOB_PASSWORD"] else { throw Failure.missingCredentials }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let login: LoginResult
        do { login = try await discovery.login(LoginRequest(loginID: "bob", password: password)) } catch {
            await discovery.shutdown()
            throw error
        }
        await discovery.shutdown()
        let api = factory.makeClient(for: endpoint, credential: login.credential)
        var cleanup = Cleanup()
        do {
            try await exercise(api, me: login.user.id, cleanup: &cleanup)
        } catch {
            await cleanup.run(api)
            try? await api.logout()
            await api.shutdown()
            throw error
        }
        await cleanup.run(api)
        await removePermanently(cleanup.archived, endpoint: endpoint, factory: factory,
                                adminPassword: environment["MM_TEST_ADMIN_PASSWORD"])
        try await api.logout()
        await api.shutdown()
    }

    struct Cleanup {
        var collapse: SidebarCategory?
        var channel: ChannelID?
        var archived: [ChannelID] = []

        mutating func run(_ api: MattermostHTTPClient) async {
            if let original = collapse, var fresh = try? await api.sidebarCategory(original.id, team: original.teamID,
                                                                                    me: original.userID) {
                fresh.isCollapsed = original.isCollapsed
                _ = try? await api.updateSidebarCategory(fresh)
                collapse = nil
            }
            if let channel {
                if (try? await api.deleteChannel(channel, permanent: false)) != nil { archived.append(channel) }
                self.channel = nil
            }
        }
    }

    private func exercise(_ api: MattermostHTTPClient, me: UserID, cleanup: inout Cleanup) async throws {
        let config = try await api.fullConfiguration()
        if config.capabilities.version?.major == 10 {
            #expect(config.viewArchivedChannels != nil)
        } else {
            #expect(config.viewArchivedChannels == nil)
        }
        guard let team = try await api.teams().first(where: { $0.name == "qa" }),
              let interop = try await api.channels(team: team.id).first(where: { $0.name == "interop" }),
              let carol = try await api.users(usernames: ["carol"]).first,
              let alice = try await api.users(usernames: ["alice"]).first
        else { throw Failure.missingFixture }

        // Categories: the three default kinds exist; every member channel is placed.
        let categories = try await api.sidebarCategories(team: team.id, me: me)
        #expect(Set([SidebarCategory.Kind.favorites, .channels, .directMessages]).isSubset(of: Set(categories.map(\.kind))))
        #expect(categories.contains { $0.channelIDs.contains(interop.id) })
        #expect(categories.allSatisfy { $0.droppedChannelIDs == 0 && $0.teamID == team.id })
        #expect(categories.first { $0.kind == .directMessages }?.effectiveSorting == .recent)

        // Collapse round trip keeps the channel list; restored in `cleanup`.
        let channels = try #require(categories.first { $0.kind == .channels })
        cleanup.collapse = channels
        var toggled = try await api.sidebarCategory(channels.id, team: team.id, me: me)
        toggled.isCollapsed.toggle()
        let saved = try await api.updateSidebarCategory(toggled)
        #expect(saved.isCollapsed == toggled.isCollapsed)
        let reread = try await api.sidebarCategory(channels.id, team: team.id, me: me)
        #expect(reread.isCollapsed == toggled.isCollapsed)
        #expect(Set(reread.channelIDs) == Set(toggled.channelIDs))
        var restore = reread
        restore.isCollapsed = channels.isCollapsed
        #expect(try await api.updateSidebarCategory(restore).isCollapsed == channels.isCollapsed)
        cleanup.collapse = nil

        // Team unread counts, browsing, search and member counts.
        let unread = try await api.teamUnreads(includeCollapsedThreads: true)
        #expect(unread.allSatisfy { $0.messageCount >= 0 && $0.mentionCount >= 0 })
        let browse = try await api.publicChannels(team: team.id, page: 0, perPage: 200)
        #expect(browse.contains { $0.id == interop.id })
        #expect(browse.allSatisfy { $0.type == .open && !$0.isArchived })
        #expect(try await api.searchChannels(team: team.id, term: "interop").contains { $0.id == interop.id })
        let counts = try await api.channelMemberCounts([interop.id])
        #expect((counts[interop.id] ?? 0) >= 3)
        _ = try await api.archivedChannels(team: team.id, page: 0, perPage: 50)

        // Create: an existing URL is refused with the name-taken id.
        do {
            _ = try await api.createChannel(NewChannelRequest(team: team.id, name: "interop", displayName: "Interop copy",
                                                              isPrivate: false))
            Issue.record("duplicate channel name was accepted")
        } catch {
            guard case .badRequest(let info) = error else { Issue.record("unexpected \(error)"); return }
            #expect(info.id == ServerErrorID.channelNameTaken)
        }
        let name = "mm-sidebar-" + String(UUID().uuidString.lowercased().prefix(8))
        let created = try await api.createChannel(NewChannelRequest(team: team.id, name: name, displayName: "Sidebar check",
                                                                    purpose: "MatterMac live test", isPrivate: false))
        cleanup.channel = created.id
        #expect(created.name == name)
        #expect(created.type == .open)
        #expect(created.purpose == "MatterMac live test")
        // The server places the new channel in a category.
        #expect(try await api.sidebarCategories(team: team.id, me: me).contains { $0.channelIDs.contains(created.id) })

        // Add a member and search people outside the channel.
        #expect(try await api.searchUsers(UserSearchQuery(term: "car", team: team.id, notInChannel: created.id))
            .contains { $0.id == carol.id })
        try await api.addChannelMembers(created.id, users: [carol.id])
        #expect(try await api.channelMembers(created.id, page: 0, perPage: 60).contains { $0.id == carol.id })
        #expect(!(try await api.searchUsers(UserSearchQuery(term: "car", team: team.id, notInChannel: created.id))
            .contains { $0.id == carol.id }))
        try await api.deleteChannel(created.id, permanent: false)
        cleanup.archived.append(created.id)
        cleanup.channel = nil

        // Group message: the same people always resolve to the same channel.
        let group = try await api.createGroupChannel(with: [alice.id, carol.id])
        #expect(group.type == .group)
        #expect(try await api.createGroupChannel(with: [carol.id, alice.id]).id == group.id)
    }

    /// Best effort: archived test channels are removed for good when an administrator
    /// may do so (`EnableAPIChannelDeletion`); otherwise they stay archived.
    private func removePermanently(_ channels: [ChannelID], endpoint: ServerEndpoint,
                                   factory: DefaultMattermostServiceFactory, adminPassword: String?) async {
        guard !channels.isEmpty, let adminPassword else { return }
        let discovery = factory.discovery(for: endpoint)
        let login = try? await discovery.login(LoginRequest(loginID: "mmadmin", password: adminPassword))
        await discovery.shutdown()
        guard let login else { return }
        let admin = factory.makeClient(for: endpoint, credential: login.credential)
        for channel in channels { try? await admin.deleteChannel(channel, permanent: true) }
        try? await admin.logout()
        await admin.shutdown()
    }
}
