import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

/// The channel details pane inside the real SwiftUI shell with a large member list,
/// long names and avatar images, at the minimum and default window widths.
@MainActor
@Suite("Channel details pane", .serialized)
struct ChannelInfoPaneTests {
    @Test(arguments: [760.0, 1100.0])
    func largeMemberListRendersPagesFiltersAndResizes(width: Double) async throws {
        let channel = CoreFixtures.channel(1)
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let png = CoreFixtures.png(width: 96, height: 96)
        service.withState { state in
            state.teams = [CoreFixtures.team]
            state.channels[channel.id] = channel
            state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: CoreFixtures.me.id)
            for n in 0..<150 {
                let user = User(id: UserID(unchecked: CoreFixtures.id("member", n)), username: String(format: "member.%03d", n),
                                firstName: "Maximiliána Alexandra \(n)", lastName: "Featherstonehaugh-Montgomery-Llewellyn",
                                position: "Senior Principal Engineer, Platform Reliability")
                state.users[user.id] = user
            }
            state.imageHandler = { _, _ in png }
        }
        let app = AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
            makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) }))
        let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
            login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
            capabilities: ServerCapabilities())
        let model = SessionViewModel(slot: slot, app: app)
        await slot.session.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let host = NSHostingController(rootView: MainWindowView(app: app, session: model)
            .frame(minWidth: 760, minHeight: 500))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 600))
        window.orderFrontRegardless()
        defer { window.close() }

        try await settle(window) { model.selectedChannel == channel.id && model.header != nil }
        // Opening details while a thread is open swaps the trailing pane in one update.
        let root = CoreFixtures.post(1, channel: channel.id)
        service.withState { $0.posts[root.id] = root }
        model.openThread(root: root.id)
        try await settle(window) { model.thread != nil }
        #expect(model.thread != nil)
        try await settle(window, iterations: 10)
        // The toolbar toggle writes through a SwiftUI binding (key-path write).
        Bindable(model).isChannelInfoVisible.wrappedValue = true
        #expect(model.thread == nil)
        try await settle(window) { service.calls.filter { $0 == "channelMembers" }.count >= 1 }
        try await settle(window, iterations: 20)
        #expect(service.calls.filter { $0 == "channelMembers" }.count == 1)

        // Second page, filtering and window resizes while rows and images update.
        let page = try await model.channelMembers(channel.id, page: 1)
        #expect(page.members.count == ServerSession.channelMembersPageSize)
        for size in [NSSize(width: 800, height: 520), NSSize(width: 1400, height: 800), NSSize(width: width, height: 600)] {
            window.setContentSize(size)
            try await settle(window, iterations: 5)
        }
        model.openThread(root: root.id)
        #expect(!model.isChannelInfoVisible)
        try await settle(window) { model.thread != nil }
        try await settle(window, iterations: 10)
        model.isChannelInfoVisible = false
        try await settle(window, iterations: 5)
        model.isChannelInfoVisible = true
        try await settle(window, iterations: 20)

        // Profile cards: the AppKit popover (timeline) and the SwiftUI popover (members).
        let member = UserID(unchecked: CoreFixtures.id("member", 3))
        let anchor = try #require(window.contentView)
        ProfilePopover.show(session: model, lookup: .id(member), relativeTo: NSRect(x: 300, y: 300, width: 4, height: 4),
                            of: anchor)
        try await settle(window, iterations: 40)
        let presenter = PopoverPresenter(session: model, user: member)
        let popoverHost = NSHostingView(rootView: presenter)
        popoverHost.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        anchor.addSubview(popoverHost)
        try await settle(window, iterations: 40)
        popoverHost.removeFromSuperview()
        model.prepareForSignOut()
        await app.registry.removeAll()
    }

    /// The pane with a Markdown header, presence and a bot member row on screen (a
    /// bot row once crashed the list), in both appearances at the minimum and default
    /// widths. With `MM_SNAPSHOT_DIR` set (development review only), it also captures
    /// this test's own window, never the screen.
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua], [760.0, 1100.0])
    func paneRendersHeaderPresenceAndBotMembers(appearance: NSAppearance.Name, width: Double) async throws {
        let base = CoreFixtures.channel(1)
        let channel = Channel(id: base.id, teamID: base.teamID, type: .open, name: "dev-regioapp-lite",
                              displayName: "dev-regioapp-lite",
                              header: "[staging-web](https://staging.example.com), [prod-web](https://www.example.com) · **Docs:** https://docs.example.com/app",
                              purpose: "Development of the RegioApp Lite mobile app: builds, releases and QA.")
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        service.withState { state in
            state.teams = [CoreFixtures.team]
            state.channels[channel.id] = channel
            state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: CoreFixtures.me.id)
            let people: [(String, String, String, PresenceStatus, Bool)] = [
                ("alice", "Alice", "Nováková", .online, false), ("bob", "Bob", "Dvořák", .away, false),
                ("carol", "Carol", "Svobodová", .doNotDisturb, false), ("dan", "Dan", "Horák", .offline, false),
                ("deploy-bot", "Deploy", "Bot", .online, true),
            ]
            for (n, person) in people.enumerated() {
                let user = User(id: UserID(unchecked: CoreFixtures.id("member", n)), username: person.0,
                                firstName: person.1, lastName: person.2, isBot: person.4)
                state.users[user.id] = user
                state.statuses[user.id] = person.3
            }
        }
        let app = AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
            makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, limits in MarkupParser.parse(text, limits: limits) }))
        let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
            login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
            capabilities: ServerCapabilities())
        let model = SessionViewModel(slot: slot, app: app)
        await slot.session.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1080),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingController(rootView: MainWindowView(app: app, session: model)
            .frame(minWidth: 760, minHeight: 500))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 1080))
        window.orderFrontRegardless()
        defer { window.close() }

        try await settle(window) { model.selectedChannel == channel.id && model.header != nil }
        model.isChannelInfoVisible = true
        try await settle(window) { service.calls.contains("channelMembers") }
        try await settle(window, iterations: 40)
        #expect(model.isChannelInfoVisible)
        #expect(service.calls.filter { $0 == "channelMembers" }.count == 1)
        if let directory = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] {
            let name = "channel-info-\(Int(width))-\(appearance == .darkAqua ? "dark" : "light").png"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                 URL(fileURLWithPath: directory).appendingPathComponent(name).path]
            try process.run()
            process.waitUntilExit()
        }
        model.prepareForSignOut()
        await app.registry.removeAll()
    }

    private struct PopoverPresenter: View {
        let session: SessionViewModel
        let user: UserID
        @State private var shown = false
        var body: some View {
            Color.clear
                .popover(isPresented: $shown) { UserProfileCard(session: session, lookup: .id(user)) { shown = false } }
                .onAppear { shown = true }
        }
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
