import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

@Suite("Notification policy")
struct NotificationPolicyTests {
    private let channel = CoreFixtures.channel(1)

    private func kind(_ message: String = "hello", type: ChannelType = .open, serverMentioned: Bool = false,
                      desktop: ChannelDesktopLevel = .default, muted: Bool = false,
                      ignore: IgnoreChannelMentions = .default, account: [String: String] = [:],
                      crt: Bool = false, reply: Bool = false, follower: Bool = false, postType: PostType = .normal) -> IncomingMessageAlert.Kind? {
        var post = CoreFixtures.post(1, channel: channel.id, message: message,
                                     rootID: reply ? PostID(unchecked: CoreFixtures.id("root", 1)) : nil)
        post.type = postType
        let member = ChannelMembership(channelID: channel.id, userID: CoreFixtures.me.id,
                                       markUnread: muted ? .mention : .all, desktop: desktop, ignoreChannelMentions: ignore)
        var props = UserNotifyProps.serverDefault.values
        props.merge(account) { $1 }
        return NotificationPolicy.kind(for: .init(
            post: post, channelType: type, serverMentioned: serverMentioned, membership: member,
            account: UserNotifyProps(values: props), username: "alice", firstName: "Alice", collapsedThreads: crt,
            notifiesThreadFollower: follower))
    }

    @Test func directMessagesNotifyUnlessNothingOrMuted() {
        #expect(kind(type: .direct) == .directMessage)
        #expect(kind(type: .direct, account: ["desktop": "mention"]) == .directMessage)
        #expect(kind(type: .direct, desktop: .nothing) == nil)
        #expect(kind(type: .direct, account: ["desktop": "none"]) == nil)
        #expect(kind(type: .direct, muted: true) == nil)
        #expect(kind(type: .direct, serverMentioned: true) == .mention)
    }

    @Test func groupMessagesDefaultToAllButHonorAnExplicitMentionLevel() {
        #expect(kind(type: .group) == .directMessage)
        #expect(kind(type: .group, desktop: .mention) == nil)
        #expect(kind("@alice look", type: .group, desktop: .mention) == .mention)
        #expect(kind(type: .group, account: ["desktop": "none"]) == nil)
    }

    @Test func channelLevelsResolveDefaultToTheAccount() {
        #expect(kind() == nil)
        #expect(kind(serverMentioned: true) == .mention)
        #expect(kind(account: ["desktop": "all"]) == .channelMessage)
        #expect(kind(desktop: .all, account: ["desktop": "none"]) == .channelMessage)
        #expect(kind(desktop: .mention, account: ["desktop": "all"]) == nil)
        #expect(kind(serverMentioned: true, desktop: .nothing) == nil)
        #expect(kind(serverMentioned: true, muted: true) == nil)
        #expect(kind(postType: .joinChannel) == nil)
    }

    @Test func clientSideKeywordsAndChannelWideMentions() {
        #expect(kind("Deploy now", account: ["mention_keys": "deploy"]) == .mention)
        #expect(kind("thanks Alice", account: ["first_name": "true"]) == .mention)
        #expect(kind("thanks Alice") == nil)
        #expect(kind("@channel standup") == .mention)
        #expect(kind("@here standup", ignore: .on) == nil)
        #expect(kind("@all standup", account: ["channel": "false"]) == nil)
        // "off" cannot re-enable what the account turned off (server rule).
        #expect(kind("@all standup", ignore: .off, account: ["channel": "false"]) == nil)
    }

    @Test func collapsedThreadRepliesNotifyOnlyForMentionsInChannels() {
        #expect(kind(account: ["desktop": "all"], crt: true, reply: true) == nil)
        #expect(kind("@alice", account: ["desktop": "all"], crt: true, reply: true) == .mention)
        #expect(kind(account: ["desktop": "all"], crt: false, reply: true) == .channelMessage)
        #expect(kind(type: .direct, crt: true, reply: true) == .directMessage)
    }

    @Test func serverEligibleFollowersNotifyWithoutCreatingMentions() {
        #expect(kind(crt: true, reply: true, follower: true) == .channelMessage)
        #expect(kind(desktop: .all, crt: true, reply: true, follower: true) == .channelMessage)
        #expect(kind(desktop: .nothing, crt: true, reply: true, follower: true) == nil)
        #expect(kind(muted: true, crt: true, reply: true, follower: true) == nil)
        #expect(kind(account: ["desktop": "none"], crt: true, reply: true, follower: true) == nil)
        #expect(kind(crt: false, reply: true, follower: true) == nil)
        #expect(kind(crt: true, reply: false, follower: true) == nil)
        #expect(kind(serverMentioned: true, crt: true, reply: true, follower: true) == .mention)
    }

    @Test func previewsAreShortWhitespaceCollapsedPlainText() {
        let short = MessageDocument(blocks: [.paragraph([.text("hi\n\n  there")])])
        #expect(NotificationPolicy.preview(of: short) == "hi there")
        let long = MessageDocument(blocks: [.paragraph([.text(String(repeating: "word ", count: 60))])])
        let preview = NotificationPolicy.preview(of: long) ?? ""
        #expect(preview.count == IncomingMessageAlert.previewCharacters + 1)
        #expect(preview.hasSuffix("…"))
        #expect(NotificationPolicy.preview(of: .empty) == nil)
    }
}

