import Testing
@testable import MatterMacCore
import MatterMacModels
import TestSupport

@Suite("PostStore merge rules")
struct PostStoreTests {
    let channel = ChannelID(unchecked: CoreFixtures.id("ch", 1))

    func makeStore() -> PostStore {
        PostStore { post in MessageDocument(blocks: [.paragraph([.text(post.message)])]) }
    }

    @Test func olderSnapshotNeverReplacesNewerEdit() {
        var store = makeStore()
        var post = CoreFixtures.post(1, channel: channel, message: "original")
        store.upsert(post)
        post.message = "edited"
        post.updateAt = MattermostTimestamp(milliseconds: post.createAt.milliseconds + 500)
        post.editAt = post.updateAt
        let updated = store.upsert(post)
        #expect(updated == .updated)
        let stale = CoreFixtures.post(1, channel: channel, message: "original")
        let staleResult = store.upsert(stale)
        #expect(staleResult == .ignoredStale)
        #expect(store.post(post.id)?.message == "edited")
        #expect(store.entry(post.id)?.document.plainText == "edited")
    }

    @Test func deletionIsSticky() {
        var store = makeStore()
        let post = CoreFixtures.post(1, channel: channel)
        store.upsert(post)
        let deleted = store.markDeleted(post.id, at: MattermostTimestamp(milliseconds: 5))
        #expect(deleted)
        var resurrect = post
        resurrect.updateAt = MattermostTimestamp(milliseconds: post.updateAt.milliseconds + 10_000)
        let resurrected = store.upsert(resurrect)
        #expect(resurrected == .unchanged)
        #expect(store.post(post.id)?.isDeleted == true)
        #expect(store.post(post.id)?.message == "")
    }

    @Test func equalRevisionKeepsLocallyAppliedReaction() {
        var store = makeStore()
        let post = CoreFixtures.post(1, channel: channel)
        store.upsert(post)
        let reaction = Reaction(userID: CoreFixtures.me.id, postID: post.id, emojiName: "+1")
        store.applyReaction(reaction, added: true)
        // A snapshot taken before the reaction (same update_at) arrives late.
        store.upsert(post)
        #expect(store.post(post.id)?.reactions == [reaction])
        // Removing twice is idempotent.
        store.applyReaction(reaction, added: false)
        store.applyReaction(reaction, added: false)
        #expect(store.post(post.id)?.reactions.isEmpty == true)
    }

    @Test func pendingPostIDIsPreservedWhenFetchedCopyLacksIt() {
        var store = makeStore()
        var post = CoreFixtures.post(1, channel: channel)
        post.pendingPostID = PendingPostID(user: CoreFixtures.me.id, milliseconds: 1)
        store.upsert(post)
        var fetched = post
        fetched.pendingPostID = nil
        fetched.updateAt = MattermostTimestamp(milliseconds: post.updateAt.milliseconds + 1)
        store.upsert(fetched)
        #expect(store.post(post.id)?.pendingPostID == post.pendingPostID)
    }

    @Test func usageTracksCostsAndUnreferencedEntriesAreCollected() {
        var store = makeStore()
        for n in 0..<50 { store.upsert(CoreFixtures.post(n, channel: channel, message: String(repeating: "x", count: n))) }
        let expected = (0..<50).compactMap { store.entry(PostID(unchecked: CoreFixtures.id("post", $0)))?.cost }.reduce(0, +)
        #expect(store.usage.bytes == expected)
        #expect(store.usage.count == 50)
        store.retain(PostID(unchecked: CoreFixtures.id("post", 3)))
        let collected = store.collectUnreferenced()
        #expect(collected == 49)
        #expect(store.count == 1)
        #expect(store.usage.count == 1)
        #expect(store.usage.bytes == store.entry(PostID(unchecked: CoreFixtures.id("post", 3)))?.cost)
    }

