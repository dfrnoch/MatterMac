import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

@Suite("Profiles, channel details and explicit settings", .serialized)
struct PeopleTests {
    private func ready(_ h: SessionHarness) async {
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
    }

    @Test func profileByUsernameRefreshesPresenceAndIgnoresSpecialMentions() async {
        let h = await SessionHarness()
        await ready(h)
        h.service.withState { $0.statuses[CoreFixtures.bob.id] = .doNotDisturb }
        let profile = await h.session.profile(username: "Bob")
        #expect(profile?.user.id == CoreFixtures.bob.id)
        #expect(profile?.status == .doNotDisturb)
        #expect(profile?.isCurrentUser == false)
        #expect(await h.session.profile(username: "here") == nil)
        #expect(await h.session.profile(username: "alice")?.isCurrentUser == true)
        #expect(h.service.calls.filter { $0 == "usernames" }.count == 1)
    }

    @Test func channelDetailsReflectFavoritesMuteAndLeaveRules() async throws {
        let h = await SessionHarness()
        await ready(h)
        var details = try await h.session.channelDetails(h.channel.id)
        #expect(details.memberCount == 3)
        #expect(details.canLeave)
        #expect(!details.isFavorite)
        #expect(details.link?.absoluteString == "https://chat.example.test/company/chat/qa/channels/channel-1")

        try await h.session.setFavorite(h.channel.id, true)
        try await h.session.setMuted(h.channel.id, true)
        details = try await h.session.channelDetails(h.channel.id)
        #expect(details.isFavorite)
        #expect(details.isMuted)
        #expect(h.service.withState { $0.savedPreferences }
            == [Preference(category: "favorite_channel", name: h.channel.id.rawValue, value: "true")])
        #expect(h.service.withState { $0.memberships[h.channel.id]?.markUnread } == .mention)

        try await h.session.setFavorite(h.channel.id, false)
        #expect(try await h.session.channelDetails(h.channel.id).isFavorite == false)
        #expect(h.service.withState { $0.deletedPreferences.count } == 1)
    }

    @Test func channelMembersArePagedWithPresence() async throws {
        let h = await SessionHarness()
        await ready(h)
        h.service.withState { state in
            for n in 0..<70 {
                let user = User(id: UserID(unchecked: CoreFixtures.id("member", n)), username: String(format: "member%02d", n))
                state.users[user.id] = user
            }
        }
        let total = h.service.withState { $0.users.count }
        let first = try await h.session.channelMembers(h.channel.id, page: 0)
        #expect(first.members.count == ServerSession.channelMembersPageSize)
        #expect(first.hasMore)
        #expect(first.members.allSatisfy { $0.status == .online })
        let second = try await h.session.channelMembers(h.channel.id, page: 1)
        #expect(second.members.count == total - ServerSession.channelMembersPageSize)
        #expect(!second.hasMore)
        #expect(Set(first.members.map(\.userID)).isDisjoint(with: second.members.map(\.userID)))
    }

    @Test func ownStatusIsSetOnServerAndPublishedInSidebar() async throws {
        let h = await SessionHarness()
        await ready(h)
        try await h.session.setOwnStatus(.away)
        #expect(h.service.withState { $0.statuses[CoreFixtures.me.id] } == .away)
        #expect(await h.session.directory.status(of: CoreFixtures.me.id) == .away)
        await #expect(throws: UserFacingError.self) { try await h.session.setOwnStatus(.unknown) }
    }

    @Test func channelMentionResolvesOnlyMemberChannelsOnSelectedTeam() async {
        let h = await SessionHarness()
        await ready(h)
        _ = await eventually { await h.session.selectedTeam != nil }
        #expect(await h.session.memberChannel(named: "Channel-1") == h.channel.id)
        #expect(await h.session.memberChannel(named: "unknown") == nil)
    }

    @Test func detailsFailAfterSessionShutdown() async {
        let h = await SessionHarness()
        await ready(h)
        _ = await h.session.shutdown(revokeServerSession: false)
        await #expect(throws: UserFacingError.authenticationRequired) { try await h.session.channelDetails(h.channel.id) }
        #expect(await h.session.profile(username: "bob") == nil)
    }
}

@Suite("Slash commands", .serialized)
struct SlashCommandTests {
    @Test func detectsCommandsAndLeadingSpaceEscape() {
        #expect(ServerSession.isSlashCommand("/away"))
        #expect(!ServerSession.isSlashCommand(" /away"))
        #expect(!ServerSession.isSlashCommand("/"))
        #expect(!ServerSession.isSlashCommand("hello /away"))
    }

