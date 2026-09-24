import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

/// A session whose fake server is configured before `start()`.
struct SidebarHarness {
    let service: FakeMattermostService
    let realtime: FakeRealtimeConnection
    let session: ServerSession
    let team = CoreFixtures.team
    let me = CoreFixtures.me

    init(configure: @Sendable (inout State) -> Void = { _ in }, directory: @Sendable (inout DirectoryState) -> Void = { _ in })
        async {
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        service.withState { state in
            state.teams = [CoreFixtures.team]
            state.users[CoreFixtures.bob.id] = CoreFixtures.bob
            for n in 1...3 {
                let channel = CoreFixtures.channel(n)
                state.channels[channel.id] = channel
                state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: CoreFixtures.me.id)
            }
            configure(&state)
        }
        service.withDirectory(directory)
        let realtime = FakeRealtimeConnection()
        var deps = CoreFixtures.dependencies(realtime: realtime)
        deps.clock = ImmediateClock()
        let session = ServerSession(
            scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id), endpoint: CoreFixtures.endpoint,
            me: CoreFixtures.me, credential: BearerCredential(token: "tokentokentokentokentoken1", kind: .session)!,
            capabilities: ServerCapabilities(), service: service, dependencies: deps)
        self.service = service
        self.realtime = realtime
        self.session = session
        await session.start()
    }

    typealias State = FakeMattermostService.State

    func sections() async -> [SidebarSection] { await session.sidebarSections(collapsedThreads: false) }

    func titles() async -> [String] {
        await sections().map { $0.title.isEmpty ? "\($0.kind)" : $0.title }
    }

    func rowNames(_ kind: SidebarSection.Kind) async -> [String] {
        await sections().first { $0.kind == kind }?.rows.map(\.displayName) ?? []
    }

    func categoryID(_ kind: String) -> SidebarCategoryID {
        SidebarCategoryID(unchecked: kind + "_" + me.id.rawValue + "_" + team.id.rawValue)
    }

    func waitForCategories() async {
        _ = await eventually { await session.directory.categories[team.id] != nil }
    }
}

extension ChannelID {
    static func fixture(_ n: Int) -> ChannelID { CoreFixtures.channel(n).id }
}

