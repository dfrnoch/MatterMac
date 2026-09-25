import Foundation
import CoreGraphics
import ImageIO
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
            let recent = try await a.posts(channel: channel.id, query: .latest(perPage: 30), collapsedThreads: false,
                                           priority: .interactive).posts
            if recent.contains(where: { !$0.type.isSystem }) {
                // Earlier seeds attached a flat placeholder; replace it with the drawn mockup once.
                if !recent.contains(where: { $0.message.hasPrefix(Self.mockupMessage) }) {
                    for old in recent where old.message == "New dashboard mockup attached." && old.userID == carol.user.id {
                        try await c.deletePost(old.id)
                    }
                    try await postMockup(c, channel: channel.id, user: carol.user.id)
                }
                return
            }
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
        try await postMockup(c, channel: channel.id, user: carol.user.id)
        _ = try await post(a, alice.user.id, "Checklist:\n- [x] Changelog\n- [ ] Screenshots\n- [ ] Announce in ~town-square")
    }

    static let mockupMessage = "Dashboard mockup v2"

    private func postMockup(_ api: any MattermostService, channel: ChannelID, user: UserID) async throws {
        let source = try UploadSource(pastedImage: Self.dashboardPNG(), typeIdentifier: "public.png",
                                      maximumBytes: 5_000_000, onRelease: {})
        let file = try await api.upload(source, channel: channel, clientID: UUID().uuidString, progress: { _ in })
        _ = try await api.createPost(OutgoingPost(channelID: channel, rootID: nil,
            message: Self.mockupMessage + ": stat cards, weekly trend and release burndown.", fileIDs: [file.id],
            pendingPostID: PendingPostID(rawValue: "\(user.rawValue):\(UUID().uuidString)")!))
    }

    /// A drawn, synthetic dashboard (no real data): header, stat cards, a line chart
    /// and bars on a soft gradient.
    static func dashboardPNG(width: Int = 1_600, height: Int = 1_000) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
        let w = CGFloat(width), h = CGFloat(height)
        let gradient = CGGradient(colorsSpace: space, colors: [color(0.96, 0.95, 1.0), color(0.88, 0.91, 1.0)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        func card(_ rect: CGRect, _ fill: CGColor = color(1, 1, 1)) {
            context.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: color(0.2, 0.25, 0.5, 0.12))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil))
            context.setFillColor(fill)
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        func bar(_ rect: CGRect, _ fill: CGColor) {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) / 2,
                                   cornerHeight: min(rect.width, rect.height) / 2, transform: nil))
            context.setFillColor(fill)
            context.fillPath()
        }
        // Header.
        bar(CGRect(x: 80, y: h - 120, width: 360, height: 36), color(0.2, 0.22, 0.35))
        bar(CGRect(x: 80, y: h - 165, width: 220, height: 20), color(0.55, 0.58, 0.7))
        bar(CGRect(x: w - 300, y: h - 130, width: 220, height: 56), color(0.36, 0.42, 0.95))
        // Stat cards.
        let accents = [color(0.36, 0.42, 0.95), color(0.2, 0.72, 0.55), color(0.96, 0.55, 0.3), color(0.85, 0.35, 0.6)]
        for (index, accent) in accents.enumerated() {
            let x = 80 + CGFloat(index) * 370
            card(CGRect(x: x, y: h - 400, width: 330, height: 180))
            bar(CGRect(x: x + 36, y: h - 280, width: 120, height: 18), color(0.6, 0.62, 0.72))
            bar(CGRect(x: x + 36, y: h - 350, width: 200, height: 44), color(0.18, 0.2, 0.3))
            context.setFillColor(accent)
            context.fillEllipse(in: CGRect(x: x + 250, y: h - 300, width: 44, height: 44))
        }
        // Line chart.
        card(CGRect(x: 80, y: 80, width: 920, height: 460))
        let points: [CGFloat] = [0.35, 0.42, 0.38, 0.55, 0.5, 0.66, 0.62, 0.78, 0.74, 0.86]
        let path = CGMutablePath()
        for (index, value) in points.enumerated() {
            let point = CGPoint(x: 140 + CGFloat(index) * 90, y: 130 + value * 340)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let fill = path.mutableCopy()!
        fill.addLine(to: CGPoint(x: 140 + 9 * 90, y: 130))
        fill.addLine(to: CGPoint(x: 140, y: 130))
        fill.closeSubpath()
        context.addPath(fill)
        context.setFillColor(color(0.36, 0.42, 0.95, 0.15))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(color(0.36, 0.42, 0.95))
        context.setLineWidth(8)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.strokePath()
        // Bars.
        card(CGRect(x: 1_040, y: 80, width: 480, height: 460))
        for (index, value) in [0.9, 0.72, 0.58, 0.41, 0.3, 0.16].enumerated() {
            let x = 1_090 + CGFloat(index) * 68
            bar(CGRect(x: x, y: 130, width: 40, height: 330 * CGFloat(value)), accents[index % accents.count])
        }
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