@Suite("Server notification and display preferences", .serialized)
struct NotificationPreferenceSessionTests {
    private static let account = UserNotifyProps(values: [
        "desktop": "mention", "desktop_sound": "true", "mention_keys": "", "first_name": "false", "channel": "true",
        "push": "mention", "email": "true",
    ])

    private func signedIn(collapsedThreads: String = "disabled") async -> SessionHarness {
        let h = await SessionHarness(collapsedThreads: collapsedThreads)
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        var me = CoreFixtures.me
        me.notifyProps = Self.account
        let signedIn = me
        h.service.withState { $0.me = signedIn }
        await h.realtime.push(.userUpdated(me))
        _ = await eventually { await h.session.me.notifyProps != nil }
        return h
    }

    private func post(_ h: SessionHarness, _ n: Int, _ message: String, mention: Bool = false) async {
        let post = CoreFixtures.post(n, channel: h.channel.id, user: CoreFixtures.bob.id, message: message)
        await h.realtime.push(.posted(PostedEvent(post: post, channelType: .open, teamID: CoreFixtures.team.id,
                                                  mentionsCurrentUser: mention, setOnline: true)))
    }

    @Test func alertsFollowAccountAndChannelLevelsAndCarryPreviewsOnlyWhenEnabled() async throws {
        let h = await signedIn()
        var alerts = h.session.alerts.makeAsyncIterator()
        await h.session.updateAppState(isActive: false, isWindowVisible: true)

        // Account level "all" via the user's own update: a plain post notifies, without text.
        var me = await h.session.me
        me.notifyProps?.desktop = .all
        me.notifyProps?.desktopSound = false
        await h.realtime.push(.userUpdated(me))
        await post(h, 80, "plain secret text")
        let first = try #require(await alerts.next())
        #expect(first.kind == .channelMessage)
        #expect(first.preview == nil)
        #expect(!first.soundEnabled)
        #expect(!String(describing: first).contains("secret"))

        // A sanitized copy of ourselves (no notify props) keeps the known ones.
        var sanitized = me
        sanitized.notifyProps = nil
        await h.realtime.push(.userUpdated(sanitized))
        _ = await eventually { await h.realtime.queuedCount == 0 }
        #expect(await h.session.me.notifyProps?.desktop == .all)

        // The channel overrides the account: "nothing" suppresses even mentions.
        var member = try #require(await h.session.directory.memberships[h.channel.id])
        member.desktop = .nothing
        await h.realtime.push(.channelMemberUpdated(member))
        await post(h, 81, "@alice suppressed", mention: true)
        member.desktop = .mention
        await h.realtime.push(.channelMemberUpdated(member))
        await post(h, 82, "plain suppressed")
        await h.session.setAlertPreviews(true)
        await post(h, 83, "@alice   please\nreview", mention: true)
        let second = try #require(await alerts.next())
        #expect(second.kind == .mention)
        #expect(second.preview == "@alice please review")
        await h.session.setAlertPreviews(false)
        await post(h, 84, "@alice again", mention: true)
        let third = try #require(await alerts.next())
        #expect(third.preview == nil)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func followedReplyNotifiesInActiveChannelButNotOpenOrReadThread() async throws {
        let h = await signedIn(collapsedThreads: "always_on")
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        var alerts = h.session.alerts.makeAsyncIterator()
        let root = CoreFixtures.post(1, channel: h.channel.id).id
        let reply = CoreFixtures.post(95, channel: h.channel.id, user: CoreFixtures.bob.id, rootID: root)
        let event = PostedEvent(post: reply, channelType: .open, teamID: CoreFixtures.team.id,
                                mentionsCurrentUser: false, setOnline: true, notifiesCurrentThreadFollower: true)
        await h.session.testThreadAlert(event, open: true, read: false)
        await h.session.testThreadAlert(event, open: false, read: true)
        await h.session.testThreadAlert(event, open: false, read: false)
        let alert = try #require(await alerts.next())
        #expect(alert.rootID == root)
        #expect(alert.kind == .channelMessage)
        _ = await h.session.shutdown(revokeServerSession: false)
        #expect(await alerts.next() == nil)
    }

