import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

@Suite("Pin, save, mark unread and server links", .serialized)
struct InteractionSessionTests {
    func postID(_ n: Int) -> PostID { PostID(unchecked: CoreFixtures.id("post", n)) }

    @Test func pinningUpdatesTheRetainedPostAndSurvivesTheEcho() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let id = postID(2)
        try await h.session.setPinned(id, true)
        #expect(h.service.calls.contains("pin"))
        #expect(await h.session.store.post(id)?.isPinned == true)
        // The server echo (newer update_at) carries the same state.
        let echo = h.service.withState { $0.posts[id]! }
        await h.realtime.push(.postEdited(echo))
        #expect(await eventually { await h.session.store.post(id)?.updateAt == echo.updateAt })
        #expect(await h.session.store.post(id)?.isPinned == true)
        try await h.session.setPinned(id, false)
        #expect(h.service.calls.contains("unpin"))
        #expect(await h.session.store.post(id)?.isPinned == false)
        // Another client unpins/pins: the realtime edit wins.
        var remote = h.service.withState { $0.posts[id]! }
        remote.isPinned = true
        remote.updateAt = MattermostTimestamp(milliseconds: remote.updateAt.milliseconds + 10)
        await h.realtime.push(.postEdited(remote))
        #expect(await eventually { await h.session.store.post(id)?.isPinned == true })
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.setPinned(PostID(unchecked: CoreFixtures.id("post", 99)), true)
        }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func savingUsesFlaggedPostPreferencesAndFollowsOtherClients() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let id = postID(1)
        try await h.session.setSaved(id, true)
        let saved = Preference(category: "flagged_post", name: id.rawValue, value: "true")
        #expect(h.service.withState { $0.savedPreferences } == [saved])
        #expect(await h.session.isSaved(id))
        try await h.session.setSaved(id, false)
        #expect(h.service.withState { $0.deletedPreferences } == [saved])
        #expect(await !h.session.isSaved(id))
        let other = postID(3)
        await h.realtime.push(.preferencesChanged([Preference(category: "flagged_post", name: other.rawValue, value: "true")]))
        #expect(await eventually { await h.session.isSaved(other) })
        await h.realtime.push(.preferencesDeleted([Preference(category: "flagged_post", name: other.rawValue, value: "true")]))
        #expect(await eventually { await !h.session.isSaved(other) })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func savedPostsAreBoundedAndLoadedFromPreferences() {
        var budget = ResourceBudget.standard
        budget.savedPostIDs = 2
        var directory = DirectoryStore(budget: budget)
        let preferences = (0..<4).map { Preference(category: "flagged_post", name: CoreFixtures.id("post", $0), value: "true") }
            + [Preference(category: "flagged_post", name: "not a valid id!", value: "true")]
        directory.applyPreferences(preferences, replacing: true)
        #expect(directory.savedPosts.count == 2)
        #expect(directory.savedPostsTruncated)
        directory.apply(preferences[0], deleted: true)
        directory.apply(preferences[3], deleted: false)
        #expect(directory.savedPosts == [PostID(unchecked: CoreFixtures.id("post", 1)), PostID(unchecked: CoreFixtures.id("post", 3))])
        directory.applyPreferences([Preference(category: "display_settings", name: "link_previews", value: "false")], replacing: true)
        #expect(directory.savedPosts.isEmpty && !directory.savedPostsTruncated)
        #expect(!directory.showsLinkPreviews)
    }

    @Test func markAsUnreadHoldsReadStateUntilTheUserScrolls() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let target = TimelineTarget.channel(h.channel.id)
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        await h.session.updateVisibility(target: target, first: postID(0), last: postID(4), atLiveEdge: true)
        #expect(await !h.session.directory.unread(for: h.channel.id, collapsedThreads: false).isUnread)
        let viewedBefore = h.service.withState { $0.viewedChannels.count }

        try await h.session.markUnread(from: postID(3))
        #expect(h.service.withState { $0.unreadMarks } == [postID(3)])
        let unread = await h.session.directory.unread(for: h.channel.id, collapsedThreads: false)
        #expect(unread.isUnread && unread.messages == 2)
        #expect(await h.session.windows[target]?.unreadBoundary == postID(3))
        #expect(await h.session.isHeldUnread(h.channel.id))
        let row = await h.session.sidebarRow(for: h.channel, collapsedThreads: false)
        #expect(row.isUnread, "the open channel shows as unread while held")

        // Content updates, new posts and re-activation do not mark it read again.
        await h.session.updateVisibility(target: target, first: postID(1), last: postID(4), atLiveEdge: true)
        await h.session.updateAppState(isActive: false, isWindowVisible: true)
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        await h.realtime.push(.posted(PostedEvent(post: CoreFixtures.post(7, channel: h.channel.id), channelType: .open,
                                                  teamID: nil, mentionsCurrentUser: false, setOnline: false)))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(h.service.withState { $0.viewedChannels.count } == viewedBefore)
        #expect(await h.session.directory.unread(for: h.channel.id, collapsedThreads: false).isUnread)

        // Scrolling the timeline is the user acting again.
        await h.session.updateVisibility(target: target, first: postID(1), last: postID(7), atLiveEdge: true,
                                         userScrolled: true)
        #expect(await eventually { h.service.withState { $0.viewedChannels.count } > viewedBefore })
        #expect(await !h.session.isHeldUnread(h.channel.id))
        #expect(await eventually { await !h.session.directory.unread(for: h.channel.id, collapsedThreads: false).isUnread })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func openingAnotherChannelOrSendingEndsTheHold() async throws {
        let h = await SessionHarness()
        let other = CoreFixtures.channel(2, total: 0)
        h.service.withState { state in
            state.channels[other.id] = other
            state.memberships[other.id] = ChannelMembership(channelID: other.id, userID: CoreFixtures.me.id)
        }
        await h.session.selectTeam(CoreFixtures.team.id)
        await h.session.loadChannels(team: CoreFixtures.team.id)
        await h.openChannel()
        try await h.session.markUnread(from: postID(2))
        #expect(await h.session.isHeldUnread(h.channel.id))
        await h.session.openChannel(other.id)
        #expect(await !h.session.isHeldUnread(h.channel.id))

        await h.openChannel()
        try await h.session.markUnread(from: postID(2))
        #expect(await h.session.isHeldUnread(h.channel.id))
        _ = await h.send("reply after marking unread")
        #expect(await eventually { await h.session.pending.isEmpty })
        #expect(await !h.session.isHeldUnread(h.channel.id))

        // A failed request releases the hold and reports the error.
        h.service.withState { $0.markUnreadHandler = { _ in throw APIError.forbidden(ServerErrorInfo(id: "", statusCode: 403, requestID: nil)) } }
        await #expect(throws: UserFacingError.permissionDenied) { try await h.session.markUnread(from: postID(2)) }
        #expect(await !h.session.isHeldUnread(h.channel.id))
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func serverLinksResolveOnlyToMemberChannels() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let stored = try await h.session.resolve(.post(team: "qa", postID: postID(1)))
        #expect(stored == .channel(h.channel.id, focusing: postID(1)))
        // Not retained: fetched with GET /posts/{id}.
        let far = CoreFixtures.post(50, channel: h.channel.id)
        h.service.withState { $0.posts[far.id] = far }
        #expect(try await h.session.resolve(.post(team: "qa", postID: far.id)) == .channel(h.channel.id, focusing: far.id))
        // A post in a channel the user is not a member of.
        let foreign = CoreFixtures.post(51, channel: CoreFixtures.channel(9).id)
        h.service.withState { $0.posts[foreign.id] = foreign }
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.resolve(.post(team: "qa", postID: foreign.id))
        }
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.resolve(.post(team: "qa", postID: postID(77)))
        }
        #expect(try await h.session.resolve(.channel(team: "qa", name: h.channel.name)) == .channel(h.channel.id, focusing: nil))
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.resolve(.channel(team: "qa", name: "no-such-channel"))
        }
        #expect(try await h.session.resolve(.directMessage(team: "qa", username: "bob")) == .directMessage(CoreFixtures.bob.id))
        #expect(try await h.session.resolve(.directMessage(team: "qa", username: "alice")) == .directMessage(CoreFixtures.me.id))
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}

