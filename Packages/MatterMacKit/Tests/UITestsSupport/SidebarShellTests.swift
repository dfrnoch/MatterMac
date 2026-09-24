import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

/// The sidebar inside the real SwiftUI shell: server categories, the team rail,
/// drafts, keyboard navigation, and every directory sheet, at the minimum and
/// default widths. `MM_SNAPSHOT_DIR` optionally captures only this test's windows.
@MainActor
@Suite("Sidebar shell", .serialized)
struct SidebarShellTests {
    nonisolated static let otherTeam = Team(id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "zulu", displayName: "Zulu Ops",
                                iconRevision: 9)

    @Test(arguments: [760.0, 1100.0])
    func categoriesRailSheetsAndNavigation(width: Double) async throws {
        _ = NSApplication.shared
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let me = CoreFixtures.me.id
        let team = CoreFixtures.team.id
        let png = CoreFixtures.png(width: 64, height: 64)
        service.withState { state in
            state.teams = [CoreFixtures.team, Self.otherTeam]
            state.users[CoreFixtures.bob.id] = CoreFixtures.bob
            for n in 1...6 {
                var channel = CoreFixtures.channel(n)
                channel.displayName = ["Town Square", "Design reviews with a very long channel name for truncation",
                                       "Release", "Random", "Support", "Ops"][n - 1]
                if n == 3 { channel.totalMessageCount = 4 }
                state.channels[channel.id] = channel
                var member = ChannelMembership(channelID: channel.id, userID: me)
                if n == 5 { member.mentionCount = 3; member.markUnread = .mention }
                state.memberships[channel.id] = member
            }
            let dm = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", 1)), teamID: nil, type: .direct,
                             name: [me.rawValue, CoreFixtures.bob.id.rawValue].sorted().joined(separator: "__"), displayName: "")
            state.channels[dm.id] = dm
            state.memberships[dm.id] = ChannelMembership(channelID: dm.id, userID: me)
            state.imageHandler = { _, _ in png }
        }
        service.withDirectory { directory in
            func id(_ kind: String) -> SidebarCategoryID { SidebarCategoryID(unchecked: kind + "_" + me.rawValue + "_" + team.rawValue) }
            directory.categories[team] = [
                SidebarCategory(id: id("favorites"), userID: me, teamID: team, kind: .favorites, displayName: "Favorites",
                                channelIDs: [CoreFixtures.channel(3).id]),
                SidebarCategory(id: SidebarCategoryID(unchecked: CoreFixtures.id("work", 1)), userID: me, teamID: team,
                                kind: .custom, displayName: "Work streams", isMuted: true,
                                channelIDs: [CoreFixtures.channel(2).id, CoreFixtures.channel(5).id]),
                SidebarCategory(id: id("channels"), userID: me, teamID: team, kind: .channels, displayName: "Channels",
                                sorting: .alphabetical,
                                channelIDs: [CoreFixtures.channel(1).id, CoreFixtures.channel(4).id, CoreFixtures.channel(6).id]),
                SidebarCategory(id: id("direct_messages"), userID: me, teamID: team, kind: .directMessages,
                                displayName: "Direct Messages", sorting: .recent),
            ]
            directory.teamUnreads = [TeamUnread(teamID: Self.otherTeam.id, messageCount: 2, mentionCount: 1)]
            directory.publicChannels[team] = [CoreFixtures.channel(1), CoreFixtures.channel(30)]
        }
        let app = AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
            makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) }))
        let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
            login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
            capabilities: ServerCapabilities())
        let model = SessionViewModel(slot: slot, app: app)
        await slot.session.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let host = NSHostingController(rootView: MainWindowView(app: app, session: model).frame(minWidth: 760, minHeight: 500))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 640))
        window.orderFrontRegardless()
        defer { window.close() }

        try await settle(window) { model.sidebar?.usesServerCategories == true && model.selectedChannel != nil }
        let sidebar = try #require(model.sidebar)
        #expect(sidebar.sections.map(\.kind) == [.favorites, .custom, .channels, .directMessages])
        #expect(sidebar.sections[1].title == "Work streams")
        #expect(sidebar.sections[1].isMuted)
        #expect(sidebar.sections[2].rows.map(\.displayName) == ["Ops", "Random", "Town Square"])
        #expect(sidebar.sections[0].rows.first?.isFavorite == true)
        #expect(sidebar.teams.map(\.displayName) == ["QA", "Zulu Ops"])
        #expect(sidebar.teams[1].mentionCount == 1)
        #expect(WorkspaceRail.isShown(app: app, sidebar: sidebar))
        // A draft in another channel shows the pencil (read on re-render).
        let draftChannel = CoreFixtures.channel(4).id
        try app.environment.drafts.save(Draft(text: "draft"), for: DraftKey(scope: model.scope, channelID: draftChannel, rootID: nil))
        model.select(channel: CoreFixtures.channel(1).id)
        try await settle(window) { model.header?.channelID == CoreFixtures.channel(1).id }
        try await settle(window, iterations: 20)
        await snapshot(window, "sidebar-\(Int(width)).png")

        // Keyboard navigation follows on-screen order.
        let order = sidebar.visibleRows(selected: model.selectedChannel).map(\.channelID)
        model.selectAdjacentChannel(1, unreadOnly: false)
        let expected = order[(order.firstIndex(of: CoreFixtures.channel(1).id)! + 1) % order.count]
        #expect(model.selectedChannel == expected)
        model.selectAdjacentChannel(1, unreadOnly: true)
        // The unread channels are Release (messages) and Support (muted, with mentions).
        #expect([CoreFixtures.channel(3).id, CoreFixtures.channel(5).id].contains(try #require(model.selectedChannel)))

        // Collapsing is a server change; the selected row stays visible.
        let channels = try #require(model.sidebar?.sections.first { $0.kind == .channels })
        model.setCategoryCollapsed(channels, collapsed: true)
        try await settle(window) { model.sidebar?.sections.first { $0.kind == .channels }?.isCollapsed == true }
        #expect(service.withDirectory { $0.updatedCategories.last?.isCollapsed } == true)

        // Group unread channels separately (local).
        model.setGroupsUnreads(true)
        try await settle(window) { model.sidebar?.sections.first?.kind == .unreads }
        await snapshot(window, "sidebar-unreads-\(Int(width)).png")
        model.setGroupsUnreads(false)
        try await settle(window) { model.sidebar?.groupsUnreads == false }

        // Every directory sheet renders and closes.
        for sheet in [DirectorySheet.browseChannels, .createChannel, .newMessage, .addMembers(CoreFixtures.channel(1).id)] {
            model.directorySheet = sheet
            try await settle(window) { window.attachedSheet != nil }
            try await settle(window, iterations: 30)
            #expect(window.attachedSheet != nil)
            if let attached = window.attachedSheet { await snapshot(attached, "sheet-\(sheet.snapshotName)-\(Int(width)).png") }
            model.directorySheet = nil
            try await settle(window) { window.attachedSheet == nil }
        }
        #expect(service.calls.contains("publicChannels"))

        // Team switching (⌘2) and back (⌘1).
        model.selectTeam(at: 1)
        try await settle(window) { model.sidebar?.selectedTeam == Self.otherTeam.id }
        try await settle(window, iterations: 10)
        model.selectTeam(at: 0)
        try await settle(window) { model.sidebar?.selectedTeam == team }
        for size in [NSSize(width: 800, height: 520), NSSize(width: 1400, height: 800), NSSize(width: width, height: 640)] {
            window.setContentSize(size)
            try await settle(window, iterations: 5)
        }
        model.prepareForSignOut()
        await app.registry.removeAll()
    }

    @Test func sheetsPerformTheirServerActions() async throws {
        _ = NSApplication.shared
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let carol = User(id: UserID(unchecked: CoreFixtures.id("carol", 1)), username: "carol")
        let lobby = CoreFixtures.channel(20)
        service.withState { state in
            state.teams = [CoreFixtures.team]
            state.users[CoreFixtures.bob.id] = CoreFixtures.bob
            state.users[carol.id] = carol
            let channel = CoreFixtures.channel(1)
            state.channels[channel.id] = channel
            state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: CoreFixtures.me.id)
        }
        service.withDirectory { $0.publicChannels[CoreFixtures.team.id] = [CoreFixtures.channel(1), lobby] }
        let app = AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
            makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) }))
        let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
            login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
            capabilities: ServerCapabilities())
        let model = SessionViewModel(slot: slot, app: app)
        await slot.session.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = NSHostingController(rootView: MainWindowView(app: app, session: model)
            .frame(minWidth: 760, minHeight: 500))
        window.orderFrontRegardless()
        defer { window.close() }
        try await settle(window) { model.selectedChannel != nil }

        // Browse → Join opens the channel.
        let page = try await model.browseChannels(term: "", archived: false, page: 0)
        #expect(page.items.first { $0.channelID == lobby.id }?.isMember == false)
        service.withState { state in
            state.channels[lobby.id] = lobby
            state.memberships[lobby.id] = ChannelMembership(channelID: lobby.id, userID: state.me.id)
        }
        try await model.joinAndOpen(lobby.id)
        #expect(model.selectedChannel == lobby.id)

        // Create Channel navigates to the new channel.
        try await model.createChannel(displayName: "Release plan", name: "release-plan", purpose: "", isPrivate: false)
        try await settle(window) { model.header?.displayName == "Release plan" }
        #expect(model.header?.displayName == "Release plan")

        // New message: one person → DM, two → group message.
        try await model.openConversation(with: [CoreFixtures.bob.id])
        try await settle(window) { model.header?.type == .direct }
        #expect(model.header?.type == .direct)
        try await model.openConversation(with: [CoreFixtures.bob.id, carol.id])
        try await settle(window) { model.header?.type == .group }
        #expect(model.header?.type == .group)

        // Add members: people already in the channel are excluded by the server.
        let people = try await model.searchUsers("car", notInChannel: CoreFixtures.channel(1).id)
        #expect(people.map(\.username) == ["carol"])
        let revision = model.channelInfoRevision
        try await model.addMembers([carol.id], to: CoreFixtures.channel(1).id)
        #expect(model.channelInfoRevision == revision &+ 1)
        #expect(service.withDirectory { $0.addedMembers.last?.1 } == [carol.id])
        model.prepareForSignOut()
        await app.registry.removeAll()
    }

    private func snapshot(_ window: NSWindow, _ name: String) async {
        guard let directory = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] else { return }
        try? await settle(window, iterations: 10)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent(name).path]
        try? process.run()
        process.waitUntilExit()
    }

    private func settle(_ window: NSWindow, iterations: Int = 200, until condition: () -> Bool = { false }) async throws {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }
}

extension DirectorySheet {
    var snapshotName: String {
        switch self {
        case .browseChannels: "browse"
        case .createChannel: "create"
        case .newMessage: "message"
        case .addMembers: "members"
        }
    }
}
