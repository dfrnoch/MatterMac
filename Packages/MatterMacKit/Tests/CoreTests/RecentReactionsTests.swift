import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import TestSupport

@Suite("Recent reactions")
struct RecentReactionsTests {
    @Test func mostRecentFirstBoundedValidatedAndCached() {
        var directory = DirectoryStore(budget: .standard)
        for name in ["tada", "+1", "TADA", "not valid!", "eyes"] { directory.noteReaction(name) }
        #expect(directory.recentReactions == ["eyes", "tada", "+1"])
        for n in 0..<40 { directory.noteReaction("emoji_\(n)") }
        #expect(directory.recentReactions.count == DirectoryStore.recentReactionLimit)
        #expect(directory.recentReactions.first == "emoji_39")
        var restored = DirectoryStore(budget: .standard)
        restored.restore(directory.cacheSnapshot())
        #expect(restored.recentReactions == directory.recentReactions)
    }

    @Test func addingAReactionRecordsItAndSnapshotsCarryTheList() async throws {
        let h = await SessionHarness(posts: 3)
        await h.openChannel()
        let post = try #require(await h.windowIDs().first)
        try await h.session.toggleReaction(post, emojiName: "rocket")
        #expect(await h.session.directory.recentReactions == ["rocket"])
        // Removing does not count as use.
        try await h.session.toggleReaction(post, emojiName: "rocket")
        #expect(await h.session.directory.recentReactions == ["rocket"])
        var timeline = h.session.timelineUpdates.makeAsyncIterator()
        var latest: [String] = []
        let deadline = ContinuousClock.now + .seconds(3)
        while latest != ["rocket"], ContinuousClock.now < deadline, let snapshot = await timeline.next() {
            latest = snapshot.recentReactions
        }
        #expect(latest == ["rocket"])
    }
}
