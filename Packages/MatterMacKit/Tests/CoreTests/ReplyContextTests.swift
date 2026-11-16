import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("Reply root cache")
struct ReplyRootCacheTests {
    let channel = CoreFixtures.channel(1)

    @Test func previewIsOneBoundedLine() {
        #expect(ReplyRootCache.preview("  first\n\nsecond\tthird  ") == "first second third")
        let long = ReplyRootCache.preview(String(repeating: "a", count: 500))
        #expect(long.count == ReplyRootCache.previewCharacters)
    }

    @Test func olderCopiesNeverReplaceNewerAndDeletionSticks() throws {
        var cache = ReplyRootCache(capacity: 10)
        var root = CoreFixtures.post(1, channel: channel.id, message: "new")
        root.updateAt = MattermostTimestamp(milliseconds: 20)
        cache.record(root, plainText: "new")
        var stale = root
        stale.updateAt = MattermostTimestamp(milliseconds: 10)
        cache.record(stale, plainText: "old")
        #expect(cache.peek(root.id)?.preview == "new")
        cache.markDeleted(root.id)
        root.updateAt = MattermostTimestamp(milliseconds: 30)
        cache.record(root, plainText: "back")
        let summary = try #require(cache.peek(root.id))
        #expect(summary.isDeleted && summary.preview.isEmpty)
    }

    @Test func capacityEvictsLeastRecentlyUsed() {
        var cache = ReplyRootCache(capacity: 4)
        let roots = (1...4).map { CoreFixtures.post($0, channel: channel.id) }
        for root in roots { cache.record(root, plainText: root.message) }
        cache.touch([roots[0].id])
        cache.record(CoreFixtures.post(5, channel: channel.id), plainText: "five")
        #expect(cache.count <= 4)
        #expect(cache.contains(roots[0].id), "recently shown")
        #expect(!cache.contains(roots[1].id), "least recently used")
    }

    @Test func wantedRootsAreRequestedOnceUntilRetriesAreAllowed() {
        var cache = ReplyRootCache(capacity: 10)
        let id = CoreFixtures.post(1, channel: channel.id).id
        cache.want([id, id])
        #expect(cache.takeWanted(10) == [id])
        cache.want([id])
        #expect(cache.wanted.isEmpty, "already requested")
        cache.allowRetries()
        cache.want([id])
        #expect(cache.wanted == [id])
        cache.recordUnavailable(id)
        #expect(cache.peek(id)?.userID == nil)
    }
}

@Suite("Timeline builder: reply context")
struct ReplyContextBuilderTests {
    let channel = CoreFixtures.channel(1)

