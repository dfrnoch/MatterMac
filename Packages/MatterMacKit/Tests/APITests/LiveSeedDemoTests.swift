import Foundation
import Testing
import MatterMacModels
import MattermostAPI
import TestSupport

/// Opt-in (`MM_SEED_DEMO=1` plus the live environment): creates a "Design Demo"
/// channel on the local 11.11 test server with representative content for visual
/// review (Markdown, code, table, mentions, emoji, reactions, a thread, an image).
/// Idempotent: does nothing when the channel already has posts.
@Suite("Seed demo content", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_SEED_DEMO"] == "1"))
struct LiveSeedDemoTests {
    enum Failure: Error { case missingCredentials, missingTeam }

    @Test func seedDesignDemo() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let alicePassword = env["MM_TEST_ALICE_PASSWORD"], let bobPassword = env["MM_TEST_BOB_PASSWORD"],
              let carolPassword = env["MM_TEST_CAROL_PASSWORD"] else { throw Failure.missingCredentials }
        let endpoint = try ServerURLNormalizer.normalize("http://localhost:8065", allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let alice = try await discovery.login(LoginRequest(loginID: "alice", password: alicePassword))
        let bob = try await discovery.login(LoginRequest(loginID: "bob", password: bobPassword))
        let carol = try await discovery.login(LoginRequest(loginID: "carol", password: carolPassword))
        await discovery.shutdown()
        let a = factory.service(for: endpoint, credential: alice.credential)
        let b = factory.service(for: endpoint, credential: bob.credential)
        let c = factory.service(for: endpoint, credential: carol.credential)
        defer { Task {
            try? await a.logout(); try? await b.logout(); try? await c.logout()
            await a.shutdown(); await b.shutdown(); await c.shutdown()
        } }
        guard let team = try await a.teams().first(where: { $0.name == "qa" }) else { throw Failure.missingTeam }
        let existing = try await a.channels(team: team.id).first { $0.name == "design-demo" }
        let channel: Channel
        if let existing {
            channel = existing
            if try await a.posts(channel: channel.id, query: .latest(perPage: 5), collapsedThreads: false,
                                 priority: .interactive).posts.contains(where: { !$0.type.isSystem }) { return }
        } else {
            channel = try await a.createChannel(NewChannelRequest(team: team.id, name: "design-demo", displayName: "Design Demo",
                                                                   purpose: "Visual review of MatterMac rendering", isPrivate: false))
            try await a.addChannelMembers(channel.id, users: [bob.user.id, carol.user.id])
        }
        func post(_ api: any MattermostService, _ user: UserID, _ text: String, root: PostID? = nil, files: [FileID] = []) async throws -> Post {
            try await api.createPost(OutgoingPost(channelID: channel.id, rootID: root, message: text, fileIDs: files,
                pendingPostID: PendingPostID(rawValue: "\(user.rawValue):\(UUID().uuidString)")!))
        }
        _ = try await post(a, alice.user.id, "## Sprint review :tada:\nWelcome everyone! Agenda for today:\n1. **Release status**\n2. _Design_ updates\n3. ~~Old items~~ cleanup\n\n> Ship small, ship often.")
        let kickoff = try await post(b, bob.user.id, "Thanks @alice! The build is green. Details: https://mattermost.com/blog/ and the `release/1.4` branch is ready.")
        _ = try await b.addReaction(post: kickoff.id, emojiName: "+1", me: bob.user.id)
        _ = try await a.addReaction(post: kickoff.id, emojiName: "+1", me: alice.user.id)
        _ = try await c.addReaction(post: kickoff.id, emojiName: "rocket", me: carol.user.id)
        _ = try await post(c, carol.user.id, "Here is the config change:\n```swift\nlet budget = ResourceBudget.standard\nbudget.timeline.count = 300 // bounded\n```")
        _ = try await post(a, alice.user.id, "| Metric | Before | After |\n|:--|--:|--:|\n| Launch | 1.8 s | 0.9 s |\n| Memory | 310 MB | 120 MB |")
        let question = try await post(b, bob.user.id, "Can we freeze the release branch on Friday? :thinking:")
        _ = try await post(a, alice.user.id, "Yes — I'll prepare the notes.", root: question.id)
        _ = try await post(c, carol.user.id, "Friday works for QA too @bob", root: question.id)
        _ = try await post(b, bob.user.id, "Great, thanks both! :white_check_mark:", root: question.id)
        let png = CoreFixtures.png(width: 640, height: 400)
        let source = try UploadSource(pastedImage: png, typeIdentifier: "public.png", maximumBytes: 5_000_000, onRelease: {})
        let file = try await c.upload(source, channel: channel.id, clientID: UUID().uuidString, progress: { _ in })
        _ = try await post(c, carol.user.id, "New dashboard mockup attached.", files: [file.id])
        _ = try await post(a, alice.user.id, "Checklist:\n- [x] Changelog\n- [ ] Screenshots\n- [ ] Announce in ~town-square")
    }
}
