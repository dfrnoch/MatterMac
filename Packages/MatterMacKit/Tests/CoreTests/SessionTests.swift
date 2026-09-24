import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

/// Polls an async condition (waiting for the session's own async work, not for time).
func eventually(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

struct SessionHarness {
    let service: FakeMattermostService
    let realtime: FakeRealtimeConnection
    let session: ServerSession
    let unsent: UnsentWorkLedger
    let retention: RetentionLedger
    let wallClock: FixedWallClock
    let channel: Channel

    init(budget: ResourceBudget = .standard, posts: Int = 5, unread: Bool = false,
         collapsedThreads: String = "disabled",
         configure: @Sendable (inout FakeMattermostService.State) -> Void = { _ in }) async {
        let me = CoreFixtures.me
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: me)
        let channel = CoreFixtures.channel(1, total: Int64(posts))
        service.withState { state in
            state.collapsedThreadsConfig = collapsedThreads
            state.teams = [CoreFixtures.team]
            state.channels[channel.id] = channel
            state.memberships[channel.id] = ChannelMembership(
                channelID: channel.id, userID: me.id, lastViewedAt: MattermostTimestamp(milliseconds: unread ? 1 : 0),
                messageCount: unread ? 0 : Int64(posts), messageCountRoot: unread ? 0 : Int64(posts))
            state.users[CoreFixtures.bob.id] = CoreFixtures.bob
            for n in 0..<posts {
                let post = CoreFixtures.post(n, channel: channel.id)
                state.posts[post.id] = post
            }
            configure(&state)
        }
        let realtime = FakeRealtimeConnection()
        let wallClock = FixedWallClock()
        let retention = RetentionLedger(budget: budget)
        let unsent = UnsentWorkLedger(budget: budget)
        var deps = CoreFixtures.dependencies(budget: budget, realtime: realtime, retention: retention, unsent: unsent,
                                             clock: wallClock)
        deps.clock = ImmediateClock()
        let session = ServerSession(
            scope: AccountScope(server: ServerSlotID(1), user: me.id), endpoint: CoreFixtures.endpoint, me: me,
            credential: BearerCredential(token: "tokentokentokentokentoken1", kind: .session)!,
            capabilities: ServerCapabilities(), service: service, dependencies: deps)
        self.service = service
        self.realtime = realtime
        self.session = session
        self.unsent = unsent
        self.retention = retention
        self.wallClock = wallClock
        self.channel = channel
        await session.start()
    }

    func openChannel() async {
        await session.openChannel(channel.id)
        _ = await eventually { await session.windows[.channel(channel.id)]?.isLoaded == true }
    }

    func send(_ text: String) async -> PendingPostID {
        let reservation = try! unsent.convertDraftToPending(nil, bytes: text.utf8.count)
        return try! await session.enqueueSend(text: text, channel: channel.id, rootID: nil, attachments: [],
                                         reservation: reservation)
    }

    func windowIDs() async -> [PostID] { await session.windows[.channel(channel.id)]?.ids ?? [] }
}

