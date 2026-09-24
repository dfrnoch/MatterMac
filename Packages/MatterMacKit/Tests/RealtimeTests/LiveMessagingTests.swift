import Foundation
import Testing
import MatterMacModels
import MattermostAPI
import MattermostRealtime

/// Opt-in only, restricted to the three repository-owned loopback test servers.
/// Both peers use native API clients; this is not official-web-client UI proof.
@Suite("Live normal-user REST and WebSocket messaging", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveMessagingTests {
    enum Failure: Error { case missingCredentials, deadline, stopped, missingChannel }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func twoUsersAndDirectMessages(base: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let alicePassword = env["MM_TEST_ALICE_PASSWORD"], let bobPassword = env["MM_TEST_BOB_PASSWORD"]
        else { throw Failure.missingCredentials }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let alice: LoginResult, bob: LoginResult
        do {
            #expect(try await discovery.ping() != nil)
            alice = try await discovery.login(LoginRequest(loginID: "alice", password: alicePassword))
            bob = try await discovery.login(LoginRequest(loginID: "bob", password: bobPassword))
        } catch {
            await discovery.shutdown()
            throw error
        }
        await discovery.shutdown()
        let a = factory.service(for: endpoint, credential: alice.credential)
        let b = factory.service(for: endpoint, credential: bob.credential)
        let socketA = MattermostRealtimeClient(endpoint: endpoint, credential: alice.credential, currentUserID: alice.user.id)
        let socketB = MattermostRealtimeClient(endpoint: endpoint, credential: bob.credential, currentUserID: bob.user.id)
        do {
            await socketA.start()
            await socketB.start()
            try await wait(socketA) { if case .state(.connected) = $0 { true } else { false } }
            try await wait(socketB) { if case .state(.connected) = $0 { true } else { false } }
            let teams = try await a.teams()
            guard let team = teams.first(where: { $0.name == "qa" }) else { throw Failure.missingChannel }
            let channels = try await a.channels(team: team.id)
            guard let channel = channels.first(where: { $0.name == "interop" }) else { throw Failure.missingChannel }
            let dm = try await a.createDirectChannel(with: bob.user.id, me: alice.user.id)
            for id in [channel.id, dm.id] {
                try await exchange(sender: a, receiver: b, socket: socketB, user: alice.user.id, channel: id)
                try await exchange(sender: b, receiver: a, socket: socketA, user: bob.user.id, channel: id)
            }
        } catch {
            await socketA.stop(); await socketB.stop()
            try? await a.logout(); try? await b.logout()
            await a.shutdown(); await b.shutdown()
            throw error
        }
        await socketA.stop(); await socketB.stop()
        try await a.logout(); try await b.logout()
        await a.shutdown(); await b.shutdown()
    }

    private func exchange(sender: any MattermostService, receiver: any MattermostService,
                          socket: MattermostRealtimeClient, user: UserID, channel: ChannelID) async throws {
        let pending = PendingPostID(rawValue: "\(user.rawValue):\(UUID().uuidString)")!
        let post = try await sender.createPost(OutgoingPost(channelID: channel, rootID: nil,
            message: "MatterMac synthetic recovery integration check", fileIDs: [], pendingPostID: pending))
        do {
            try await wait(socket) {
                if case .event(.posted(let event)) = $0 { event.post.id == post.id } else { false }
            }
            let fetched = try await receiver.post(post.id)
            #expect(fetched.id == post.id)
            #expect(fetched.userID == user)
            let edited = try await sender.editPost(post.id, message: "MatterMac synthetic edited check")
            try await wait(socket) {
                if case .event(.postEdited(let event)) = $0 { event.id == edited.id } else { false }
            }
            _ = try await sender.addReaction(post: post.id, emojiName: "thumbsup", me: user)
            try await wait(socket) {
                if case .event(.reactionAdded(let event)) = $0 { event.postID == post.id } else { false }
            }
        } catch {
            try? await sender.deletePost(post.id)
            throw error
        }
        try await sender.deletePost(post.id)
        try await wait(socket) {
            if case .event(.postDeleted(let event)) = $0 { event.id == post.id } else { false }
        }
    }

    private func wait(_ socket: MattermostRealtimeClient,
                      matching: @escaping @Sendable (RealtimeDelivery) -> Bool) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while let delivery = await socket.nextDelivery() {
                    if matching(delivery) { return }
                }
                throw Failure.stopped
            }
            group.addTask { try await Task.sleep(for: .seconds(15)); throw Failure.deadline }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