    @Test func executesInChannelContextAndMapsFailures() async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        h.service.withState { state in
            state.commandHandler = { command in
                switch command {
                case "/away": return CommandResult(isEphemeral: true, text: "You are now away", gotoLocation: nil)
                case "/lost": throw APIError.outcomeUnknown(.connectionLost)
                default: throw APIError.notFound(ServerErrorInfo(id: ServerErrorID.commandNotFound, statusCode: 404, requestID: nil))
                }
            }
        }
        let result = try await h.session.executeCommand("/away  ", channel: h.channel.id, rootID: nil)
        #expect(result.text == "You are now away")
        #expect(h.service.withState { $0.executedCommands } == ["/away"])
        await #expect(throws: UserFacingError.commandNotFound) {
            try await h.session.executeCommand("/nope", channel: h.channel.id, rootID: nil)
        }
        await #expect(throws: UserFacingError.commandOutcomeUnknown) {
            try await h.session.executeCommand("/lost", channel: h.channel.id, rootID: nil)
        }
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.executeCommand("/away", channel: ChannelID(unchecked: CoreFixtures.id("gone", 1)), rootID: nil)
        }
    }
}

@Suite("Teammate name display")
struct NameDisplayTests {
    @Test func serverDefaultPreferenceAndLockResolveLikeTheOfficialClient() {
        var directory = DirectoryStore(budget: .standard)
        let user = User(id: UserID(unchecked: CoreFixtures.id("u", 1)), username: "jordan.q", firstName: "Jordan",
                        lastName: "Quill", nickname: "Jo")
        #expect(directory.nameFormat.displayName(for: user) == "jordan.q")
        directory.serverNameFormat = .fullName
        #expect(directory.nameFormat.displayName(for: user) == "Jordan Quill")
        directory.apply(Preference(category: "display_settings", name: "name_format", value: "nickname_full_name"),
                        deleted: false)
        #expect(directory.nameFormat.displayName(for: user) == "Jo")
        directory.isNameFormatLocked = true
        #expect(directory.nameFormat.displayName(for: user) == "Jordan Quill")
        directory.isNameFormatLocked = false
        directory.applyPreferences([], replacing: true)
        #expect(directory.nameFormat == .fullName)
    }
}

@Suite("Incoming message alerts", .serialized)
struct IncomingAlertTests {
    /// Pushes an event and waits until the session has consumed it.
    private func deliver(_ h: SessionHarness, _ post: Post, type: ChannelType, mention: Bool = false) async {
        await h.realtime.push(.posted(PostedEvent(post: post, channelType: type, teamID: type.isDirectOrGroup ? nil : CoreFixtures.team.id,
                                                  mentionsCurrentUser: mention, setOnline: true)))
        _ = await eventually { await h.realtime.queuedCount == 0 }
        // The consumer dequeues before handling; give the actor a moment to finish.
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func next(_ iterator: inout AsyncStream<IncomingMessageAlert>.Iterator) async -> IncomingMessageAlert? {
        await iterator.next()
    }

    @Test func mentionsAndDirectMessagesAlertWithoutContent() async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        var alerts = h.session.alerts.makeAsyncIterator()
        // Not looking at the channel: a mention alerts.
        await h.session.updateAppState(isActive: false, isWindowVisible: true)
        let mention = CoreFixtures.post(90, channel: h.channel.id, user: CoreFixtures.bob.id, message: "@alice secret text")
        await h.realtime.push(.posted(PostedEvent(post: mention, channelType: .open, teamID: CoreFixtures.team.id,
                                                  mentionsCurrentUser: true, setOnline: true)))
        let first = try #require(await next(&alerts))
        #expect(first.kind == .mention)
        #expect(first.channelID == h.channel.id)
        #expect(first.senderName == "bob")
        #expect(!String(describing: first).contains("secret"))

        // A direct message from bob in a new DM.
        let dm = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", 1)), teamID: nil, type: .direct,
                         name: [CoreFixtures.me.id.rawValue, CoreFixtures.bob.id.rawValue].sorted().joined(separator: "__"),
                         displayName: "")
        h.service.withState { state in
            state.channels[dm.id] = dm
            state.memberships[dm.id] = ChannelMembership(channelID: dm.id, userID: CoreFixtures.me.id)
        }
        await h.realtime.push(.directAdded(channelID: dm.id))
        _ = await eventually { await h.session.directory.channels[dm.id] != nil }
        let direct = CoreFixtures.post(91, channel: dm.id, user: CoreFixtures.bob.id, message: "hi")
        await h.realtime.push(.posted(PostedEvent(post: direct, channelType: .direct, teamID: nil,
                                                  mentionsCurrentUser: false, setOnline: true)))
        let second = try #require(await next(&alerts))
        #expect(second.kind == .directMessage)
        #expect(second.channelName == "bob")

