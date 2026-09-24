import Foundation
import Testing
import MatterMacModels
import MattermostAPI

/// Opt-in: followed-thread endpoints on the local servers (collapsed reply threads
/// default `always_on`). Posts created here are deleted afterwards.
@Suite("Live followed threads", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveThreadsTests {
    enum Failure: Error { case missingCredentials, missingChannel }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func followReadAndUnfollow(base: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let alicePassword = env["MM_TEST_ALICE_PASSWORD"], let bobPassword = env["MM_TEST_BOB_PASSWORD"]
        else { throw Failure.missingCredentials }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let alice = try await discovery.login(LoginRequest(loginID: "alice", password: alicePassword))
        let bob = try await discovery.login(LoginRequest(loginID: "bob", password: bobPassword))
        await discovery.shutdown()
        let a = factory.service(for: endpoint, credential: alice.credential)
        let b = factory.service(for: endpoint, credential: bob.credential)
        var created: [PostID] = []
        do {
            guard let team = try await a.teams().first(where: { $0.name == "qa" }),
                  let channel = try await a.channels(team: team.id).first(where: { $0.name == "interop" })
            else { throw Failure.missingChannel }
            let pending = PendingPostID(rawValue: "\(alice.user.id.rawValue):\(UUID().uuidString)")!
            let root = try await a.createPost(OutgoingPost(channelID: channel.id, rootID: nil,
                message: "MatterMac thread check", fileIDs: [], pendingPostID: pending))
            created.append(root.id)
            let replyPending = PendingPostID(rawValue: "\(bob.user.id.rawValue):\(UUID().uuidString)")!
            let reply = try await b.createPost(OutgoingPost(channelID: channel.id, rootID: root.id,
                message: "MatterMac reply @alice", fileIDs: [], pendingPostID: replyPending))
            created.append(reply.id)
            try await Task.sleep(for: .milliseconds(300))

            let list = try await a.userThreads(team: team.id, me: alice.user.id, before: nil, perPage: 25,
                                               unreadOnly: false, totalsOnly: false)
            let thread = try #require(list.threads.first { $0.root.id == root.id })
            #expect(thread.replyCount == 1)
            #expect(thread.unreadReplies == 1)
            #expect(thread.participants.contains { $0.username == "bob" })
            #expect(list.totalUnreadThreads >= 1)
            let totals = try await a.userThreads(team: team.id, me: alice.user.id, before: nil, perPage: 1,
                                                 unreadOnly: false, totalsOnly: true)
            #expect(totals.threads.isEmpty && totals.totalUnreadThreads == list.totalUnreadThreads)

            try await a.markThreadRead(root.id, at: reply.createAt, team: team.id, me: alice.user.id)
            let afterRead = try await a.userThreads(team: team.id, me: alice.user.id, before: nil, perPage: 25,
                                                    unreadOnly: false, totalsOnly: false)
            #expect(afterRead.threads.first { $0.root.id == root.id }?.unreadReplies == 0)

            try await a.setThreadFollowing(root.id, following: false, team: team.id, me: alice.user.id)
            let afterUnfollow = try await a.userThreads(team: team.id, me: alice.user.id, before: nil, perPage: 25,
                                                        unreadOnly: false, totalsOnly: false)
            #expect(!afterUnfollow.threads.contains { $0.root.id == root.id })
            try await a.setThreadFollowing(root.id, following: true, team: team.id, me: alice.user.id)
        } catch {
            for id in created.reversed() { try? await a.deletePost(id) }
            try? await a.logout(); try? await b.logout()
            await a.shutdown(); await b.shutdown()
            throw error
        }
        for id in created.reversed() { try? await a.deletePost(id) }
        try await a.logout(); try await b.logout()
        await a.shutdown(); await b.shutdown()
    }
}
