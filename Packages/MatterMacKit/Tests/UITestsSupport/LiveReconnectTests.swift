import Foundation
import Testing
import MatterMacModels
@testable import MatterMacCore
import MattermostAPI
import MattermostRealtime
@testable import MatterMacUI

/// Closes a real native socket; only connection admission is controlled by the test.
/// One channel and scalar counters, no suspended continuations or unbounded history.
private actor InterruptedLiveTransport: WebSocketTransport {
    private let production = URLSessionWebSocketTransport()
    private var channel: (any WebSocketChannel)?
    private var blocked = false
    private(set) var refusedConnections = 0
    private(set) var openedConnections = 0

    func connect(url: URL, headers: [String: String], maximumMessageSize: Int)
        async throws(WebSocketTransportError) -> any WebSocketChannel {
        guard !blocked else { refusedConnections += 1; throw .network(.offline) }
        let opened = try await production.connect(url: url, headers: headers, maximumMessageSize: maximumMessageSize)
        guard !blocked, !Task.isCancelled else { opened.close(); throw .cancelled }
        channel?.close()
        channel = opened
        openedConnections += 1
        return opened
    }

    func interrupt() {
        blocked = true
        channel?.close()
        channel = nil
    }

    func release() { blocked = false }
}

@MainActor
@Suite("Live native reconnect gap", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveReconnectTests {
    enum Failure: Error { case missingCredentials, channel
        case deadline(Int) }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func reconcilesMissedPostsEditsDeletesWithoutChangingDraft(base: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let alicePassword = env["MM_TEST_ALICE_PASSWORD"], let bobPassword = env["MM_TEST_BOB_PASSWORD"]
        else { throw Failure.missingCredentials }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let alice: LoginResult, bob: LoginResult
        do {
            alice = try await discovery.login(LoginRequest(loginID: "alice", password: alicePassword))
            bob = try await discovery.login(LoginRequest(loginID: "bob", password: bobPassword))
        } catch { await discovery.shutdown(); throw error }
        await discovery.shutdown()
        let bobAPI = factory.service(for: endpoint, credential: bob.credential)
        let transport = InterruptedLiveTransport()
        let app = AppModel(environment: AppEnvironment(allowsInsecureLoopback: true, serviceFactory: factory,
            makeRealtime: { MattermostRealtimeClient(endpoint: $0, credential: $1, currentUserID: $2, transport: transport) },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
        var remaining: [PostID] = []
        do {
            try await app.completeLogin(alice, discovery: DiscoveryResult(endpoint: endpoint, version: nil,
                capabilities: ServerCapabilities()), remember: false)
            let model = try #require(app.activeSession)
            try await wait(1) { model.connection == .connected }
            let teams = try await bobAPI.teams()
            guard let team = teams.first(where: { $0.name == "qa" }) else { throw Failure.channel }
            await model.session.selectTeam(team.id)
            let channels = try await bobAPI.channels(team: team.id)
            guard let channel = channels.first(where: { $0.name == "interop" })?.id else { throw Failure.channel }
            try await wait(2) { model.sidebar?.sections.flatMap(\.rows).contains(where: { $0.channelID == channel }) == true }
            model.select(channel: channel)
            try await wait(3) { await model.session.windows[.channel(channel)]?.isLoaded == true }
            // Existing local QA accounts may open at an old unread boundary.
            // New posts are intentionally not retained until that window reaches live.
            await model.session.jumpToLiveEdge(.channel(channel))
            try await wait(3) {
                guard let window = await model.session.windows[.channel(channel)] else { return false }
                return window.isLoaded && !window.hasNewer
            }
            let key = DraftKey(scope: model.scope, channelID: channel, rootID: nil)
            let draft = Draft(text: "Unsent reconnect draft", selectedRange: NSRange(location: 2, length: 5))
            try app.environment.drafts.save(draft, for: key)
            let marker = "MatterMac reconnect " + UUID().uuidString
            let editable = try await create(marker + " original", channel: channel, user: bob.user.id, service: bobAPI)
            remaining.append(editable.id)
            let deletable = try await create(marker + " delete", channel: channel, user: bob.user.id, service: bobAPI)
            remaining.append(deletable.id)
            try await wait(4) {
                let edit = await model.session.post(editable.id)
                let deletion = await model.session.post(deletable.id)
                return edit != nil && deletion != nil
            }

            await transport.interrupt()
            try await wait(5) { await transport.refusedConnections > 0 && model.connection != .connected }
            _ = try await bobAPI.editPost(editable.id, message: marker + " edited offline")
            try await bobAPI.deletePost(deletable.id)
            remaining.removeAll { $0 == deletable.id }
            let created = try await create(marker + " created offline", channel: channel, user: bob.user.id, service: bobAPI)
            remaining.append(created.id)
            // Confirm Alice really missed the events before permitting a new real socket.
            #expect(await model.session.post(editable.id)?.message == editable.message)
            #expect(await model.session.post(deletable.id)?.isDeleted == false)
            #expect(await model.session.post(created.id) == nil)
            #expect(app.environment.drafts.draft(for: key) == draft)
            await transport.release()
            try await wait(6) {
                guard model.connection == .connected,
                      await model.session.post(editable.id)?.message == marker + " edited offline",
                      await model.session.post(created.id)?.message == created.message else { return false }
                let deleted = await model.session.post(deletable.id)
                return deleted == nil || deleted?.isDeleted == true
            }
            #expect(await transport.openedConnections >= 2)
            #expect(app.environment.drafts.draft(for: key) == draft)
            model.prepareForSignOut()
        } catch {
            for id in remaining { try? await bobAPI.deletePost(id) }
            await app.shutdownAll()
            try? await bobAPI.logout()
            await bobAPI.shutdown()
            throw error
        }
        var cleanupFailed = false
        for id in remaining { do { try await bobAPI.deletePost(id) } catch { cleanupFailed = true } }
        await app.shutdownAll()
        try await bobAPI.logout()
        await bobAPI.shutdown()
        #expect(!cleanupFailed)
        #expect(app.registry.slots.isEmpty)
        #expect(app.environment.unsentLedger.usage.totalBytes == 0)
    }

    private func create(_ text: String, channel: ChannelID, user: UserID, service: any MattermostService) async throws -> Post {
        try await service.createPost(OutgoingPost(channelID: channel, rootID: nil, message: text, fileIDs: [],
            pendingPostID: PendingPostID(rawValue: "\(user.rawValue):\(UUID().uuidString)")!))
    }

    private func wait(_ stage: Int, _ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(40)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw Failure.deadline(stage) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
