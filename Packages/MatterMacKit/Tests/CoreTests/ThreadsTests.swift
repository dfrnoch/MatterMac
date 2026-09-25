import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("Followed threads", .serialized)
struct ThreadsTests {
    private static func thread(_ n: Int, channel: ChannelID, unread: Int, mentions: Int = 0) -> UserThread {
        let root = CoreFixtures.post(100 + n, channel: channel, message: "**Root** \(n)", createAt: 1_700_000_000_000 + Int64(n))
        return UserThread(root: root, replyCount: 3, lastReplyAt: MattermostTimestamp(milliseconds: 1_800_000_000_000 + Int64(n)),
                          lastViewedAt: .zero, unreadReplies: unread, unreadMentions: mentions,
                          participants: [CoreFixtures.bob, CoreFixtures.me])
    }

    @Test func unavailableWithoutCollapsedThreads() async {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        await #expect(throws: UserFacingError.self) { try await h.session.followedThreads(unreadOnly: false, before: nil) }
        var activity = h.session.threadActivity.makeAsyncIterator()
        let first = await activity.next()
        #expect(first?.isAvailable == false)
    }

    @Test func pagesSummariesAndTotalsWithoutLooping() async throws {
        let channelID = CoreFixtures.channel(1).id
        let h = await SessionHarness(configure: { state in
            state.collapsedThreadsConfig = "always_on"
            state.threads = (0..<30).map { ThreadsTests.thread($0, channel: channelID, unread: $0 < 4 ? 1 : 0, mentions: $0 == 0 ? 2 : 0) }
        })
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        let page = try await h.session.followedThreads(unreadOnly: false, before: nil)
        #expect(page.threads.count == ServerSession.threadsPageSize)
        #expect(page.hasMore)
        #expect(page.unreadThreads == 4 && page.unreadMentions == 2)
        let newest = try #require(page.threads.first)
        #expect(newest.rootID == CoreFixtures.post(129, channel: channelID).id)
        #expect(newest.preview.contains("Root") && newest.preview.hasSuffix("29"))
        #expect(newest.channelName == "Channel 1")
        #expect(newest.participants.map(\.name) == ["bob", "alice"])
        let older = try await h.session.followedThreads(unreadOnly: false, before: page.threads.last?.rootID)
        #expect(older.threads.count == 5 && !older.hasMore)
        let unread = try await h.session.followedThreads(unreadOnly: true, before: nil)
        #expect(unread.threads.count == 4)
        // Settle the independent startup refresh before testing page-only revisions.
        #expect(await eventually { await !h.session.isRunning(.threadTotals) })
        // Fetching pages publishes totals without bumping the revision.
        let revision = await h.session.threadActivityRevision
        _ = try await h.session.followedThreads(unreadOnly: false, before: nil)
        #expect(await h.session.threadActivityRevision == revision)

        try await h.session.markThreadRead(nil)
        #expect(h.service.withState { $0.threads.allSatisfy { $0.unreadReplies == 0 } })
        #expect(await h.session.isFollowingThread(newest.rootID) == true)
        try await h.session.setThreadFollowing(newest.rootID, false)
        #expect(await h.session.isFollowingThread(newest.rootID) == false)
        #expect(h.service.withState { $0.threads.count } == 29)
        #expect(await eventually { await h.session.threadActivityRevision > revision })
    }

