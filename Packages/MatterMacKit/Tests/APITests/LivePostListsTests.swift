import Foundation
import Testing
import MatterMacModels
import MattermostAPI

/// Opt-in: saved (flagged) and pinned lists and the recent-mentions search.
@Suite("Live post lists", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LivePostListsTests {
    enum Failure: Error { case missingCredentials, missingChannel }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8067"])
    func savedPinnedAndMentions(base: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_ALICE_PASSWORD"] else { throw Failure.missingCredentials }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let login = try await discovery.login(LoginRequest(loginID: "alice", password: password))
        await discovery.shutdown()
        let api = factory.service(for: endpoint, credential: login.credential)
        let me = login.user.id
        var created: PostID?
        do {
            guard let team = try await api.teams().first(where: { $0.name == "qa" }),
                  let channel = try await api.channels(team: team.id).first(where: { $0.name == "interop" })
            else { throw Failure.missingChannel }
            let post = try await api.createPost(OutgoingPost(channelID: channel.id, rootID: nil,
                message: "MatterMac saved check @alice", fileIDs: [],
                pendingPostID: PendingPostID(rawValue: "\(me.rawValue):\(UUID().uuidString)")!))
            created = post.id
            let flag = Preference(category: "flagged_post", name: post.id.rawValue, value: "true")
            try await api.savePreferences([flag], me: me)
            #expect(try await api.flaggedPosts(me: me, page: 0, perPage: 20).posts.contains { $0.id == post.id })
            try await api.deletePreferences([flag], me: me)
            #expect(!(try await api.flaggedPosts(me: me, page: 0, perPage: 20).posts.contains { $0.id == post.id }))
            _ = try await api.pinnedPosts(channel: channel.id)
            let mentions = try await api.searchPosts(SearchQuery(team: team.id, terms: "@alice", isOrSearch: true,
                                                                 timeZoneOffsetSeconds: 0))
            _ = mentions
        } catch {
            if let created { try? await api.deletePost(created) }
            try? await api.logout(); await api.shutdown()
            throw error
        }
        if let created { try await api.deletePost(created) }
        try await api.logout(); await api.shutdown()
    }
}
