import Foundation
import Testing
import MatterMacModels
import MattermostAPI

/// Opt-in only, restricted to the three repository-owned loopback test servers, as
/// user alice. Every server-side change (account notify props, one channel member's
/// notify props, one display preference) is restored, also when a check fails.
@Suite("Live notification and display preferences", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveNotificationPreferencesTests {
    enum Failure: Error { case missingCredentials, missingChannel, missingNotifyProps }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func notificationPreferencesRoundTrip(base: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_ALICE_PASSWORD"] else {
            throw Failure.missingCredentials
        }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let login: LoginResult
        do { login = try await discovery.login(LoginRequest(loginID: "alice", password: password)) } catch {
            await discovery.shutdown()
            throw error
        }
        await discovery.shutdown()
        let api = factory.service(for: endpoint, credential: login.credential)
        let me = login.user.id
        guard let original = try await api.currentUser().notifyProps, original.isComplete else {
            try? await api.logout()
            await api.shutdown()
            throw Failure.missingNotifyProps
        }
        guard let team = try await api.teams().first(where: { $0.name == "qa" }),
              let channel = try await api.channels(team: team.id).first(where: { $0.name == "interop" })
        else {
            try? await api.logout()
            await api.shutdown()
            throw Failure.missingChannel
        }
        let member = try await api.channelMembership(channel.id)
        let clock = try await api.preferences().first { $0.category == "display_settings" && $0.name == "use_military_time" }
        do {
            try await exercise(api, me: me, original: original, channel: channel.id, member: member, clock: clock)
        } catch {
            await restore(api, me: me, original: original, channel: channel.id, member: member, clock: clock)
            try? await api.logout()
            await api.shutdown()
            throw error
        }
        await restore(api, me: me, original: original, channel: channel.id, member: member, clock: clock)
        #expect(try await api.currentUser().notifyProps == original)
        let restoredMember = try await api.channelMembership(channel.id)
        #expect(restoredMember.desktop == member.desktop)
        #expect(restoredMember.ignoreChannelMentions == member.ignoreChannelMentions)
        #expect(restoredMember.markUnread == member.markUnread)
        try await api.logout()
        await api.shutdown()
    }

    private func exercise(_ api: any MattermostService, me: UserID, original: UserNotifyProps, channel: ChannelID,
                          member: ChannelMembership, clock: Preference?) async throws {
        // Account: the complete map goes back with only these keys changed.
        var changed = original
        changed.desktop = original.desktop == .all ? .mention : .all
        changed.desktopSound = !original.desktopSound
        changed.mentionKeys = ["mattermac-check", "Release"]
        changed.firstNameMentions = !original.firstNameMentions
        let returned = try await api.patchNotifyProps(changed, me: me)
        #expect(returned.id == me)
        let reread = try #require(try await api.currentUser().notifyProps)
        #expect(reread.desktop == changed.desktop)
        #expect(reread.desktopSound == changed.desktopSound)
        #expect(reread.firstNameMentions == changed.firstNameMentions)
        #expect(reread.mentionKeys == ["mattermac-check", "release"])
        for key in original.values.keys where !["desktop", "desktop_sound", "mention_keys", "first_name"].contains(key) {
            #expect(reread.values[key] == original.values[key], "\(key) must be unchanged")
        }

        // Channel: only the sent keys change on the member.
        try await api.updateChannelNotifyProps(channel, ChannelNotifyPropsChange(desktop: .nothing, ignoreChannelMentions: .on),
                                               me: me)
        let updated = try await api.channelMembership(channel)
        #expect(updated.desktop == ChannelDesktopLevel.nothing)
        #expect(updated.ignoreChannelMentions == .on)
        #expect(updated.markUnread == member.markUnread)

        // Display preference: an explicit, restorable server change.
        let value = clock?.value == "true" ? "false" : "true"
        try await api.savePreferences([Preference(category: "display_settings", name: "use_military_time", value: value)], me: me)
        #expect(try await api.preferences().contains(Preference(category: "display_settings", name: "use_military_time",
                                                                value: value)))
    }

    private func restore(_ api: any MattermostService, me: UserID, original: UserNotifyProps, channel: ChannelID,
                         member: ChannelMembership, clock: Preference?) async {
        _ = try? await api.patchNotifyProps(original, me: me)
        try? await api.updateChannelNotifyProps(channel, ChannelNotifyPropsChange(
            desktop: member.desktop, markUnread: member.markUnread, ignoreChannelMentions: member.ignoreChannelMentions), me: me)
        let current = Preference(category: "display_settings", name: "use_military_time", value: clock?.value ?? "")
        if let clock { try? await api.savePreferences([clock], me: me) } else { try? await api.deletePreferences([current], me: me) }
    }
}
