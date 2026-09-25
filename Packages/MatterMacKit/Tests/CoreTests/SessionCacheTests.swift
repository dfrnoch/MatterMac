import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

@Suite("Session content cache")
struct SessionCacheTests {
    let channel = CoreFixtures.channel(1, total: 5)

    func makeSession(cache: ContentCache, configure: @Sendable (inout FakeMattermostService.State) -> Void = { _ in })
        -> (FakeMattermostService, ServerSession) {
        let me = CoreFixtures.me
        let channel = channel
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: me)
        service.withState { state in
            state.teams = [CoreFixtures.team]
            state.channels[channel.id] = channel
            // Unread: the cached window must not mark it read.
            state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: me.id,
                lastViewedAt: MattermostTimestamp(milliseconds: 1_700_000_002_500), messageCount: 2, messageCountRoot: 2)
            state.users[CoreFixtures.bob.id] = CoreFixtures.bob
            for n in 0..<5 {
                let post = CoreFixtures.post(n, channel: channel.id)
                state.posts[post.id] = post
            }
            configure(&state)
        }
        var deps = CoreFixtures.dependencies(realtime: FakeRealtimeConnection())
        deps.clock = ImmediateClock()
        deps.contentCache = cache
        let session = ServerSession(
            scope: AccountScope(server: ServerSlotID(1), user: me.id), endpoint: CoreFixtures.endpoint, me: me,
            credential: BearerCredential(token: "tokentokentokentokentoken1", kind: .session)!,
            capabilities: ServerCapabilities(), service: service, dependencies: deps)
        return (service, session)
    }

    @Test func relaunchShowsCachedSidebarAndPostsBeforeTheServerAnswers() async throws {
        let directory = ContentCacheTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryCacheKeys()
        func cache() -> ContentCache {
            ContentCache(storage: .init(directory: directory, keys: keys), budget: .standard,
                         diagnostics: DiagnosticRing(byteBudget: 1_024))
        }
        // First launch: load, open the channel, quit.
        let (_, first) = makeSession(cache: cache())
        await first.start()
        await first.openChannel(channel.id)
        #expect(await eventually { await first.windows[.channel(channel.id)]?.isLoaded == true })
        let loaded = await first.windows[.channel(channel.id)]?.ids ?? []
        #expect(loaded.count == 5)
        await first.persistCache()
        _ = await first.shutdown(revokeServerSession: false)

        // Second launch: the server's channel list and posts are held back.
        let channels = Gate(), posts = Gate()
        let channel = channel
        // The server now has one more post than the cache.
        let page = PostPage(posts: (0..<6).reversed().map { CoreFixtures.post($0, channel: channel.id) })
        let (service, second) = makeSession(cache: cache()) { state in
            state.channelsHandler = { _ in await channels.wait(); return [channel] }
            state.postsHandler = { _, _ in await posts.wait(); return page }
            state.unreadHandler = { _ in await posts.wait(); return page }
        }
        let start = Task { await second.start() }
        #expect(await eventually { await second.directory.channels[channel.id] != nil })
        #expect(await second.directory.peekUser(CoreFixtures.bob.id) != nil, "Profiles are restored")
        #expect(await second.restoredChannel == channel.id, "The last open channel is offered again")
        #expect(await second.directory.loadedTeams.isEmpty, "The channel list is still fetched")

        await second.updateAppState(isActive: true, isWindowVisible: true)
        await second.openChannel(channel.id)
        #expect(await eventually { await second.windows[.channel(channel.id)]?.isCached == true })
        #expect(await second.windows[.channel(channel.id)]?.ids == loaded)
        #expect(await second.restoredChannel == nil)
        await second.updateVisibility(target: .channel(channel.id), first: nil, last: loaded.last, atLiveEdge: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(service.withState { $0.viewedChannels }.isEmpty, "Cached posts never mark the channel read")
        #expect(await second.cachedChannelValue(channel.id) == nil, "A cached window is not written back")

        await posts.open()
        await channels.open()
        #expect(await eventually { await second.windows[.channel(channel.id)]?.isCached == false })
        #expect(await second.windows[.channel(channel.id)]?.ids.count == 6, "The server's page replaced the cache")
        #expect(await eventually { !service.withState { $0.viewedChannels }.isEmpty }, "Now it is marked read")
        _ = await start.value
        _ = await second.shutdown(revokeServerSession: false)
    }
}