    @Test func accountNotificationChangesSendTheCompleteMap() async throws {
        let h = await signedIn()
        var updates = h.session.accountSettingsUpdates.makeAsyncIterator()
        try await h.session.updateAccountNotifications { props in
            props.desktop = .all
            props.mentionKeys = ["Deploy", "ship"]
            props.firstNameMentions = true
        }
        let sent = try #require(h.service.withState { $0.patchedNotifyProps.last })
        #expect(sent.values["push"] == "mention")
        #expect(sent.values["email"] == "true")
        #expect(sent.values["desktop"] == "all")
        #expect(sent.values["mention_keys"] == "deploy,ship")
        #expect(sent.values["first_name"] == "true")
        #expect(await h.session.me.notifyProps == sent)
        var snapshot = try #require(await updates.next())
        while snapshot.notifications != sent { snapshot = try #require(await updates.next()) }
        #expect(snapshot.canEditNotifications)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func incompleteOrUnknownAccountPropsAreNeverWritten() async throws {
        let h = await SessionHarness()
        await #expect(throws: UserFacingError.unsupportedCapability("notify_props")) {
            try await h.session.updateAccountNotifications { $0.desktop = .all }
        }
        var me = CoreFixtures.me
        me.notifyProps = UserNotifyProps(values: ["desktop": "mention"], isComplete: false)
        await h.realtime.push(.userUpdated(me))
        _ = await eventually { await h.session.me.notifyProps != nil }
        await #expect(throws: UserFacingError.unsupportedCapability("notify_props")) {
            try await h.session.updateAccountNotifications { $0.desktop = .all }
        }
        #expect(!h.service.calls.contains("patchNotifyProps"))
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func channelPreferencesSendOnlyChangedKeys() async throws {
        let h = await signedIn()
        let initial = try await h.session.channelNotificationPreferences(h.channel.id)
        #expect(initial.desktop == .default && !initial.isMuted && initial.ignoreChannelMentions == .default)
        #expect(initial.accountDesktop == .mention && !initial.ignoresChannelWideMentions)
        try await h.session.setChannelNotificationPreferences(h.channel.id, desktop: .default, muted: false,
                                                              ignoreChannelMentions: .default)
        #expect(!h.service.calls.contains("updateChannelNotifyProps"))
        try await h.session.setChannelNotificationPreferences(h.channel.id, desktop: .all, muted: true,
                                                              ignoreChannelMentions: .default)
        let change = try #require(h.service.withState { $0.channelNotifyChanges.last })
        #expect(change.0 == h.channel.id)
        #expect(change.1 == ChannelNotifyPropsChange(desktop: .all, markUnread: .mention))
        let updated = try await h.session.channelNotificationPreferences(h.channel.id)
        #expect(updated.desktop == .all && updated.isMuted)
        #expect(await h.session.directory.memberships[h.channel.id]?.markUnread == .mention)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func displayPreferencesAreExplicitServerChanges() async throws {
        let h = await signedIn()
        var updates = h.session.accountSettingsUpdates.makeAsyncIterator()
        let before = await h.session.accountSettings()
        #expect(before.display.militaryTime == nil)
        #expect(!before.display.canChangeCollapsedThreads)
        try await h.session.setMilitaryTime(true)
        try await h.session.setNameFormat(.fullName)
        #expect(h.service.withState { $0.savedPreferences } == [
            Preference(category: "display_settings", name: "use_military_time", value: "true"),
            Preference(category: "display_settings", name: "name_format", value: "full_name"),
        ])
        var snapshot = try #require(await updates.next())
        while snapshot.display.nameFormat != .fullName { snapshot = try #require(await updates.next()) }
        #expect(snapshot.display.militaryTime == true)
        await #expect(throws: UserFacingError.unsupportedCapability("collapsed_reply_threads")) {
            try await h.session.setCollapsedThreads(true)
        }
        // Another client's change arrives as a realtime event.
        await h.realtime.push(.preferencesChanged([Preference(category: "display_settings", name: "use_military_time",
                                                              value: "false")]))
        _ = await eventually { await h.session.accountSettings().display.militaryTime == false }
        #expect(await h.session.accountSettings().display.militaryTime == false)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func turningCollapsedThreadsOnReloadsTheVisibleChannel() async throws {
        let h = await signedIn(collapsedThreads: "default_off")
        await h.openChannel()
        let reply = CoreFixtures.post(70, channel: h.channel.id, user: CoreFixtures.bob.id, message: "reply",
                                      rootID: CoreFixtures.post(0, channel: h.channel.id).id)
        h.service.withState { $0.posts[reply.id] = reply }
        await h.realtime.push(.posted(PostedEvent(post: reply, channelType: .open, teamID: CoreFixtures.team.id,
                                                  mentionsCurrentUser: false, setOnline: true)))
        #expect(await eventually { await h.windowIDs().contains(reply.id) })
        #expect(await h.session.accountSettings().display.canChangeCollapsedThreads)
        let pageLoads = h.service.calls.filter { $0 == "posts" }.count
        try await h.session.setCollapsedThreads(true)
        #expect(await h.session.collapsedThreadsActive)
        #expect(await eventually { h.service.calls.filter { $0 == "posts" }.count > pageLoads })
        #expect(await eventually {
            let ids = await h.windowIDs()
            return !ids.contains(reply.id) && !ids.isEmpty
        })
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}

private extension ServerSession {
    func testThreadAlert(_ event: PostedEvent, open: Bool, read: Bool) {
        let root = event.post.rootID!
        activeChannel = event.post.channelID
        openThread = open ? .thread(root: root, channel: event.post.channelID) : nil
        threadReadMark = read ? (root, event.post.createAt) : nil
        alertIfNeeded(event)
    }
}
