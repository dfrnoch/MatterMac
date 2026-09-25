import Testing
import MatterMacModels
import MattermostAPI
import TestSupport
@testable import MatterMacCore

@Suite("Search cancellation and pagination", .serialized)
struct SearchCancellationTests {
    @Test(arguments: [false, true], [false, true])
    func clearedQueryCannotReturnIntoNewQuery(list: Bool, fails: Bool) async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.selectedTeam != nil }
        let gate = Gate(), started = Gate()
        let old = CoreFixtures.post(20, channel: h.channel.id, message: "old")
        let fresh = CoreFixtures.post(21, channel: h.channel.id, message: "new")
        h.service.withState { state in
            state.searchPostsHandler = { query in
                if query.terms != "new" {
                    await started.open()
                    await gate.wait() // Deliberately ignores cancellation.
                    if fails { throw APIError.notSent(.connectionLost) }
                    return PostPage(posts: [old])
                }
                return PostPage(posts: [fresh])
            }
        }
        if list { await h.session.showRecentMentions() } else { await h.session.search("old") }
        await started.wait()
        let oldTask = try #require(await h.session.tasks[.search])
        let generation = await h.session.searchState.generation
        await h.session.clearSearch()
        await h.session.search("new")
        #expect(await eventually { await h.session.searchState.state == .results })
        #expect(await h.session.searchState.generation > generation)
        await gate.open()
        await oldTask.value
        #expect(await h.session.searchState.results == [fresh.id])
        #expect(await h.session.searchState.state == .results)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func repeatedLoadMoreDoesNotSkipAPage() async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.selectedTeam != nil }
        let gate = Gate()
        let posts = (0..<20).map { CoreFixtures.post($0, channel: h.channel.id) }
        h.service.withState { state in
            state.searchPostsHandler = { query in
                if query.page > 0 { await gate.wait() }
                return PostPage(posts: posts)
            }
        }
        await h.session.search("message")
        #expect(await eventually { await h.session.searchState.canLoadMore })
        await h.session.loadMoreSearchResults()
        await h.session.loadMoreSearchResults()
        #expect(await h.session.searchState.page == 1)
        #expect(await h.session.searchState.state == .searching)
        await gate.open()
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
