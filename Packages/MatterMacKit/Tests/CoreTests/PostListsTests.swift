import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("Mentions, saved and pinned lists", .serialized)
struct PostListsTests {
    private func snapshot(_ h: SessionHarness, _ iterator: inout AsyncStream<SearchSnapshot>.Iterator,
                          until kind: SearchKind) async -> SearchSnapshot? {
        while let next = await iterator.next() {
            if next.kind == kind, next.state == .results { return next }
            if case .failed = next.state { return next }
        }
        return nil
    }

    @Test func listsShareBoundedSearchStorage() async throws {
        let h = await SessionHarness(posts: 6) { state in
            let channel = CoreFixtures.channel(1).id
            let mention = CoreFixtures.post(40, channel: channel, message: "hey @alice look")
            var pinned = CoreFixtures.post(41, channel: channel, message: "pinned note")
            pinned.isPinned = true
            state.posts[mention.id] = mention
            state.posts[pinned.id] = pinned
            state.flagged = [CoreFixtures.post(2, channel: channel).id, pinned.id]
        }
        _ = await eventually {
            let loaded = await h.session.directory.channels[h.channel.id] != nil
            let team = await h.session.selectedTeam
            return loaded && team != nil
        }
        var updates = h.session.searchUpdates.makeAsyncIterator()

        await h.session.showRecentMentions()
        let mentions = try #require(await snapshot(h, &updates, until: .recentMentions))
        #expect(mentions.items.map(\.preview) == ["hey @alice look"])
        #expect(mentions.items.first?.authorID == CoreFixtures.bob.id)

        await h.session.showSavedPosts()
        let saved = try #require(await snapshot(h, &updates, until: .saved))
        #expect(saved.items.count == 2)

        await h.session.showPinnedPosts(channel: h.channel.id)
        let pins = try #require(await snapshot(h, &updates, until: .pinned(h.channel.id)))
        #expect(pins.items.map(\.preview) == ["pinned note"])
        #expect(!pins.canLoadMore)

        // A normal search resets the kind; clearing releases retained results.
        await h.session.search("message")
        let search = try #require(await snapshot(h, &updates, until: .terms))
        #expect(!search.items.isEmpty)
        await h.session.clearSearch()
        #expect(await h.session.searchState.results.isEmpty)
        #expect(await h.session.searchKind == .terms)
    }
}