@Suite("ServerSession send reconciliation", .serialized)
struct SessionSendTests {
    @Test func ambiguousUploadWaitsForUserAndReusesConfirmedFiles() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let firstFile = FileID(unchecked: "firstfilexxxxxxxxxxxxxxxxx")
        h.service.withState { state in
            state.uploadHandler = { source, channel in
                if source.fileName == "second" { throw APIError.outcomeUnknown(.connectionLost) }
                return FileInfo(id: firstFile, channelID: channel, name: source.fileName, size: 1)
            }
        }
        let sources = ["first", "second"].map { UploadSource(fileURL: URL(fileURLWithPath: "/fixture/" + $0), fileName: $0, expectedSize: 1) }
        let reservation = try h.unsent.convertDraftToPending(nil, bytes: 1)
        let id = try await h.session.enqueueSend(text: "", channel: h.channel.id, rootID: nil, attachments: sources, reservation: reservation)
        #expect(await eventually { await h.session.pending.item(id)?.state == .outcomeUnknown })
        #expect(await h.session.pending.item(id)?.attachments.first?.uploadedFileID == firstFile)
        await h.session.resumeQueuedSends()
        #expect(h.service.calls.filter { $0 == "upload" }.count == 2)
        #expect(h.service.withState { $0.createdPosts.isEmpty })
        h.service.withState { $0.uploadHandler = nil }
        await h.session.retrySend(id)
        #expect(await eventually { await h.session.pending.isEmpty })
        #expect(h.service.calls.filter { $0 == "upload" }.count == 3)
        #expect(h.service.withState { $0.createdPosts.first?.fileIDs.count } == 2)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func discardStopsUploadAndContinuesNextMessage() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        h.service.withState { state in
            state.uploadHandler = { _, _ in
                try await Task.sleep(for: .seconds(20))
                throw APIError.cancelled
            }
        }
        let reservation = try h.unsent.convertDraftToPending(nil, bytes: 1)
        let source = UploadSource(fileURL: URL(fileURLWithPath: "/fixture"), fileName: "fixture", expectedSize: 1)
        let id = try await h.session.enqueueSend(text: "", channel: h.channel.id, rootID: nil,
                                                attachments: [source], reservation: reservation)
        #expect(await eventually { h.service.calls.contains("upload") })
        let next = await h.send("next message")
        #expect(await h.session.discardSend(id) == "")
        #expect(await eventually { await h.session.pending.isEmpty })
        #expect(h.service.withState { $0.createdPosts.map(\.pendingPostID) } == [next])
        #expect(h.unsent.usage.totalBytes == 0)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func membershipRevocationCancelsDownload() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        h.service.withState { state in
            state.downloadHandler = { _, _ in try await Task.sleep(for: .seconds(20)) }
        }
        let task = Task { try await h.session.downloadAttachment(FileID(unchecked: "fixture"), channel: h.channel.id,
                                                                  to: URL(fileURLWithPath: "/unused-test-destination")) }
        #expect(await eventually { h.service.calls.contains("download") })
        await h.session.purgeChannel(h.channel.id, reason: nil)
        do { try await task.value; Issue.record("Revoked download completed") } catch {}
        #expect(await h.session.downloads.isEmpty)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func restResponseBeforeEchoYieldsOneCanonicalPost() async {
        let h = await SessionHarness()
        await h.openChannel()
        let pendingID = await h.send("hello from MatterMac")
        #expect(await eventually { await h.session.pending.isEmpty })
        let created = h.service.withState { $0.posts.values.first { $0.pendingPostID == pendingID } }!
        // The WebSocket echo arrives afterwards.
        await h.realtime.push(.posted(PostedEvent(post: created, channelType: .open, teamID: CoreFixtures.team.id,
                                                  mentionsCurrentUser: false, setOnline: true)))
        _ = await eventually { await h.realtime.queuedCount == 0 }
        try? await Task.sleep(for: .milliseconds(20))
        let ids = await h.windowIDs()
        #expect(ids.filter { $0 == created.id }.count == 1)
        #expect(h.unsent.usage.pendingOperations == 0)
        #expect(h.unsent.usage.pendingBytes == 0)
        #expect(h.service.withState { $0.createdPosts.count } == 1)
    }

    @Test func echoBeforeRestResponseConfirmsOnce() async {
        let h = await SessionHarness()
        await h.openChannel()
        let gate = Gate()
        let service = h.service
        let realtime = h.realtime
        h.service.withState { state in
            state.createPostHandler = { outgoing, _ in
                let post = service.storeCreated(outgoing)
                // Server publishes the echo before the HTTP response is delivered.
                await realtime.push(.posted(PostedEvent(post: post, channelType: .open, teamID: nil,
                                                        mentionsCurrentUser: false, setOnline: true)))
                await gate.wait()
                return post
            }
        }
        _ = await h.send("race")
        // Confirmed by the echo while the POST is still outstanding.
        #expect(await eventually { await h.session.pending.isEmpty })
        await gate.open()
        try? await Task.sleep(for: .milliseconds(30))
        let ids = await h.windowIDs()
        let serverPost = h.service.withState { $0.createdPosts.count }
        #expect(serverPost == 1)
        #expect(ids.count == 6)
        #expect(h.unsent.usage.pendingOperations == 0)
    }

    @Test func lostResponseInsideDedupWindowRetriesWithSameIDAndNeverFalselyConfirms() async {
        let h = await SessionHarness()
        await h.openChannel()
        let service = h.service
        let gate = Gate()
        h.service.withState { state in
            state.createPostHandler = { outgoing, attempt in
                let post = service.storeCreated(outgoing)
                if attempt == 1 {
                    // Created on the server, but the response is lost.
                    throw APIError.outcomeUnknown(.timedOut)
                }
                await gate.wait()
                // Dedup-return path: raw DB post without pending_post_id.
                var raw = post
                raw.pendingPostID = nil
                return raw
            }
        }
        let pendingID = await h.send("do not duplicate me")
        // While the retry is outstanding the item is not confirmed and the text is kept.
        #expect(await eventually { h.service.withState { $0.createdPosts.count } == 2 })
        let item = await h.session.pending.item(pendingID)
        #expect(item?.message == "do not duplicate me")
        #expect(h.unsent.usage.pendingOperations == 1)
        await gate.open()
        #expect(await eventually { await h.session.pending.isEmpty })
        let attempts = h.service.withState { $0.createdPosts.map(\.pendingPostID) }
        #expect(attempts == [pendingID, pendingID])
        let serverCopies = h.service.withState { state in state.posts.values.filter { $0.message == "do not duplicate me" }.count }
        #expect(serverCopies == 1)
        let ids = await h.windowIDs()
        #expect(ids.count == 6)
    }

    @Test func lostResponseAfterDedupWindowBecomesUnknownAndWaitsForUser() async {
        let h = await SessionHarness()
        await h.openChannel()
        let clock = h.wallClock
        h.service.withState { state in
            state.createPostHandler = { _, _ in
                clock.advance(milliseconds: 40_000)
                throw APIError.outcomeUnknown(.connectionLost)
            }
        }
        let pendingID = await h.send("uncertain")
        #expect(await eventually {
            if case .outcomeUnknown = await h.session.pending.item(pendingID)?.state { return true }
            return false
        })
        try? await Task.sleep(for: .milliseconds(30))
        // No silent automatic retry beyond the dedup window.
        #expect(h.service.withState { $0.createdPosts.count } == 1)
        #expect(await h.session.pendingText(pendingID) == "uncertain")
        // Discarding returns the text so the UI can offer to copy it.
        let text = await h.session.discardSend(pendingID)
        #expect(text == "uncertain")
        #expect(h.unsent.usage.pendingOperations == 0)
    }

    @Test func permissionFailureKeepsTextAsFailed() async {
        let h = await SessionHarness()
        await h.openChannel()
        h.service.withState { state in
            state.createPostHandler = { _, _ in
                throw APIError.forbidden(ServerErrorInfo(id: ServerErrorID.permissions, statusCode: 403, requestID: nil))
            }
        }
        let pendingID = await h.send("forbidden text")
        #expect(await eventually { await h.session.pending.item(pendingID)?.state == .failed(.permissionDenied) })
        #expect(await h.session.pendingText(pendingID) == "forbidden text")
        #expect(await h.session.isActiveSessionAlive)
        #expect(h.unsent.usage.pendingOperations == 1)
    }
}