@Suite("Sidebar categories, teams and navigation", .serialized)
struct SidebarTests {
    private func dm(_ state: inout FakeMattermostService.State, with user: User, lastPostAt: Int64) -> Channel {
        let ids = [state.me.id.rawValue, user.id.rawValue].sorted()
        let channel = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", Int(lastPostAt % 1_000))), teamID: nil,
                              type: .direct, name: ids.joined(separator: "__"), displayName: "",
                              lastPostAt: MattermostTimestamp(milliseconds: lastPostAt))
        state.channels[channel.id] = channel
        state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: state.me.id)
        state.users[user.id] = user
        return channel
    }

    @Test func serverCategoriesDriveSectionsOrderAndSorting() async {
        let carol = User(id: UserID(unchecked: CoreFixtures.id("carol", 1)), username: "carol", firstName: "Carol")
        let h = await SidebarHarness(configure: { state in
            let me = state.me.id
            let team = CoreFixtures.team.id
            func id(_ kind: String) -> SidebarCategoryID { SidebarCategoryID(unchecked: kind + "_" + me.rawValue + "_" + team.rawValue) }
            state.users[carol.id] = carol
            let bobDM = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", 1)), teamID: nil, type: .direct,
                                name: [me.rawValue, CoreFixtures.bob.id.rawValue].sorted().joined(separator: "__"), displayName: "",
                                lastPostAt: MattermostTimestamp(milliseconds: 100))
            let carolDM = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", 2)), teamID: nil, type: .direct,
                                  name: [me.rawValue, carol.id.rawValue].sorted().joined(separator: "__"), displayName: "",
                                  lastPostAt: MattermostTimestamp(milliseconds: 900))
            for channel in [bobDM, carolDM] {
                state.channels[channel.id] = channel
                state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: me)
            }
        }, directory: { directory in
            let me = CoreFixtures.me.id
            let team = CoreFixtures.team.id
            func id(_ kind: String) -> SidebarCategoryID { SidebarCategoryID(unchecked: kind + "_" + me.rawValue + "_" + team.rawValue) }
            directory.categories[team] = [
                SidebarCategory(id: SidebarCategoryID(unchecked: CoreFixtures.id("work", 1)), userID: me, teamID: team,
                                kind: .custom, displayName: "Work", sorting: .manual,
                                channelIDs: [.fixture(3), .fixture(1)]),
                SidebarCategory(id: id("favorites"), userID: me, teamID: team, kind: .favorites, displayName: "Favorites"),
                SidebarCategory(id: id("channels"), userID: me, teamID: team, kind: .channels, displayName: "Channels",
                                sorting: .alphabetical, isCollapsed: true, channelIDs: [.fixture(2)]),
                SidebarCategory(id: id("direct_messages"), userID: me, teamID: team, kind: .directMessages,
                                displayName: "Direct Messages", sorting: .recent,
                                channelIDs: [ChannelID(unchecked: CoreFixtures.id("dm", 1)), ChannelID(unchecked: CoreFixtures.id("dm", 2))]),
            ]
        })
        await h.waitForCategories()
        _ = await eventually { await h.rowNames(.directMessages) == ["carol", "bob"] }
        let sections = await h.sections()
        #expect(sections.map(\.kind) == [.custom, .favorites, .channels, .directMessages])
        #expect(sections[0].title == "Work")
        #expect(sections[0].rows.map(\.displayName) == ["Channel 3", "Channel 1"])  // server (manual) order
        #expect(sections[2].isCollapsed)
        #expect(sections[2].categoryID == h.categoryID("channels"))
        #expect(await h.rowNames(.directMessages) == ["carol", "bob"])  // most recent first
        // A collapsed category shows unread and selected rows only.
        #expect(sections[2].visibleRows(selected: nil).isEmpty)
        #expect(sections[2].visibleRows(selected: .fixture(2)).map(\.channelID) == [.fixture(2)])
        #expect(h.service.calls.contains("sidebarCategories"))
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func unavailableCategoriesFallBackToSynthesizedSections() async {
        let h = await SidebarHarness(directory: { $0.categoriesError = .forbidden(ServerErrorInfo(id: "x", statusCode: 403, requestID: nil)) })
        _ = await eventually { await h.session.directory.categoriesUnavailable.contains(h.team.id) }
        let sections = await h.sections()
        #expect(sections.map(\.kind) == [.channels, .directMessages])
        #expect(sections.allSatisfy { $0.categoryID == nil })
        #expect(sections[0].rows.map(\.displayName) == ["Channel 1", "Channel 2", "Channel 3"])
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func newlyJoinedChannelsAppearBeforeTheCategoriesAreReRead() async {
        let h = await SidebarHarness()
        await h.waitForCategories()
        let extra = CoreFixtures.channel(9)
        await h.session.directoryInsertForTesting(extra)
        let channels = await h.sections().first { $0.kind == .channels }
        #expect(channels?.rows.map(\.channelID).contains(extra.id) == true)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func categoryEventsReReadTheSelectedTeamAndDropOtherTeams() async {
        let other = Team(id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "zz", displayName: "Zulu")
        let h = await SidebarHarness(configure: { $0.teams.append(other) })
        await h.waitForCategories()
        let before = h.service.calls.filter { $0 == "sidebarCategories" }.count
        // The server moved channel 2 into a new custom category.
        let work = SidebarCategory(id: SidebarCategoryID(unchecked: CoreFixtures.id("work", 1)), userID: h.me.id,
                                   teamID: h.team.id, kind: .custom, displayName: "Work", channelIDs: [.fixture(2)])
        let current = h.service.currentCategories(team: h.team.id)
        h.service.withDirectory { $0.categories[CoreFixtures.team.id] = [work] + current.map { category in
            var category = category
            category.channelIDs.removeAll { $0 == .fixture(2) }
            return category
        } }
        await h.realtime.push(.sidebarCategoriesChanged(teamID: h.team.id))
        #expect(await eventually { await h.sections().first?.title == "Work" })
        #expect(h.service.calls.filter { $0 == "sidebarCategories" }.count == before + 1)
        #expect(await h.rowNames(.custom) == ["Channel 2"])
        #expect(await h.rowNames(.channels) == ["Channel 1", "Channel 3"])
        // An event for a team that is not shown only drops its cached categories.
        await h.session.cacheCategoriesForTesting(team: other.id)
        await h.realtime.push(.sidebarCategoriesChanged(teamID: other.id))
        #expect(await eventually { await h.session.directory.categories[other.id] == nil })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func collapsingIsSavedOnTheServerWithAFreshChannelList() async throws {
        let h = await SidebarHarness()
        await h.waitForCategories()
        let id = h.categoryID("channels")
        // Another client added a channel since the sidebar was read.
        let latest = h.service.currentCategories(team: h.team.id).map { category in
            var category = category
            if category.kind == .channels { category.channelIDs.append(ChannelID(unchecked: CoreFixtures.id("ch", 42))) }
            return category
        }
        h.service.withDirectory { $0.categories[CoreFixtures.team.id] = latest }
        try await h.session.setCategoryCollapsed(id, collapsed: true)
        let saved = try #require(h.service.withDirectory { $0.updatedCategories.last })
        #expect(saved.isCollapsed)
        #expect(saved.channelIDs.contains(ChannelID(unchecked: CoreFixtures.id("ch", 42))))
        let calls = h.service.calls
        #expect((calls.lastIndex(of: "sidebarCategory") ?? .max) < (calls.lastIndex(of: "updateSidebarCategory") ?? -1))
        #expect(await h.sections().first { $0.kind == .channels }?.isCollapsed == true)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func refusedCollapseIsRevertedAndReported() async {
        let h = await SidebarHarness(directory: {
            $0.updateCategoryError = .forbidden(ServerErrorInfo(id: "api.context.permissions.app_error", statusCode: 403, requestID: nil))
        })
        await h.waitForCategories()
        await #expect(throws: UserFacingError.permissionDenied) {
            try await h.session.setCategoryCollapsed(h.categoryID("channels"), collapsed: true)
        }
        #expect(await h.sections().first { $0.kind == .channels }?.isCollapsed == false)
        #expect(await h.session.directory.pendingCollapse.isEmpty)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func groupingUnreadsKeepsTheActiveChannelUntilLeft() async {
        let h = await SidebarHarness(configure: { state in
            state.channels[.fixture(2)]?.totalMessageCount = 5
            state.channels[.fixture(3)]?.totalMessageCount = 2
            state.channels[.fixture(3)]?.lastPostAt = MattermostTimestamp(milliseconds: 50)
            state.memberships[.fixture(3)]?.mentionCount = 1
        })
        await h.waitForCategories()
        await h.session.setGroupsUnreads(true)
        var sections = await h.sections()
        #expect(sections.first?.kind == .unreads)
        // Mentions first.
        #expect(sections.first?.rows.map(\.channelID) == [.fixture(3), .fixture(2)])
        #expect(sections.first { $0.kind == .channels }?.rows.map(\.channelID) == [.fixture(1)])
        // Opening channel 2 marks it read, but it stays grouped while it is open.
        await h.session.openChannel(.fixture(2))
        await h.session.updateStickyUnreadForTesting()
        await h.session.markViewedLocally(.fixture(2), at: MattermostTimestamp(milliseconds: 1))
        sections = await h.sections()
        #expect(sections.first?.rows.map(\.channelID).contains(.fixture(2)) == true)
        await h.session.openChannel(.fixture(1))
        await h.session.updateStickyUnreadForTesting()
        sections = await h.sections()
        #expect(sections.first?.rows.map(\.channelID) == [.fixture(3)])
        await h.session.setGroupsUnreads(false)
        #expect(await h.sections().first?.kind != .unreads)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func otherTeamsUseServerUnreadCountsUntilLoaded() async {
        let other = Team(id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "zz", displayName: "Zeta",
                         iconRevision: 77)
        let h = await SidebarHarness(configure: { $0.teams.append(other) }, directory: { state in
            state.teamUnreads = [TeamUnread(teamID: other.id, messageCount: 3, mentionCount: 2)]
        })
        #expect(await eventually { await h.session.teamSummaries(collapsedThreads: false).last?.mentionCount == 2 })
        let zeta = await h.session.teamSummaries(collapsedThreads: false).last
        #expect(zeta?.hasUnread == true)
        #expect(zeta?.iconRevision == 77)
        // A post in an unloaded team refreshes the counts (coalesced).
        let before = h.service.calls.filter { $0 == "teamUnreads" }.count
        await h.session.noteTeamActivity(other.id)
        #expect(await eventually { h.service.calls.filter { $0 == "teamUnreads" }.count == before + 1 })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func teamIconsGoThroughTheBoundedPipeline() async {
        let other = Team(id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "zz", displayName: "Zeta", iconRevision: 5)
        let png = CoreFixtures.png(width: 64, height: 64)
        let h = await SidebarHarness(configure: { state in
            state.teams.append(other)
            state.imageHandler = { resource, _ in
                guard case .teamIcon(let team, 5) = resource, team == other.id else { throw APIError.cancelled }
                return png
            }
        })
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 4_096))
        let image = await h.session.teamIcon(other.id, revision: 5, maxPixelSize: 32, pipeline: pipeline)
        #expect(image?.image.width == 32)
        #expect(await h.session.teamIcon(other.id, revision: 0, maxPixelSize: 32, pipeline: pipeline) == nil)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func keyboardNavigationWrapsAndFindsUnreads() {
        func row(_ n: Int, unread: Bool = false, archived: Bool = false) -> SidebarChannelRow {
            SidebarChannelRow(channelID: .fixture(n), displayName: "\(n)", type: .open, isUnread: unread, mentionCount: 0,
                              isArchived: archived, isMuted: false, partnerStatus: nil, lastPostAt: .zero)
        }
        let snapshot = SidebarSnapshot(
            scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id), generation: 1, teams: [],
            selectedTeam: nil,
            sections: [SidebarSection(kind: .channels, rows: [row(1), row(2, unread: true), row(3, archived: true)]),
                       SidebarSection(kind: .custom, rows: [row(4), row(5, unread: true)], id: "c", isCollapsed: true)],
            isTruncated: false)
        #expect(snapshot.adjacentChannel(to: .fixture(1), offset: 1, unreadOnly: false) == .fixture(2))
        // Archived (unselected) and collapsed read rows are skipped.
        #expect(snapshot.adjacentChannel(to: .fixture(2), offset: 1, unreadOnly: false) == .fixture(5))
        #expect(snapshot.adjacentChannel(to: .fixture(5), offset: 1, unreadOnly: false) == .fixture(1))
        #expect(snapshot.adjacentChannel(to: .fixture(1), offset: -1, unreadOnly: false) == .fixture(5))
        #expect(snapshot.adjacentChannel(to: .fixture(5), offset: 1, unreadOnly: true) == .fixture(2))
        #expect(snapshot.adjacentChannel(to: nil, offset: 1, unreadOnly: false) == .fixture(1))
        #expect(snapshot.adjacentChannel(to: .fixture(2), offset: 1, unreadOnly: true) == .fixture(5))
        let lone = SidebarSnapshot(scope: snapshot.scope, generation: 1, teams: [], selectedTeam: nil,
                                   sections: [SidebarSection(kind: .channels, rows: [row(1)])], isTruncated: false)
        #expect(lone.adjacentChannel(to: .fixture(1), offset: 1, unreadOnly: false) == nil)
    }

    @Test func directMessagesBeyondTheLimitAreCounted() async {
        let h = await SidebarHarness(configure: { state in
            for n in 0..<45 {
                let user = User(id: UserID(unchecked: CoreFixtures.id("u", n)), username: "user\(n)")
                state.users[user.id] = user
                let channel = Channel(id: ChannelID(unchecked: CoreFixtures.id("d", n)), teamID: nil, type: .direct,
                                      name: [state.me.id.rawValue, user.id.rawValue].sorted().joined(separator: "__"),
                                      displayName: "", lastPostAt: MattermostTimestamp(milliseconds: Int64(n)))
                state.channels[channel.id] = channel
                state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: state.me.id)
            }
        })
        await h.waitForCategories()
        let directs = await h.sections().first { $0.kind == .directMessages }
        #expect(directs?.rows.count == ServerSession.visibleDirectMessages)
        #expect(directs?.hiddenCount == 5)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}