        // Suppressed: own posts, plain channel posts, Do Not Disturb, visible conversation.
        let own = CoreFixtures.post(92, channel: dm.id, user: CoreFixtures.me.id, message: "mine")
        await deliver(h, own, type: .direct)
        let plain = CoreFixtures.post(93, channel: h.channel.id, user: CoreFixtures.bob.id, message: "plain")
        await deliver(h, plain, type: .open)
        try await h.session.setOwnStatus(.doNotDisturb)
        let quiet = CoreFixtures.post(94, channel: dm.id, user: CoreFixtures.bob.id, message: "quiet")
        await deliver(h, quiet, type: .direct)
        try await h.session.setOwnStatus(.online)
        await h.session.openChannel(dm.id)
        await h.session.updateAppState(isActive: true, isWindowVisible: true)
        let visible = CoreFixtures.post(95, channel: dm.id, user: CoreFixtures.bob.id, message: "visible")
        await deliver(h, visible, type: .direct)
        // A final alert proves the suppressed ones were never queued before it.
        await h.session.updateAppState(isActive: false, isWindowVisible: true)
        let last = CoreFixtures.post(96, channel: dm.id, user: CoreFixtures.bob.id, message: "last")
        await h.realtime.push(.posted(PostedEvent(post: last, channelType: .direct, teamID: nil,
                                                  mentionsCurrentUser: false, setOnline: true)))
        let third = try #require(await next(&alerts))
        #expect(third.kind == .directMessage && third.channelID == dm.id)
        _ = await h.session.shutdown(revokeServerSession: false)
        #expect(await next(&alerts) == nil)
    }
}

@Suite("Custom status")
struct CustomStatusTests {
    @Test func durationsExpireInTheUsersTimeZone() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Prague"))
        // 2026-09-24 10:00 in Prague (a Thursday).
        let now = Date(timeIntervalSince1970: 1_790_236_800)
        #expect(CustomStatusDuration.dontClear.expiry(from: now, timeZone: zone) == nil)
        #expect(CustomStatusDuration.oneHour.expiry(from: now, timeZone: zone) == now.addingTimeInterval(3_600))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = try #require(CustomStatusDuration.today.expiry(from: now, timeZone: zone))
        #expect(calendar.component(.hour, from: today) == 23 && calendar.component(.minute, from: today) == 59)
        #expect(calendar.isDate(today, inSameDayAs: now))
        let week = try #require(CustomStatusDuration.thisWeek.expiry(from: now, timeZone: zone))
        #expect(week > today)
    }

    @Test func setAndClearUpdateTheSidebar() async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        try await h.session.setCustomStatus(emoji: ":palm_tree:", text: " Away ", duration: .dontClear)
        #expect(await h.session.me.customStatus == CustomStatus(emoji: "palm_tree", text: "Away", expiresAt: nil))
        try await h.session.setCustomStatus(emoji: "", text: "", duration: .dontClear)
        #expect(await h.session.me.customStatus == nil)
        #expect(h.service.calls.filter { $0 == "setCustomStatus" }.count == 2)
    }
}

@Suite("Channel editing")
struct ChannelEditingTests {
    @Test func patchesOnlyChangedFieldsAndEnforcesLimits() async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        try await h.session.updateChannel(h.channel.id, displayName: "Renamed", header: h.channel.header, purpose: "New purpose")
        #expect(await h.session.directory.channels[h.channel.id]?.displayName == "Renamed")
        #expect(await h.session.directory.channels[h.channel.id]?.purpose == "New purpose")
        await #expect(throws: UserFacingError.messageTooLong(limitCharacters: 250)) {
            try await h.session.updateChannel(h.channel.id, displayName: nil, header: nil,
                                              purpose: String(repeating: "x", count: 251))
        }
        await #expect(throws: UserFacingError.self) {
            try await h.session.updateChannel(h.channel.id, displayName: "  ", header: nil, purpose: nil)
        }
    }
}

@Suite("Mark as read")
struct MarkReadTests {
    @Test func marksOnlyUnreadChannelsWithoutViewing() async throws {
        let h = await SessionHarness(unread: true)
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        #expect(await h.session.directory.unread(for: h.channel.id, collapsedThreads: false).isUnread)
        try await h.session.markChannelsRead(nil)
        #expect(await h.session.directory.unread(for: h.channel.id, collapsedThreads: false).isUnread == false)
        #expect(h.service.calls.contains("markChannelsRead"))
        #expect(!h.service.withState { $0.viewedChannels }.contains(h.channel.id))
        // Nothing unread: no request.
        let before = h.service.calls.filter { $0 == "markChannelsRead" }.count
        try await h.session.markChannelsRead([h.channel.id])
        #expect(h.service.calls.filter { $0 == "markChannelsRead" }.count == before)
    }
}