@Suite("ServerSession snapshot/event races", .serialized)
struct SessionRaceTests {
    @Test func reactionArrivingDuringSnapshotIsNotLost() async {
        let h = await SessionHarness()
        let gate = Gate()
        let service = h.service
        let channelID = h.channel.id
        h.service.withState { state in
            state.postsHandler = { _, _ in
                // Snapshot computed before the reaction...
                let posts = service.withState { s in s.posts.values.filter { $0.channelID == channelID } }
                    .sorted { $0.createAt > $1.createAt }
                await gate.wait()
                return PostPage(posts: posts)
            }
        }
        await h.session.openChannel(h.channel.id)
        try? await Task.sleep(for: .milliseconds(20))
        let target = PostID(unchecked: CoreFixtures.id("post", 2))
        let reaction = Reaction(userID: CoreFixtures.bob.id, postID: target, emojiName: "tada")
        await h.realtime.push(.reactionAdded(reaction))
        _ = await eventually { await h.realtime.queuedCount == 0 }
        try? await Task.sleep(for: .milliseconds(20))
        await gate.open()
        #expect(await eventually { await h.session.windows[.channel(h.channel.id)]?.isLoaded == true })
        let stored = await h.session.store.post(target)
        #expect(stored?.reactions == [reaction])
    }