@Suite("Browse, create, messages and members", .serialized)
struct ChannelDirectoryTests {
    @Test func browseMarksMembershipCountsAndFiltersArchived() async throws {
        let joined = CoreFixtures.channel(1)
        var lobbyValue = CoreFixtures.channel(20)
        lobbyValue.purpose = "Say hello"
        var oldValue = CoreFixtures.channel(21)
        oldValue.deleteAt = MattermostTimestamp(milliseconds: 5)
        let lobby = lobbyValue
        let old = oldValue
        let h = await SidebarHarness(directory: { state in
            state.publicChannels[CoreFixtures.team.id] = [joined, lobby]
            state.archivedChannels[CoreFixtures.team.id] = [old]
            state.memberCounts[lobby.id] = 42
        })
        let page = try await h.session.browseChannels(term: "", archived: false, page: 0)
        #expect(page.items.map(\.channelID) == [joined.id, lobby.id])
        #expect(page.items.map(\.isMember) == [true, false])
        #expect(page.items[1].memberCount == 42)
        #expect(page.items[1].purpose == "Say hello")
        #expect(!page.hasMore)
        let archived = try await h.session.browseChannels(term: "", archived: true, page: 0)
        #expect(archived.items.map(\.channelID) == [old.id])
        // Search results are split by archive state.
        #expect(try await h.session.browseChannels(term: "channel-2", archived: false, page: 0).items.map(\.channelID) == [lobby.id])
        #expect(try await h.session.browseChannels(term: "channel-2", archived: true, page: 0).items.map(\.channelID) == [old.id])
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func archivedBrowsingRespectsTheServerSetting() async {
        let h = await SidebarHarness()
        await h.session.setViewArchivedChannelsForTesting(false)
        await #expect(throws: UserFacingError.self) { _ = try await h.session.browseChannels(term: "", archived: true, page: 0) }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func joiningLoadsTheChannelForImmediateSelection() async throws {
        let lobby = CoreFixtures.channel(20)
        let h = await SidebarHarness(directory: { $0.publicChannels[CoreFixtures.team.id] = [lobby] })
        h.service.withState { state in
            // The fake's join makes the channel and membership readable.
            state.channels[lobby.id] = lobby
            state.memberships[lobby.id] = ChannelMembership(channelID: lobby.id, userID: state.me.id)
        }
        let id = try await h.session.joinAndLoadChannel(lobby.id)
        #expect(id == lobby.id)
        #expect(await h.session.directory.memberships[lobby.id] != nil)
        #expect(await h.sections().contains { $0.rows.contains { $0.channelID == lobby.id } })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func createChannelValidatesAndMapsServerRefusals() async throws {
        let h = await SidebarHarness()
        await #expect(throws: ChannelCreationError.invalidName(.tooShort)) {
            _ = try await h.session.createChannel(displayName: "X", name: "x", purpose: "", isPrivate: false)
        }
        await #expect(throws: ChannelCreationError.missingDisplayName) {
            _ = try await h.session.createChannel(displayName: "  ", name: "valid", purpose: "", isPrivate: false)
        }
        await #expect(throws: ChannelCreationError.purposeTooLong) {
            _ = try await h.session.createChannel(displayName: "Ok", name: "valid", purpose: String(repeating: "p", count: 251),
                                                  isPrivate: false)
        }
        #expect(h.service.withDirectory { $0.createdChannels.isEmpty })
        // channel-1 exists on the team.
        await #expect(throws: ChannelCreationError.nameTaken) {
            _ = try await h.session.createChannel(displayName: "Dup", name: "channel-1", purpose: "", isPrivate: false)
        }
        let id = try await h.session.createChannel(displayName: " Release plan ", name: "release-plan", purpose: "Ship",
                                                   isPrivate: true)
        let request = try #require(h.service.withDirectory { $0.createdChannels.last })
        #expect(request.displayName == "Release plan")
        #expect(request.isPrivate)
        #expect(await h.session.directory.channels[id]?.type == .private)
        #expect(await h.sections().contains { $0.rows.contains { $0.channelID == id } })

        h.service.withDirectory {
            $0.createChannelError = .forbidden(ServerErrorInfo(id: "api.context.permissions.app_error", statusCode: 403, requestID: nil))
        }
        await #expect(throws: ChannelCreationError.permissionDenied(isPrivate: false)) {
            _ = try await h.session.createChannel(displayName: "Nope", name: "nope", purpose: "", isPrivate: false)
        }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func conversationsUseDirectOrGroupChannels() async throws {
        let carol = User(id: UserID(unchecked: CoreFixtures.id("carol", 1)), username: "carol")
        let dave = User(id: UserID(unchecked: CoreFixtures.id("dave", 1)), username: "dave")
        let h = await SidebarHarness(configure: { state in
            state.users[carol.id] = carol
            state.users[dave.id] = dave
        })
        let direct = try await h.session.conversation(with: [CoreFixtures.bob.id, CoreFixtures.me.id])
        #expect(await h.session.directory.channels[direct]?.type == .direct)
        let group = try await h.session.conversation(with: [CoreFixtures.bob.id, carol.id, dave.id, carol.id])
        #expect(await h.session.directory.channels[group]?.type == .group)
        #expect(h.service.withDirectory { $0.createdGroups } == [[CoreFixtures.bob.id, carol.id, dave.id]])
        let tooMany = (0..<8).map { UserID(unchecked: CoreFixtures.id("many", $0)) }
        await #expect(throws: UserFacingError.self) { _ = try await h.session.conversation(with: tooMany) }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func addMembersReportsPermissionFailures() async throws {
        let h = await SidebarHarness()
        _ = await eventually { await h.session.directory.channels[.fixture(1)] != nil }
        try await h.session.addMembers([CoreFixtures.bob.id, CoreFixtures.me.id, CoreFixtures.bob.id], to: .fixture(1))
        let added = h.service.withDirectory { $0.addedMembers.map(\.1) }
        #expect(added == [[CoreFixtures.bob.id]])
        h.service.withDirectory {
            $0.addMembersError = .forbidden(ServerErrorInfo(id: "api.context.permissions.app_error", statusCode: 403, requestID: nil))
        }
        await #expect(throws: UserFacingError.permissionDenied) {
            try await h.session.addMembers([CoreFixtures.bob.id], to: .fixture(1))
        }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func peopleSearchExcludesSelfAndScopesToTheChannelTeam() async throws {
        let h = await SidebarHarness()
        _ = await eventually { await h.session.directory.channels[.fixture(1)] != nil }
        let found = try await h.session.searchUsers("b", notInChannel: .fixture(1))
        #expect(found.map(\.username) == ["bob"])
        let query = try #require(h.service.withDirectory { $0.userSearches.last })
        #expect(query.team == CoreFixtures.team.id)
        #expect(query.notInChannel == .fixture(1))
        #expect(try await h.session.searchUsers("alice").isEmpty)
        #expect(try await h.session.searchUsers("   ").isEmpty)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}

extension ServerSession {
    func directoryInsertForTesting(_ channel: Channel) {
        directory.upsertChannel(channel)
        directory.upsertMembership(ChannelMembership(channelID: channel.id, userID: me.id))
    }

    func cacheCategoriesForTesting(team: TeamID) {
        directory.replaceCategories(team: team, [SidebarCategory(
            id: SidebarCategoryID(unchecked: "channels_" + me.id.rawValue + "_" + team.rawValue), userID: me.id,
            teamID: team, kind: .channels, displayName: "Channels")])
    }

    func updateStickyUnreadForTesting() { updateStickyUnread(collapsedThreads: false) }

    func setViewArchivedChannelsForTesting(_ value: Bool) { directory.viewArchivedChannels = value }
}
