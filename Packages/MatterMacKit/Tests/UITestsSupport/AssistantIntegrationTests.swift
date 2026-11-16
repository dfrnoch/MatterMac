import AppKit
import Testing
import MatterMacModels
@testable import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Composer reply suggestion")
struct ComposerSuggestionTests {
    @Test func tabInsertsTheSuggestionAsTheUsersTextAndGrowsTheComposer() {
        let h = ComposerHarness()
        defer { h.close() }
        let single = h.controller.preferredHeight
        h.controller.suggestion = String(repeating: "A long suggested reply that wraps. ", count: 6)
        #expect(h.controller.isSuggestionVisible)
        #expect(h.controller.preferredHeight > single, "room for the ghost text")
        #expect(h.text.isEmpty && h.controller.currentDraft().text.isEmpty, "a suggestion is not a draft")
        #expect(!h.controller.canSend)
        h.command(#selector(NSResponder.insertTab(_:)))
        #expect(h.text.hasPrefix("A long suggested reply"))
        #expect(h.controller.suggestion == nil && !h.controller.isSuggestionVisible)
        #expect(h.controller.canSend)
        h.undoManager.undo()
        #expect(h.text.isEmpty, "accepting is one undoable edit")
    }

    @Test func typingHidesItEscapeRemovesItAndEditingNeverShowsIt() {
        let h = ComposerHarness()
        defer { h.close() }
        h.controller.suggestion = "Sounds good."
        h.type("n")
        #expect(!h.controller.isSuggestionVisible && h.text == "n")
        // Tab is an ordinary key again once the user is typing.
        h.command(#selector(NSResponder.insertTab(_:)))
        #expect(!h.text.contains("Sounds good."))
        h.controller.clear()
        #expect(h.controller.isSuggestionVisible, "back in an empty composer it is offered again")
        h.controller.mode = .edit(postID: CoreFixtures.post(1, channel: CoreFixtures.channel(1).id).id, original: "")
        #expect(!h.controller.isSuggestionVisible)
        h.controller.mode = .compose
        h.textView.cancelOperation(nil)
        #expect(h.controller.suggestion == nil)
        #expect(h.spy.escapes == 0, "Escape removed the suggestion and did nothing else")
    }

    @Test func aSuggestionOverTheDraftBudgetIsNotInserted() {
        let h = ComposerHarness()
        defer { h.close() }
        h.spy.draftBudgetBytes = 4
        h.controller.suggestion = "Longer than four bytes"
        h.command(#selector(NSResponder.insertTab(_:)))
        #expect(h.text.isEmpty)
    }
}

@MainActor
@Suite("Assistant and agent control in a signed-in app", .serialized)
struct AssistantIntegrationTests {
    @MainActor final class Harness {
        let channel = CoreFixtures.channel(1)
        let service: FakeMattermostService
        let realtime = FakeRealtimeConnection()
        let app: AppModel
        let model: SessionViewModel
        var environment: AppEnvironment { app.environment }

        init(posts: [Post]) async throws {
            let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
            let channel = channel
            service.withState { state in
                state.teams = [CoreFixtures.team]
                state.channels[channel.id] = channel
                state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: CoreFixtures.me.id)
                state.users[CoreFixtures.bob.id] = CoreFixtures.bob
                for post in posts { state.posts[post.id] = post }
            }
            self.service = service
            let realtime = realtime
            app = AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
                makeRealtime: { _, _, _ in realtime }, markupParse: { text, _ in MarkupParser.parse(text) }))
            app.environment.appModel = app
            app.environment.settings.notificationsEnabled = false
            try await app.completeLogin(
                LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
                discovery: DiscoveryResult(endpoint: CoreFixtures.endpoint, version: nil, capabilities: ServerCapabilities()),
                remember: false)
            model = try #require(app.activeSession)
            let channelID = channel.id
            #expect(await waitUntil { self.model.sidebar?.sections.contains { $0.rows.contains { $0.channelID == channelID } } == true })
            model.select(channel: channel.id)
            // The first snapshot is the loading row; wait for the posts themselves.
            #expect(await waitUntil {
                self.model.header?.channelID == channelID
                    && (self.model.timeline?.items.compactMap(\.post).count ?? 0) >= posts.count
            })
        }

        func close() async {
            model.prepareForSignOut()
            app.environment.drafts.discardAll(for: model.scope)
            await app.registry.removeAll()
        }

        func agent(_ command: String, _ arguments: [String] = [], _ options: [String: String] = [:]) async throws -> [String: Any] {
            let request = try JSONSerialization.data(withJSONObject: ["version": 1, "command": command,
                                                                      "arguments": arguments, "options": options])
            let response = await environment.agent.handle(request)
            return try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        }
    }

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }

    static func recent(_ n: Int, _ message: String, user: UserID = CoreFixtures.bob.id) -> Post {
        CoreFixtures.post(n, channel: CoreFixtures.channel(1).id, user: user, message: message,
                          createAt: Int64(Date().timeIntervalSince1970 * 1_000) - Int64(600 - n) * 1_000)
    }

    @Test func aReplyIsSuggestedForSomeoneElsesNewestMessageAndNotAfterMyOwn() async throws {
        let h = try await Harness(posts: [Self.recent(0, "jo jasny", user: CoreFixtures.me.id),
                                          Self.recent(1, "Are we still on for lunch at noon?")])
        let provider = FakeAssistantProvider { _, _ in .success("Yes, see you at noon.") }
        h.environment.assistantOverride = provider
        h.environment.isAppActiveOverride = true
        let controller = ConversationController(session: h.model, target: .channel(h.channel.id))
        // Suggestions are off until the user turns them on, whatever provider is chosen.
        controller.update(target: .channel(h.channel.id), snapshot: h.model.timeline)
        #expect(controller.suggestionKey == nil)
        h.environment.settings.assistantSuggestsReplies = true
        controller.refreshSuggestion()
        #expect(await waitUntil(seconds: 5) { controller.composer.suggestion == "Yes, see you at noon." })
        let request = try #require(provider.requests.first)
        #expect(request.input.contains("bob: Are we still on for lunch at noon?"))
        #expect(request.input.contains("Conversation: #Channel 1"))
        // My own earlier message in this conversation is the style reference.
        #expect(request.input.hasPrefix("Messages ") && request.input.contains("wrote recently")
            && request.input.contains("- jo jasny"))
        // Applying the same snapshot again asks nothing new.
        controller.update(target: .channel(h.channel.id), snapshot: h.model.timeline)
        try await Task.sleep(for: .milliseconds(100))
        #expect(provider.requests.count == 1)
        // Dismissed with Escape: not offered again for that message.
        controller.composer.textView.cancelOperation(nil)
        controller.update(target: .channel(h.channel.id), snapshot: h.model.timeline)
        #expect(controller.composer.suggestion == nil)
        // Turning suggestions off removes any pending one and asks nothing.
        h.environment.settings.assistantSuggestsReplies = false
        controller.refreshSuggestion()
        #expect(controller.composer.suggestion == nil && provider.requests.count == 1)
        controller.suggestionTask?.cancel()
        await h.close()
    }

    @Test func nothingIsAskedWhenTheAssistantIsOffOrTheNewestMessageIsMine() async throws {
        let h = try await Harness(posts: [Self.recent(1, "ping"), Self.recent(2, "pong", user: CoreFixtures.me.id)])
        let provider = FakeAssistantProvider()
        h.environment.isAppActiveOverride = true
        let controller = ConversationController(session: h.model, target: .channel(h.channel.id))
        controller.update(target: .channel(h.channel.id), snapshot: h.model.timeline)
        #expect(controller.suggestionKey == nil, "assistant off")
        h.environment.assistantOverride = provider
        h.environment.settings.assistantSuggestsReplies = true
        controller.refreshSuggestion()
        #expect(controller.suggestionKey == nil, "I spoke last")
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.requests.isEmpty)
        await h.close()
    }

    @Test func learningMyWritingStoresNotesThatTheNextSuggestionCarries() async throws {
        let h = try await Harness(posts: [Self.recent(1, "stihnes dneska to review?")])
        let mine = (0..<40).map { CoreFixtures.post(200 + $0, channel: h.channel.id, user: CoreFixtures.me.id, message: "jj mrknu \($0)") }
        h.service.withState { $0.searchPostsHandler = { query in PostPage(posts: query.page == 0 ? mine : []) } }
        let provider = FakeAssistantProvider { request, _ in
            request.task == .style ? .success("Writes short lowercase Czech.") : .success("jj mrknu")
        }
        h.environment.assistantOverride = provider
        h.environment.isAppActiveOverride = true
        h.environment.settings.assistantSuggestsReplies = true
        #expect(h.model.styleProfile == nil)
        h.model.learnStyle()
        #expect(h.model.isLearningStyle)
        #expect(await waitUntil { !h.model.isLearningStyle })
        let profile = try #require(h.model.styleProfile)
        #expect(profile.text == "Writes short lowercase Czech." && profile.messageCount == 40)
        let learning = try #require(provider.requests.first)
        #expect(learning.task == .style && learning.input.contains("- jj mrknu 39"))

        let controller = ConversationController(session: h.model, target: .channel(h.channel.id))
        controller.update(target: .channel(h.channel.id), snapshot: h.model.timeline)
        #expect(await waitUntil(seconds: 5) { controller.composer.suggestion == "jj mrknu" })
        let reply = try #require(provider.requests.last)
        #expect(reply.task == .reply && reply.input.contains("Writes short lowercase Czech."))
        // Forgetting removes the notes; the next request goes without them.
        h.model.forgetStyle()
        #expect(h.model.styleProfile == nil)
        controller.suggestionTask?.cancel()
        await h.close()
    }

    @Test func learningNeedsEnoughMessagesAndAProvider() async throws {
        let h = try await Harness(posts: [])
        h.model.learnStyle()
        #expect(!h.model.isLearningStyle && h.model.styleLearningError == "Choose who answers in Settings › Assistant first.")
        let provider = FakeAssistantProvider()
        h.environment.assistantOverride = provider
        h.service.withState { $0.searchPostsHandler = { _ in PostPage(posts: []) } }
        h.model.learnStyle()
        #expect(await waitUntil { !h.model.isLearningStyle })
        #expect(h.model.styleProfile == nil && h.model.styleLearningError?.contains("too few") == true)
        #expect(provider.requests.isEmpty)
        await h.close()
    }

    @Test func agentCommandsReadSearchAndSendThroughTheApp() async throws {
        let h = try await Harness(posts: [Self.recent(1, "first"), Self.recent(2, "second")])
        // Off by default: every command is refused.
        #expect(try await h.agent("channels")["ok"] as? Bool == false)
        h.environment.settings.agentControlEnabled = true
        defer { h.environment.settings.agentControlEnabled = false }

        let status = try await h.agent("status")
        #expect(status["ok"] as? Bool == true)
        #expect((status["accounts"] as? [[String: Any]])?.first?["user"] as? String == CoreFixtures.me.username)

        let channels = try #require(try await h.agent("channels")["channels"] as? [[String: Any]])
        #expect(channels.contains { $0["name"] as? String == h.channel.name && $0["type"] as? String == "public" })

        let read = try await h.agent("read", [h.channel.name], ["limit": "1"])
        let posts = try #require(read["posts"] as? [[String: Any]])
        #expect(posts.count == 1 && posts[0]["text"] as? String == "second" && posts[0]["user"] as? String == "bob")
        #expect(posts[0]["time"] is String)

        let sent = try await h.agent("send", [h.channel.name, "sent by an agent"])
        #expect(sent["ok"] as? Bool == true && sent["state"] as? String == "sent")
        #expect(h.service.withState { $0.createdPosts.map(\.message) } == ["sent by an agent"])
        let postID = try #require(sent["post_id"] as? String)

        // A reply names any post of the thread; the root is resolved by the app.
        let reply = try await h.agent("send", [h.channel.name, "a reply"], ["reply-to": postID])
        #expect(reply["state"] as? String == "sent")
        #expect(h.service.withState { $0.createdPosts.last?.rootID?.rawValue } == postID)

        #expect(try await h.agent("send", [h.channel.name, "   "])["ok"] as? Bool == false)
        #expect(try await h.agent("read", ["no-such-channel"])["ok"] as? Bool == false)
        #expect(try await h.agent("frobnicate")["ok"] as? Bool == false)
        await h.close()
    }

    @Test func threadSummaryUsesTheWholeThreadAndTheChosenProvider() async throws {
        let root = Self.recent(1, "Should we ship on Friday?")
        var reply = Self.recent(2, "Yes, after the smoke test.", user: CoreFixtures.me.id)
        reply.rootID = root.id
        let h = try await Harness(posts: [root, reply])
        #expect(await h.model.summarizeThread(root: root.id) == .failure(AssistantFailure(
            message: "Choose who answers in Settings › Assistant first.")))
        let provider = FakeAssistantProvider { _, _ in .success("Shipping Friday after the smoke test.") }
        h.environment.assistantOverride = provider
        let summary = try await h.model.summarizeThread(root: root.id).get()
        #expect(summary.text == "Shipping Friday after the smoke test." && summary.coveredMessages == 2)
        let request = try #require(provider.requests.first)
        #expect(request.task == .summary && request.input.contains("Thread in #Channel 1"))
        #expect(request.input.contains("(me): Yes, after the smoke test."))
        await h.close()
    }
}

@MainActor
private func waitUntil(seconds: Int = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    return condition()
}
