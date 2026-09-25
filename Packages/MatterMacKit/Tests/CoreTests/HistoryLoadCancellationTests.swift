import Testing
import MatterMacModels
import MattermostAPI
import TestSupport
@testable import MatterMacCore

private actor DelayedHistoryPages {
    let old = Gate()
    let replacement = Gate()
    private(set) var calls = 0
    let stale: Post
    let fresh: Post
    let failsOld: Bool

    init(channel: ChannelID, failsOld: Bool) {
        stale = CoreFixtures.post(800, channel: channel)
        fresh = CoreFixtures.post(801, channel: channel)
        self.failsOld = failsOld
    }

    func fetch() async throws -> PostPage {
        calls += 1
        if calls == 1 {
            await old.wait() // Deliberately returns even after task cancellation.
            if failsOld { throw APIError.cancelled }
            return PostPage(posts: [stale])
        }
        await replacement.wait()
        return PostPage(posts: [fresh])
    }
}

@Suite("History request ownership")
struct HistoryLoadCancellationTests {
    @Test(arguments: [false, true])
    func cancelledFailureCannotOverwriteReplacementLoadingState(replacing: Bool) async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let target = TimelineTarget.channel(h.channel.id)
        let pages = DelayedHistoryPages(channel: h.channel.id, failsOld: true)
        h.service.withState { $0.postsHandler = { _, _ in try await pages.fetch() } }
        if replacing { await h.session.startInitialLoadReplacingWindow(target) }
        else { await h.session.startInitialLoad(target) }
        #expect(await eventually { await pages.calls == 1 })
        let oldTask = try #require(await h.session.tasks[.initialLoad(target)])
        await h.session.startInitialLoadReplacingWindow(target)
        #expect(await eventually { await pages.calls == 2 })
        let expected = await h.session.windows[target]?.initialLoad
        await pages.old.open()
        await oldTask.value
        #expect(await h.session.windows[target]?.initialLoad == expected)
        await pages.replacement.open()
        #expect(await eventually { await h.session.windows[target]?.initialLoad == .idle })
        #expect(await h.session.windows[target]?.contains(pages.fresh.id) == true)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func cancelledSuccessCannotPopulateRecreatedWindowWithReusedGeneration() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let target = TimelineTarget.channel(h.channel.id)
        await h.session.closeWindow(target)
        let pages = DelayedHistoryPages(channel: h.channel.id, failsOld: false)
        h.service.withState { $0.postsHandler = { _, _ in try await pages.fetch() } }
        await h.session.openChannel(h.channel.id)
        #expect(await eventually { await pages.calls == 1 })
        let oldTask = try #require(await h.session.tasks[.initialLoad(target)])
        await h.session.closeWindow(target)
        await h.session.openChannel(h.channel.id)
        #expect(await eventually { await pages.calls == 2 })
        let expected = await h.session.windows[target]?.initialLoad
        await pages.old.open()
        await oldTask.value
        #expect(await h.session.windows[target]?.initialLoad == expected)
        #expect(await h.session.store.post(pages.stale.id) == nil)
        await pages.replacement.open()
        #expect(await eventually { await h.session.windows[target]?.initialLoad == .idle })
        #expect(await h.session.windows[target]?.contains(pages.fresh.id) == true)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