@Suite("Timeline builder: reactors, saved, previews, grouping")
struct TimelineBuilderInteractionTests {
    let channel = CoreFixtures.channel(1)
    let carol = User(id: UserID(unchecked: CoreFixtures.id("carol", 1)), username: "carol", firstName: "Carol")

    func build(_ posts: [Post], directory: DirectoryStore? = nil, pending: [PendingSend] = [], proxy: Bool = false,
               thread: Bool = false) -> TimelineBuilder.Output {
        var store = PostStore(render: { CoreFixtures.plainDocuments.document(for: $0) })
        for post in posts { store.upsert(post) }
        let target: TimelineTarget = thread ? .thread(root: posts[0].id, channel: channel.id) : .channel(channel.id)
        var window = HistoryWindow(target: target)
        _ = window.replace(with: posts.map { HistoryWindow.Entry(id: $0.id, createAt: $0.createAt) }, hasOlder: false,
                           hasNewer: false)
        var dir = directory ?? DirectoryStore(budget: .standard)
        if directory == nil {
            dir.pin(CoreFixtures.me)
            dir.upsertUser(CoreFixtures.bob)
        }
        let context = TimelineBuildContext(
            scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id), me: CoreFixtures.me.id, channel: channel,
            teamName: "qa", endpoint: CoreFixtures.endpoint, collapsedThreads: false, editTimeLimitSeconds: nil,
            canDeleteOthers: false, now: MattermostTimestamp(milliseconds: 1_800_000_000_000), collapsedMessageCharacters: 4_000,
            timeZone: TimeZone(secondsFromGMT: 0)!, linkPreviewImages: proxy)
        return TimelineBuilder.build(window: window, store: store, directory: dir, pending: pending, context: context)
    }

    func posts(_ output: TimelineBuilder.Output) -> [PostPresentation] { output.items.compactMap(\.post) }

    @Test func reactionGroupsNameReactorsYouFirstAndReportUnknownUsers() {
        var post = CoreFixtures.post(1, channel: channel.id)
        post.reactions = [
            Reaction(userID: CoreFixtures.bob.id, postID: post.id, emojiName: "+1"),
            Reaction(userID: carol.id, postID: post.id, emojiName: "+1"),
            Reaction(userID: CoreFixtures.me.id, postID: post.id, emojiName: "+1"),
            Reaction(userID: carol.id, postID: post.id, emojiName: "heart"),
        ] + (0..<14).map { Reaction(userID: UserID(unchecked: CoreFixtures.id("u", $0)), postID: post.id, emojiName: "tada") }
        let output = build([post])
        let groups = posts(output)[0].reactions
        #expect(groups.map(\.emojiName) == ["+1", "heart", "tada"])
        #expect(groups[0].reactorNames == ["You", "bob"], "carol is not retained yet")
        #expect(groups[0].count == 3 && groups[0].includesCurrentUser)
        #expect(groups[2].count == 14 && groups[2].reactorNames.isEmpty)
        #expect(output.missingUsers.contains(carol.id))
        #expect(output.missingUsers.count == 1 + ReactionGroup.maximumReactorNames, "at most ten reactors are resolved per emoji")
    }

    @Test func actionsSavedStateAndPreviewsFollowTheDirectoryAndProxy() throws {
        var post = CoreFixtures.post(1, channel: channel.id)
        post.isPinned = true
        post.linkPreview = LinkPreview(kind: .website, link: SafeLink("https://example.com")!, title: "Example",
                                       image: LinkPreview.Image(url: "https://example.com/a.png", width: 10, height: 10))
        var directory = DirectoryStore(budget: .standard)
        directory.pin(CoreFixtures.me)
        directory.apply(Preference(category: "flagged_post", name: post.id.rawValue, value: "true"), deleted: false)
        let plain = try #require(posts(build([post], directory: directory)).first)
        #expect(plain.isSaved && plain.isPinned)
        #expect(plain.actions.canPin && plain.actions.canSave && plain.actions.canMarkUnread)
        #expect(plain.linkPreview?.title == "Example")
        #expect(plain.linkPreview?.image == nil, "no thumbnail without the server's image proxy")
        #expect(posts(build([post], directory: directory, proxy: true)).first?.linkPreview?.image != nil)
        #expect(posts(build([post], directory: directory, thread: true)).first?.actions.canMarkUnread == false)
        directory.apply(Preference(category: "display_settings", name: "link_previews", value: "false"), deleted: false)
        #expect(posts(build([post], directory: directory)).first?.linkPreview == nil)
        var deleted = post
        deleted.deleteAt = MattermostTimestamp(milliseconds: 5)
        let tombstone = try #require(posts(build([deleted], directory: directory)).first)
        #expect(!tombstone.actions.canPin && !tombstone.actions.canSave && tombstone.linkPreview == nil)
    }

    @Test func groupingCollapsesSameAuthorWithinFiveMinutesIncludingPendingSends() throws {
        let base: Int64 = 1_700_000_000_000
        let minute: Int64 = 60_000
        let a = CoreFixtures.post(1, channel: channel.id, user: CoreFixtures.me.id, createAt: base)
        let b = CoreFixtures.post(2, channel: channel.id, user: CoreFixtures.me.id, createAt: base + 4 * minute)
        let c = CoreFixtures.post(3, channel: channel.id, user: CoreFixtures.me.id, createAt: base + 10 * minute)
        let d = CoreFixtures.post(4, channel: channel.id, user: CoreFixtures.bob.id, createAt: base + 11 * minute)
        var hook = CoreFixtures.post(5, channel: channel.id, user: CoreFixtures.bob.id, createAt: base + 12 * minute)
        hook.props.fromWebhook = true
        hook.props.overrideUsername = "CI"
        var edited = CoreFixtures.post(6, channel: channel.id, user: CoreFixtures.bob.id, createAt: base + 13 * minute)
        edited.editAt = MattermostTimestamp(milliseconds: base + 14 * minute)
        let ledger = UnsentWorkLedger(budget: .standard)
        let pending = [base + 15 * minute, base + 16 * minute].enumerated().map { index, at in
            PendingSend(pendingID: PendingPostID(rawValue: "me:\(at)")!, channelID: channel.id, rootID: nil,
                        message: "pending \(index)", attachments: [], createdAt: MattermostTimestamp(milliseconds: at),
                        reservation: try! ledger.convertDraftToPending(nil, bytes: 9))
        }
        let rows = posts(build([a, b, c, d, hook, edited], pending: pending))
        #expect(rows.map(\.isContinuation) == [false, true, false, false, false, false, false, true])
        #expect(rows[5].isEdited && rows[5].editedAt == edited.editAt)
        // A pending send right after the user's own post continues that group.
        let own = CoreFixtures.post(7, channel: channel.id, user: CoreFixtures.me.id, createAt: base + 15 * minute - 1_000)
        let continued = posts(build([a, own], pending: Array(pending.prefix(1))))
        #expect(continued.last?.isContinuation == true)
        for send in pending { ledger.release(send.reservation) }
    }
}