    func build(_ posts: [Post], window ids: [PostID]? = nil, cache: ReplyRootCache? = nil, collapsedThreads: Bool = false,
               thread: PostID? = nil, pending: [PendingSend] = []) -> TimelineBuilder.Output {
        var store = PostStore(render: { CoreFixtures.plainDocuments.document(for: $0) })
        for post in posts { store.upsert(post) }
        let shown = posts.filter { ids?.contains($0.id) ?? true }
        let target: TimelineTarget = thread.map { .thread(root: $0, channel: channel.id) } ?? .channel(channel.id)
        var window = HistoryWindow(target: target)
        _ = window.replace(with: shown.map { HistoryWindow.Entry(id: $0.id, createAt: $0.createAt) }, hasOlder: false,
                           hasNewer: false)
        var directory = DirectoryStore(budget: .standard)
        directory.pin(CoreFixtures.me)
        directory.upsertUser(CoreFixtures.bob)
        let context = TimelineBuildContext(
            scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id), me: CoreFixtures.me.id, channel: channel,
            teamName: "qa", endpoint: CoreFixtures.endpoint, collapsedThreads: collapsedThreads, editTimeLimitSeconds: nil,
            canDeleteOthers: false, now: MattermostTimestamp(milliseconds: 1_800_000_000_000), collapsedMessageCharacters: 4_000,
            timeZone: TimeZone(secondsFromGMT: 0)!)
        return TimelineBuilder.build(window: window, store: store, directory: directory, pending: pending, context: context,
                                     replyRoots: cache)
    }

    func rows(_ output: TimelineBuilder.Output) -> [PostPresentation] { output.items.compactMap(\.post) }

    @Test func replyShowsTheRetainedRootsAuthorAndText() throws {
        var root = CoreFixtures.post(1, channel: channel.id, message: "Could you look\ninto support?")
        root.replyCount = 1
        root.lastReplyAt = MattermostTimestamp(milliseconds: 1_700_000_002_000)
        let reply = CoreFixtures.post(2, channel: channel.id, user: CoreFixtures.me.id, rootID: root.id)
        let output = build([root, reply])
        let shown = rows(output)
        #expect(shown[0].replyContext == nil && shown[0].lastReplyAt == root.lastReplyAt)
        let context = try #require(shown[1].replyContext)
        #expect(context.rootID == root.id)
        #expect(context.author?.userID == CoreFixtures.bob.id)
        #expect(context.preview == .text("Could you look into support?"))
        #expect(!shown[1].isContinuation)
        #expect(output.missingRoots.isEmpty)
    }

    @Test func unknownRootIsReportedAndShownAsLoading() throws {
        let rootID = CoreFixtures.post(1, channel: channel.id).id
        let reply = CoreFixtures.post(2, channel: channel.id, rootID: rootID)
        let output = build([reply])
        #expect(rows(output)[0].replyContext == ReplyContextPresentation(rootID: rootID, author: nil, preview: .loading))
        #expect(output.missingRoots == [rootID])
    }

    @Test func cachedSummaryStandsInForAnEvictedRoot() throws {
        var root = CoreFixtures.post(1, channel: channel.id, message: "")
        root.fileIDs = [FileID(unchecked: CoreFixtures.id("file", 1))]
        var cache = ReplyRootCache(capacity: 10)
        cache.record(root, plainText: "")
        let reply = CoreFixtures.post(2, channel: channel.id, rootID: root.id)
        let output = build([reply], cache: cache)
        #expect(rows(output)[0].replyContext?.preview == .attachments(1))
        #expect(output.shownRoots == [root.id] && output.missingRoots.isEmpty)
        cache.markDeleted(root.id)
        #expect(rows(build([reply], cache: cache))[0].replyContext?.preview == .deleted)
    }

    @Test func noReplyLineWithCollapsedThreadsOrInsideTheThread() {
        let root = CoreFixtures.post(1, channel: channel.id)
        let reply = CoreFixtures.post(2, channel: channel.id, rootID: root.id)
        #expect(rows(build([root, reply], thread: root.id)).allSatisfy { $0.replyContext == nil })
        #expect(rows(build([root, reply], collapsedThreads: true)).allSatisfy { $0.replyContext == nil })
    }

    @Test func pendingReplyFromTheChannelShowsItsContext() throws {
        let root = CoreFixtures.post(1, channel: channel.id, user: CoreFixtures.me.id, createAt: 1_700_000_000_000)
        let ledger = UnsentWorkLedger(budget: .standard)
        let send = PendingSend(pendingID: PendingPostID(rawValue: "me:1")!, channelID: channel.id, rootID: root.id,
                               message: "on it", attachments: [], createdAt: MattermostTimestamp(milliseconds: 1_700_000_001_000),
                               reservation: try ledger.convertDraftToPending(nil, bytes: 5))
        let shown = rows(build([root], pending: [send]))
        #expect(shown.count == 2)
        #expect(shown[1].replyContext?.rootID == root.id)
        #expect(!shown[1].isContinuation, "a reply line always starts a new group")
    }
}

@Suite("Reply roots in a session", .serialized)
struct ReplyRootSessionTests {
    @Test func rootsOfLoadedRepliesAreFetchedAndKept() async throws {
        let channel = CoreFixtures.channel(1, total: 0)
        let root = CoreFixtures.post(90, channel: channel.id, message: "the original\nquestion", createAt: 1)
        let reply = CoreFixtures.post(91, channel: channel.id, user: CoreFixtures.me.id, rootID: root.id)
        let h = await SessionHarness(posts: 0) { state in
            state.posts[root.id] = root
            state.posts[reply.id] = reply
            state.postsHandler = { _, _ in PostPage(posts: [reply]) }
        }
        await h.openChannel()
        #expect(await eventually { await h.session.replyRoots.peek(root.id)?.preview == "the original question" })
        #expect(h.service.calls.contains("postsByIDs"))
        #expect(await h.session.store.contains(root.id) == false, "the root is not part of the window")
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
