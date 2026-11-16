import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("Plain read and send (assistant day summary, agent control)", .serialized)
struct PlainSessionTests {
    @Test func channelsResolveByIDNameAndUsername() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let channels = await h.session.plainChannels()
        let listed = try #require(channels.first { $0.id == h.channel.id })
        #expect(listed.kind == "public" && listed.name == h.channel.name)
        #expect(try await h.session.resolvePlainChannel(h.channel.id.rawValue) == h.channel.id)
        #expect(try await h.session.resolvePlainChannel("#" + h.channel.name) == h.channel.id)
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.resolvePlainChannel("no-such-channel")
        }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func readingReturnsOldestFirstWithNamesAndOpensNoWindow() async throws {
        let h = await SessionHarness(posts: 5)
        // No channel is opened: reading must not create a window or mark anything read.
        _ = await eventually { await !h.session.plainChannels().isEmpty }
        let posts = try await h.session.plainPosts(channel: h.channel.id, limit: 3)
        #expect(posts.count == 3)
        #expect(posts.map(\.createdAt) == posts.map(\.createdAt).sorted())
        #expect(posts.allSatisfy { $0.username == "bob" })
        #expect(await h.session.windows.isEmpty)
        #expect(!h.service.calls.contains("viewChannel"))
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.plainPosts(channel: CoreFixtures.channel(9).id, limit: 3)
        }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func sendingGoesThroughTheQueueAndReportsTheConfirmedPost() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let result = await h.session.sendPlain(text: "from an agent", channel: h.channel.id, rootID: nil)
        guard case .sent(let id) = result else {
            Issue.record("expected a confirmed send, got \(result)")
            return
        }
        #expect(h.service.withState { $0.createdPosts.map(\.message) } == ["from an agent"])
        #expect(h.service.withState { $0.posts[id]?.message } == "from an agent")
        #expect(h.unsent.usage.pendingOperations == 0, "the reservation is released on confirmation")
        #expect(await h.session.sendPlain(text: "  ", channel: h.channel.id, rootID: nil) == .rejected(.empty))
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func ownRecentMessagesAreTheUsersNewestFirstAcrossPages() async throws {
        let channel = CoreFixtures.channel(1)
        let mine = (0..<150).map { CoreFixtures.post(100 + $0, channel: channel.id, user: CoreFixtures.me.id, message: "mine \($0)") }
        let theirs = CoreFixtures.post(900, channel: channel.id, message: "from bob")
        let h = await SessionHarness { state in
            state.searchPostsHandler = { query in
                #expect(query.terms == "from:" + CoreFixtures.me.username && query.perPage == 100)
                let all = Array(mine.reversed()) + [theirs]
                return PostPage(posts: Array(all.dropFirst(query.page * 100).prefix(100)))
            }
        }
        await h.openChannel()
        let messages = try await h.session.ownRecentMessages(limit: 120)
        #expect(messages.count == 120 && messages.first == "mine 149" && !messages.contains("from bob"))
        #expect(h.service.calls.filter { $0 == "searchPosts" }.count == 2, "two pages of 100")
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func todayKeepsOnlyTodaysMessagesFromActiveConversations() async throws {
        let now: Int64 = 1_700_000_500_000 // `FixedWallClock`'s default
        let channel = CoreFixtures.channel(1)
        let today = CoreFixtures.post(50, channel: channel.id, message: "shipping today", createAt: now - 60_000)
        let old = CoreFixtures.post(51, channel: channel.id, message: "last week", createAt: now - 8 * 86_400_000)
        let h = await SessionHarness(posts: 0) { state in
            state.posts[today.id] = today
            state.posts[old.id] = old
            state.channels[channel.id]?.lastPostAt = today.createAt
        }
        await h.openChannel()
        let conversations = try await h.session.todayConversations(maximumChannels: 5, perChannel: 60)
        #expect(conversations.count == 1)
        #expect(conversations.first?.messages.map(\.text) == ["shipping today"])
        #expect(conversations.first?.title == "#Channel 1")
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
