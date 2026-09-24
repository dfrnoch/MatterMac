import Foundation
import Testing
import MatterMacModels
import MattermostAPI

/// Opt-in only, against the repository-owned loopback test servers. Uses carol's
/// self-DM so concurrent tests in shared channels are not disturbed; the post is
/// deleted, the saved flag removed and the DM marked read again afterwards.
@Suite("Live pin, save, mark unread and link previews", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveInteractionTests {
    enum Failure: Error { case missingCredentials }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func interactionEndpoints(base: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_CAROL_PASSWORD"] else {
            throw Failure.missingCredentials
        }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let login: LoginResult
        do { login = try await discovery.login(LoginRequest(loginID: "carol", password: password)) } catch {
            await discovery.shutdown()
            throw error
        }
        await discovery.shutdown()
        let api = factory.service(for: endpoint, credential: login.credential)
        let me = login.user.id
        let channel = try await api.createDirectChannel(with: me, me: me)
        var created: Post?
        do {
            let post = try await api.createPost(OutgoingPost(
                channelID: channel.id, rootID: nil, message: "MatterMac interaction check https://mattermost.com",
                fileIDs: [], pendingPostID: PendingPostID(user: me, milliseconds: Int64(Date().timeIntervalSince1970 * 1_000))))
            created = post
            try await exercise(api, me: me, channel: channel, post: post)
        } catch {
            if let created { try? await api.deletePost(created.id) }
            try? await api.deletePreferences([Preference(category: "flagged_post", name: created?.id.rawValue ?? "", value: "true")],
                                             me: me)
            _ = try? await api.viewChannel(channel.id, previous: nil, collapsedThreadsSupported: true)
            try? await api.logout()
            await api.shutdown()
            throw error
        }
        if let created { try await api.deletePost(created.id) }
        try await api.logout()
        await api.shutdown()
    }

    private func exercise(_ api: any MattermostService, me: UserID, channel: Channel, post: Post) async throws {
        // Pin and unpin (`post_edited` also carries `is_pinned`).
        try await api.setPinned(post.id, pinned: true)
        #expect(try await api.post(post.id).isPinned)
        try await api.setPinned(post.id, pinned: true) // A no-op pin is accepted.
        try await api.setPinned(post.id, pinned: false)
        #expect(!(try await api.post(post.id).isPinned))

        // Save and unsave through `flagged_post` preferences.
        let flag = Preference(category: "flagged_post", name: post.id.rawValue, value: "true")
        try await api.savePreferences([flag], me: me)
        #expect(try await api.preferences().contains(flag))
        try await api.deletePreferences([flag], me: me)
        #expect(!(try await api.preferences().contains(flag)))

        // Mark unread from the post, then read again.
        _ = try await api.viewChannel(channel.id, previous: nil, collapsedThreadsSupported: true)
        let state = try await api.markUnread(from: post.id, me: me)
        #expect(state.channelID == channel.id)
        #expect(state.lastViewedAt < post.createAt)
        let member = try await api.channelMembership(channel.id)
        #expect(member.lastViewedAt == state.lastViewedAt)
        #expect(member.messageCount == state.messageCount)
        let current = try await api.channel(channel.id)
        #expect(current.totalMessageCount - state.messageCount >= 1, "at least the marked post is unread")
        let times = try await api.viewChannel(channel.id, previous: nil, collapsedThreadsSupported: true)
        #expect((times[channel.id] ?? .zero) >= post.createAt)

        // Link previews are server metadata; decoding must succeed whether or not this
        // server could reach the site. Nothing is fetched from the site by MatterMac.
        let fetched = try await api.post(post.id)
        if let preview = fetched.linkPreview {
            #expect(preview.link.url.host() == "mattermost.com")
            #expect(preview.kind == .website && !preview.title.isEmpty)
            #expect(preview.title.utf8.count <= LinkPreview.maximumTitleBytes + 3)
        }
        let config = try await api.fullConfiguration()
        #expect(config.capabilities.hasImageProxy != nil, "HasImageProxy is reported")
        if config.capabilities.hasImageProxy == false {
            // Without a proxy the server redirects to the third-party URL; the redirect
            // is refused, so no image request leaves the server's origin.
            await #expect(throws: APIError.self) {
                _ = try await api.imageData(.proxiedImage(url: "https://mattermost.com/favicon.ico"), maximumBytes: 1 << 20)
            }
        }
    }
}