    @Test func olderSnapshotAfterEditKeepsEdit() async {
        let h = await SessionHarness()
        let gate = Gate()
        let service = h.service
        let channelID = h.channel.id
        let target = PostID(unchecked: CoreFixtures.id("post", 3))
        h.service.withState { state in
            state.postsHandler = { _, _ in
                let posts = service.withState { s in s.posts.values.filter { $0.channelID == channelID } }
                    .sorted { $0.createAt > $1.createAt }
                await gate.wait()
                return PostPage(posts: posts)
            }
        }
        await h.session.openChannel(h.channel.id)
        try? await Task.sleep(for: .milliseconds(20))
        var edited = CoreFixtures.post(3, channel: h.channel.id, message: "edited text")
        edited.updateAt = MattermostTimestamp(milliseconds: edited.createAt.milliseconds + 60_000)
        edited.editAt = edited.updateAt
        await h.realtime.push(.postEdited(edited))
        _ = await eventually { await h.realtime.queuedCount == 0 }
        try? await Task.sleep(for: .milliseconds(20))
        await gate.open()
        #expect(await eventually { await h.session.windows[.channel(h.channel.id)]?.isLoaded == true })
        #expect(await h.session.store.post(target)?.message == "edited text")
    }

    @Test func deleteEventRemovesContentAndThreadReplies() async {
        let h = await SessionHarness()
        await h.openChannel()
        let root = CoreFixtures.post(1, channel: h.channel.id)
        await h.realtime.push(.postDeleted(root))
        #expect(await eventually { await h.session.store.post(root.id)?.isDeleted == true })
        #expect(await h.session.store.post(root.id)?.message == "")
    }

    @Test func duplicatePostedEventsDoNotDuplicateRows() async {
        let h = await SessionHarness()
        await h.openChannel()
        let incoming = CoreFixtures.post(99, channel: h.channel.id)
        let event = RealtimeEvent.posted(PostedEvent(post: incoming, channelType: .open, teamID: nil,
                                                     mentionsCurrentUser: true, setOnline: true))
        await h.realtime.push(event)
        await h.realtime.push(event)
        #expect(await eventually { await h.windowIDs().contains(incoming.id) })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await h.windowIDs().filter { $0 == incoming.id }.count == 1)
    }

    @Test func slowHistoryForPreviousChannelDoesNotLeakIntoNewChannel() async {
        let h = await SessionHarness()
        let other = CoreFixtures.channel(2)
        h.service.withState { state in
            state.channels[other.id] = other
            state.memberships[other.id] = ChannelMembership(channelID: other.id, userID: CoreFixtures.me.id)
        }
        await h.session.selectTeam(CoreFixtures.team.id)
        await h.session.loadChannels(team: CoreFixtures.team.id)
        let gate = Gate()
        let service = h.service
        let first = h.channel.id
        h.service.withState { state in
            state.postsHandler = { channel, _ in
                if channel == first { await gate.wait() }
                let posts = service.withState { s in s.posts.values.filter { $0.channelID == channel } }
                return PostPage(posts: posts.sorted { $0.createAt > $1.createAt })
            }
        }
        var timeline = h.session.timelineUpdates.makeAsyncIterator()
        await h.session.openChannel(first)
        await h.session.openChannel(other.id)
        await gate.open()
        #expect(await eventually { await h.session.windows[.channel(first)]?.isLoaded == true })
        #expect(await h.session.activeChannel == other.id)
        // Snapshots are latest-value buffered: after the late response for the first
        // channel, the newest published timeline must still be the visible channel's.
        await h.session.markDirty(.timeline)
        try? await Task.sleep(for: .milliseconds(30))
        let latest = await timeline.next()
        #expect(latest?.target == .channel(other.id))
    }
}