    @Test(arguments: [false, true])
    func totalsRefreshKeepsEventsReceivedDuringRequest(switchTeam: Bool) async throws {
        let second = Team(id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "second", displayName: "Second")
        let h = await SessionHarness(collapsedThreads: "always_on", configure: { $0.teams.append(second) })
        #expect(await eventually { await !h.session.isRunning(.threadTotals) })
        let started = Gate(), release = Gate()
        h.service.withState { state in
            state.userThreadsHandler = { _, _ in
                await started.open()
                await release.wait()
                return UserThreadList(threads: [], totalUnreadThreads: 9, totalUnreadMentions: 9)
            }
        }
        let revision = await h.session.threadActivityRevision
        await h.session.refreshThreadTotals()
        await started.wait()
        h.service.withState { state in
            state.userThreadsHandler = { team, _ in
                #expect(team == (switchTeam ? second.id : CoreFixtures.team.id))
                return UserThreadList(threads: [], totalUnreadThreads: 2, totalUnreadMentions: 1)
            }
        }
        if switchTeam { await h.session.selectTeam(second.id) }
        else { await h.session.refreshThreadTotals() }
        await release.open()
        #expect(await eventually { await !h.session.isRunning(.threadTotals) })
        // A previous team's response must never publish into the new team.
        #expect(await h.session.threadActivityRevision == revision + (switchTeam ? 1 : 2))
        var activity = h.session.threadActivity.makeAsyncIterator()
        let latest = await activity.next()
        #expect(latest?.unreadThreads == 2 && latest?.unreadMentions == 1)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func teamSwitchDiscardsLateThreadPage() async throws {
        let second = Team(id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "second", displayName: "Second")
        let h = await SessionHarness(collapsedThreads: "always_on", configure: { $0.teams.append(second) })
        let started = Gate(), release = Gate()
        h.service.withState { state in
            state.userThreadsHandler = { _, totalsOnly in
                if !totalsOnly { await started.open(); await release.wait() }
                return UserThreadList(threads: [], totalUnreadThreads: 0, totalUnreadMentions: 0)
            }
        }
        let page = Task { try await h.session.followedThreads(unreadOnly: false, before: nil) }
        await started.wait()
        await h.session.selectTeam(second.id)
        await release.open()
        await #expect(throws: UserFacingError.cancelled) { try await page.value }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func changingCollapsedThreadPreferencePublishesAvailability() async throws {
        let h = await SessionHarness(collapsedThreads: "default_off")
        #expect(await eventually { await !h.session.isRunning(.threadTotals) })
        try await h.session.setCollapsedThreads(true)
        #expect(await eventually { await !h.session.isRunning(.threadTotals) })
        var activity = h.session.threadActivity.makeAsyncIterator()
        let enabled = await activity.next()
        #expect(enabled?.isAvailable == true)
        try await h.session.setCollapsedThreads(false)
        #expect(await eventually { await !h.session.isRunning(.threadTotals) })
        let disabled = await activity.next()
        #expect(disabled?.isAvailable == false)
        #expect(disabled?.unreadThreads == 0)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func visibleThreadAtLiveEdgeIsMarkedReadOnce() async throws {
        let h = await SessionHarness(configure: { state in state.collapsedThreadsConfig = "always_on" })
        await h.openChannel()
        let root = CoreFixtures.post(1, channel: h.channel.id)
        let reply = CoreFixtures.post(50, channel: h.channel.id, rootID: root.id)
        h.service.withState { $0.posts[reply.id] = reply }
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        await h.session.openThread(root: root.id, channel: h.channel.id)
        let target = TimelineTarget.thread(root: root.id, channel: h.channel.id)
        _ = await eventually { await h.session.windows[target]?.isLoaded == true }
        // Not at the live edge: nothing is marked.
        await h.session.updateVisibility(target: target, first: root.id, last: root.id, atLiveEdge: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.service.withState { $0.threadReadMarks }.isEmpty)
        await h.session.updateVisibility(target: target, first: root.id, last: reply.id, atLiveEdge: true)
        #expect(await eventually { h.service.withState { $0.threadReadMarks } == [root.id] })
        // Re-reporting the same position does not mark again.
        await h.session.updateVisibility(target: target, first: reply.id, last: reply.id, atLiveEdge: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.service.withState { $0.threadReadMarks } == [root.id])
        // The app in the background never marks.
        await h.session.updateAppState(isActive: false, isWindowVisible: true)
        #expect(await h.session.threadReadTarget() == nil)
    }
}
