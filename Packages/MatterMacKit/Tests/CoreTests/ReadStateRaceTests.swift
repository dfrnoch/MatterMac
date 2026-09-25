import Testing
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacCore

@Suite("Read-state races", .serialized)
struct ReadStateRaceTests {
    @Test func newChannelIsMarkedAfterPreviousRequestFinishes() async throws {
        let second = CoreFixtures.channel(2, total: 1)
        let h = await SessionHarness(unread: true) { state in
            state.channels[second.id] = second
            state.memberships[second.id] = ChannelMembership(channelID: second.id, userID: CoreFixtures.me.id)
            let post = CoreFixtures.post(20, channel: second.id)
            state.posts[post.id] = post
        }
        await h.openChannel()
        let gate = Gate(), started = Gate()
        let first = h.channel.id
        h.service.withState { state in
            state.viewChannelHandler = { id in
                if id == first { await started.open(); await gate.wait() }
                return id.map { [$0: MattermostTimestamp(milliseconds: 1)] } ?? [:]
            }
        }
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        await h.session.updateVisibility(target: .channel(first), first: nil, last: nil, atLiveEdge: true)
        await started.wait()
        await h.session.openChannel(second.id)
        #expect(await eventually { await h.session.windows[.channel(second.id)]?.isLoaded == true })
        await h.session.updateVisibility(target: .channel(second.id), first: nil, last: nil, atLiveEdge: true)
        await gate.open()
        #expect(await eventually { await !h.session.directory.unread(for: second.id, collapsedThreads: false).isUnread })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func olderViewEventPreservesNewerUnreadPost() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let newer = CoreFixtures.post(51, channel: h.channel.id)
        await h.realtime.push(.event(.posted(PostedEvent(post: newer, channelType: .open,
            teamID: CoreFixtures.team.id, mentionsCurrentUser: false, setOnline: false))))
        #expect(await eventually { await h.session.store.post(newer.id) != nil })
        await h.session.markViewedLocally(h.channel.id, at: MattermostTimestamp(milliseconds: newer.createAt.milliseconds - 1))
        #expect(await h.session.directory.unread(for: h.channel.id, collapsedThreads: false).isUnread)
        await h.session.markViewedLocally(h.channel.id, at: newer.createAt)
        #expect(await !h.session.directory.unread(for: h.channel.id, collapsedThreads: false).isUnread)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func failedReadWithoutNewVisibilityDoesNotRetryItself() async throws {
        let h = await SessionHarness(unread: true)
        await h.openChannel()
        let gate = Gate(), started = Gate()
        h.service.withState { state in
            state.viewChannelHandler = { _ in
                await started.open(); await gate.wait()
                throw APIError.notSent(.offline)
            }
        }
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        await h.session.updateVisibility(target: .channel(h.channel.id), first: nil, last: nil, atLiveEdge: true)
        await started.wait()
        let task = await h.session.tasks[.readMark]
        await gate.open()
        await task?.value
        #expect(await !h.session.isRunning(.readMark))
        #expect(h.service.calls.filter { $0 == "viewChannel" }.count == 1)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func cancelledViewResponseCannotUndoManualUnread() async throws {
        let h = await SessionHarness(unread: true)
        await h.openChannel()
        let gate = Gate(), started = Gate()
        h.service.withState { state in
            state.viewChannelHandler = { id in
                await started.open(); await gate.wait()
                return id.map { [$0: MattermostTimestamp(milliseconds: 1)] } ?? [:]
            }
        }
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        await h.session.updateVisibility(target: .channel(h.channel.id), first: nil, last: nil, atLiveEdge: true)
        await started.wait()
        let task = await h.session.tasks[.readMark]
        try await h.session.markUnread(from: CoreFixtures.post(1, channel: h.channel.id).id)
        await gate.open()
        await task?.value
        #expect(await h.session.directory.unread(for: h.channel.id, collapsedThreads: false).isUnread)
        #expect(await h.session.manualUnreadHold == h.channel.id)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func replyArrivingDuringReadRequestGetsASecondReadMark() async throws {
        let h = await SessionHarness(collapsedThreads: "always_on")
        await h.openChannel()
        let root = CoreFixtures.post(1, channel: h.channel.id)
        let first = CoreFixtures.post(50, channel: h.channel.id, rootID: root.id)
        let newer = CoreFixtures.post(51, channel: h.channel.id, rootID: root.id)
        h.service.withState { $0.posts[first.id] = first }
        await h.session.openThread(root: root.id, channel: h.channel.id)
        let target = TimelineTarget.thread(root: root.id, channel: h.channel.id)
        #expect(await eventually { await h.session.windows[target]?.isLoaded == true })
        let gate = Gate(), started = Gate()
        h.service.withState { state in
            state.threadReadHandler = { _, timestamp in
                if timestamp == first.createAt { await started.open(); await gate.wait() }
            }
        }
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        await h.session.updateVisibility(target: target, first: root.id, last: first.id, atLiveEdge: true)
        await started.wait()
        await h.realtime.push(.event(.posted(PostedEvent(post: newer, channelType: .open, teamID: CoreFixtures.team.id,
                                                       mentionsCurrentUser: false, setOnline: false))))
        #expect(await eventually { await h.session.store.post(newer.id) != nil })
        await gate.open()
        #expect(await eventually { await h.session.threadReadMark?.at == newer.createAt })
        #expect(h.service.withState { $0.threadReadMarks.count } == 2)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