@Suite("ServerSession lifecycle, revocation, bounds", .serialized)
struct SessionLifecycleTests {
    @Test func authenticated401StopsRequestsButKeepsUnsentWork() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        h.service.withState { state in
            state.createPostHandler = { _, _ in throw APIError.notSent(.offline) }
            state.editPostHandler = { _, _ in
                throw APIError.unauthorized(ServerErrorInfo(id: "deployment.expired", statusCode: 401, requestID: nil))
            }
        }
        let pending = await h.send("keep pending text")
        #expect(await eventually { await h.session.pending.item(pending)?.state == .failed(.offline) })
        await #expect(throws: UserFacingError.authenticationRequired) {
            try await h.session.edit(CoreFixtures.post(1, channel: h.channel.id).id, text: "keep edit draft")
        }
        #expect(await h.session.isActiveSessionAlive == false)
        #expect(await eventually { await h.realtime.isStopped })
        #expect(await h.session.store.count == 0)
        #expect(await h.session.directory.channels.isEmpty)
        #expect(await h.session.unsentTexts == ["keep pending text"])
        #expect(h.unsent.usage.pendingOperations == 1)
        let calls = h.service.calls.count
        await h.session.retrySend(pending)
        await h.session.reconnectNow()
        await h.session.systemDidWake()
        await h.session.userIsTyping(channel: h.channel.id, root: nil)
        await h.session.handle(.state(.disconnected))
        await #expect(throws: ServerSession.SendRejection.sessionClosed) {
            try await h.session.validateSend(text: "new", channel: h.channel.id, attachments: [])
        }
        await #expect(throws: UserFacingError.authenticationRequired) {
            try await h.session.delete(CoreFixtures.post(1, channel: h.channel.id).id)
        }
        #expect(h.service.calls.count == calls)
        #expect(await h.realtime.reconnectRequests.isEmpty)
        #expect(await h.session.connection == .authenticationRequired)
        _ = await h.session.shutdown(revokeServerSession: false)
        #expect(h.unsent.usage.totalBytes == 0)
    }

    @Test func scheduledButNotStartedWorkCannotRunAfterAuthenticationEnds() async {
        let h = await SessionHarness()
        let configurations = h.service.calls.filter { $0 == "fullConfiguration" }.count
        await h.session.scheduleRefreshThenEndAuthenticationForTest()
        #expect(await eventually { await !h.session.isRunning(.configRefresh) })
        #expect(h.service.calls.filter { $0 == "fullConfiguration" }.count == configurations)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func changedIdentityStopsSessionBeforeApplyingNewUser() async {
        let h = await SessionHarness()
        await h.openChannel()
        h.service.withState { $0.me = CoreFixtures.bob }
        await h.session.refreshIdentity()
        #expect(await eventually { await h.session.authenticationEnded })
        #expect(await h.session.currentUser().id == CoreFixtures.me.id)
        #expect(await h.session.store.count == 0)
        #expect(await eventually { await h.realtime.isStopped })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func revokedUploadCannotPostLateAndKeepsItsImageReservation() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let gate = Gate()
        h.service.withState { state in
            state.uploadHandler = { source, channel in
                await gate.wait() // Deliberately ignores task cancellation.
                return FileInfo(id: FileID(unchecked: "fixture"), channelID: channel, name: "fixture", size: source.expectedSize)
            }
        }
        let png = CoreFixtures.png()
        var source: UploadSource? = try h.unsent.pastedImage(png, typeIdentifier: "public.png")
        let reservation = try h.unsent.convertDraftToPending(nil, bytes: source!.metadataBytes)
        let id = try await h.session.enqueueSend(text: "", channel: h.channel.id, rootID: nil,
                                                attachments: [source!], reservation: reservation)
        source = nil
        #expect(await eventually { h.service.calls.contains("upload") })
        await h.session.purgeChannel(h.channel.id, reason: nil)
        await gate.open()
        #expect(await eventually { await !h.session.isRunning(.sender) })
        #expect(!h.service.calls.contains("createPost"))
        #expect(await h.session.pending.item(id)?.state == .outcomeUnknown)
        #expect(h.unsent.usage.imageBytes == png.count)
        await h.session.retrySend(id)
        #expect(await h.session.pending.item(id)?.state == .outcomeUnknown)
        #expect(await h.session.discardSend(id) == "")
        #expect(h.unsent.usage.imageBytes == 0)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func membershipRevocationPurgesContentAndRetainsChargedUnsentWork() async {
        let h = await SessionHarness()
        await h.openChannel()
        h.service.withState { state in
            state.createPostHandler = { _, _ in throw APIError.notSent(.offline) }
        }
        _ = await h.send("unsent before revocation")
        _ = await eventually { await h.session.pending.items.first?.state == .failed(.offline) }
        var notices = h.session.notices.makeAsyncIterator()
        await h.realtime.push(.userRemoved(userID: CoreFixtures.me.id, channelID: h.channel.id, removerID: nil))
        let notice = await notices.next()
        #expect(notice == .accessRevoked(channel: h.channel.id))
        #expect(await h.session.directory.channels[h.channel.id] == nil)
        #expect(await h.session.windows.isEmpty)
        #expect(await h.session.store.count == 0)
        #expect(h.unsent.usage.pendingOperations == 1)
        #expect(await h.session.unsentTexts == ["unsent before revocation"])
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func shutdownCancelsWorkAndIgnoresLateResponses() async {
        let h = await SessionHarness()
        await h.openChannel()
        let gate = Gate()
        let service = h.service
        h.service.withState { state in
            state.createPostHandler = { outgoing, _ in
                await gate.wait()
                return service.storeCreated(outgoing)
            }
        }
        _ = await h.send("in flight at sign-out")
        _ = await eventually { h.service.withState { $0.createdPosts.count } == 1 }
        let outcome = await h.session.shutdown(revokeServerSession: true)
        #expect(outcome == .serverSessionRevoked)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await h.session.store.count == 0)
        #expect(await h.session.windows.isEmpty)
        #expect(await h.session.tasks.isEmpty)
        #expect(await h.realtime.isStopped)
        #expect(h.unsent.usage.pendingOperations == 0)
        #expect(h.retention.total.count == 0)
        #expect(h.service.calls.contains("logout"))
    }

    @Test func retainedPostsStayWithinBudgetWhilePagingDeep() async {
        var budget = ResourceBudget()
        budget.retainedPosts = .init(count: 120, bytes: 16 * .mebibyte)
        budget.activeTimeline = .init(count: 100, bytes: 8 * .mebibyte)
        let h = await SessionHarness(budget: budget, posts: 1_000)
        await h.openChannel()
        let target = TimelineTarget.channel(h.channel.id)
        for _ in 0..<15 {
            await h.session.loadOlder(target)
            _ = await eventually {
                if case .loading = await h.session.windows[target]?.olderState { return false }
                return true
            }
            let count = await h.session.store.count
            #expect(count <= 120)
            #expect(await h.session.windows[target]?.count ?? 0 <= 100)
        }
        // Deep history is reachable and the window records gaps on both sides.
        let window = await h.session.windows[target]
        #expect(window?.hasOlder == true)
        #expect(window?.hasNewer == true)
        #expect(h.retention.total.count == (await h.session.store.count))
    }

    @Test func readStateIsMarkedOnlyWhenVisibleActiveAndAtLiveEdge() async {
        let h = await SessionHarness(unread: true)
        await h.openChannel()
        await h.session.updateAppState(isActive: false, isWindowVisible: true)
        await h.session.updateVisibility(target: .channel(h.channel.id), first: nil, last: nil, atLiveEdge: true)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!h.service.withState { $0.viewedChannels.contains(h.channel.id) })
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        #expect(await eventually { h.service.withState { $0.viewedChannels.contains(h.channel.id) } })
        let unread = await h.session.directory.unread(for: h.channel.id, collapsedThreads: false)
        #expect(!unread.isUnread)
    }

    @Test func notAtLiveEdgeDoesNotMarkRead() async {
        let h = await SessionHarness(unread: true)
        await h.openChannel()
        await h.session.updateVisibility(target: .channel(h.channel.id), first: nil, last: nil, atLiveEdge: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!h.service.withState { $0.viewedChannels.contains(h.channel.id) })
    }

    @Test func resyncReconcilesVisibleWindowIncludingDeletions() async {
        let h = await SessionHarness()
        await h.openChannel()
        let deletedID = PostID(unchecked: CoreFixtures.id("post", 4))
        h.service.withState { state in
            state.postsByIDsHandler = { ids in
                // The server no longer returns post 4 (deleted while we were offline).
                ids.compactMap { id in id == deletedID ? nil : CoreFixtures.post(Int(id.rawValue.dropFirst(4).prefix { $0.isNumber })!, channel: CoreFixtures.channel(1).id) }
            }
        }
        await h.realtime.push(.resynchronize(.newConnection))
        #expect(await eventually { h.service.calls.contains("postsByIDs") })
        #expect(await eventually { await h.session.store.post(deletedID)?.isDeleted == true })
    }
}

@Test func closedSessionRefusesNewSendWithoutClaimingItWasQueued() async throws {
    let h = await SessionHarness()
    _ = await h.session.shutdown(revokeServerSession: false)
    let reservation = try h.unsent.convertDraftToPending(nil, bytes: 4)
    await #expect(throws: ServerSession.SendRejection.sessionClosed) {
        try await h.session.enqueueSend(text: "keep", channel: h.channel.id, rootID: nil,
                                        attachments: [], reservation: reservation)
    }
    #expect(await h.session.unsentOperationCount == 0)
    // A rejected reservation still belongs to the caller so it can restore the draft.
    #expect(h.unsent.usage.pendingBytes == 4)
    h.unsent.release(reservation)
}

private extension ServerSession {
    func scheduleRefreshThenEndAuthenticationForTest() {
        run(.configRefresh) { session in _ = try? await session.service.fullConfiguration() }
        notify(.signedOutByServer) // Same actor turn: the queued task cannot have started yet.
    }
}