    @Test func purgeRemovesChannelContentRegardlessOfReferences() {
        var store = makeStore()
        let other = ChannelID(unchecked: CoreFixtures.id("ch", 2))
        store.upsert(CoreFixtures.post(1, channel: channel))
        store.upsert(CoreFixtures.post(2, channel: other))
        store.retain(PostID(unchecked: CoreFixtures.id("post", 1)))
        let purged = store.purge(channel: channel)
        #expect(purged.count == 1)
        #expect(store.count == 1)
        #expect(store.post(PostID(unchecked: CoreFixtures.id("post", 1))) == nil)
    }
}

@Suite("HistoryWindow")
struct HistoryWindowTests {
    func entry(_ n: Int, _ time: Int64) -> HistoryWindow.Entry {
        HistoryWindow.Entry(id: PostID(unchecked: CoreFixtures.id("post", n)), createAt: MattermostTimestamp(milliseconds: time))
    }

    @Test func replaceSortsAndDeduplicates() {
        var window = HistoryWindow(target: .channel(ChannelID(unchecked: "c")))
        let delta = window.replace(with: [entry(3, 30), entry(1, 10), entry(2, 20), entry(1, 10)], hasOlder: true, hasNewer: false)
        #expect(window.ids.map(\.rawValue) == [1, 2, 3].map { CoreFixtures.id("post", $0) })
        #expect(delta.added.count == 3)
        #expect(window.isLoaded)
    }

    @Test func liveInsertOnlyAtLiveEdge() {
        var window = HistoryWindow(target: .channel(ChannelID(unchecked: "c")))
        _ = window.replace(with: [entry(1, 10)], hasOlder: false, hasNewer: true)
        let whileBehind = window.insertLive(entry(2, 20))
        #expect(!whileBehind)
        window.hasNewer = false
        let atEdge = window.insertLive(entry(2, 20))
        #expect(atEdge)
        let duplicate = window.insertLive(entry(2, 20))
        #expect(!duplicate)
        // Out-of-order arrival lands in order.
        let outOfOrder = window.insertLive(entry(3, 15))
        #expect(outOfOrder)
        #expect(window.ids.last == PostID(unchecked: CoreFixtures.id("post", 2)))
    }

    @Test func trimRemovesFarSideAndRecordsGap() {
        var window = HistoryWindow(target: .channel(ChannelID(unchecked: "c")))
        _ = window.replace(with: (0..<100).map { entry($0, Int64($0)) }, hasOlder: false, hasNewer: false)
        // Anchor near the bottom: trim the older side.
        let removed = window.trim(toCount: 40, keepingAround: PostID(unchecked: CoreFixtures.id("post", 95)))
        #expect(removed.count == 60)
        #expect(window.count == 40)
        #expect(window.hasOlder)
        #expect(!window.hasNewer)
        #expect(window.oldest?.id == PostID(unchecked: CoreFixtures.id("post", 60)))
        // Anchor near the top: trim the newer side.
        let removedNewer = window.trim(toCount: 10, keepingAround: PostID(unchecked: CoreFixtures.id("post", 61)))
        #expect(removedNewer.count == 30)
        #expect(window.hasNewer)
        #expect(window.contains(PostID(unchecked: CoreFixtures.id("post", 61))))
    }
}

@Suite("EventJournal")
struct EventJournalTests {
    @Test func returnsRecordsAfterPositionAndDetectsWrap() {
        var journal = EventJournal(capacity: 4)
        let reaction = { (n: Int) in
            EventJournal.Record.reaction(Reaction(userID: UserID(unchecked: "u"), postID: PostID(unchecked: "p\(n)"), emojiName: "x"), added: true)
        }
        let start = journal.position
        journal.append(reaction(1))
        journal.append(reaction(2))
        #expect(journal.records(after: start)?.count == 2)
        #expect(journal.records(after: journal.position)?.isEmpty == true)
        for n in 3...8 { journal.append(reaction(n)) }
        // Positions 1...4 were overwritten: the journal cannot vouch for a request that
        // started at position 0.
        #expect(journal.records(after: start) == nil)
        #expect(journal.records(after: 4)?.map(\.postID.rawValue) == ["p5", "p6", "p7", "p8"])
    }
}
