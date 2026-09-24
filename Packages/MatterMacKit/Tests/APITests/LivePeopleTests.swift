import Foundation
import Testing
import MatterMacModels
import MattermostAPI

/// Opt-in only, restricted to the three repository-owned loopback test servers.
/// Every server-side change made here (status, favorite, mute) is restored.
@Suite("Live profiles, members, status and channel settings", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LivePeopleTests {
    enum Failure: Error { case missingCredentials, missingChannel }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func peopleEndpoints(base: String) async throws {
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
        do {
            try await exercise(api, me: me)
        } catch {
            try? await api.setStatus(.online, me: me)
            try? await api.setCustomStatus(nil, duration: "", me: me)
            try? await api.logout()
            await api.shutdown()
            throw error
        }
        try await api.logout()
        await api.shutdown()
    }

    private func exercise(_ api: any MattermostService, me: UserID) async throws {
        let config = try await api.fullConfiguration()
        #expect(["username", "nickname_full_name", "full_name"].contains(config.teammateNameDisplay ?? "missing"))
        let bob = try await api.users(usernames: ["BOB"])
        #expect(bob.map(\.username) == ["bob"])

        guard let team = try await api.teams().first(where: { $0.name == "qa" }),
              let channel = try await api.channels(team: team.id).first(where: { $0.name == "interop" })
        else { throw Failure.missingChannel }
        let members = try await api.channelMembers(channel.id, page: 0, perPage: 60)
        #expect(members.contains { $0.id == me })
        #expect(members.contains { $0.username == "bob" })
        #expect(try await api.channelMembers(channel.id, page: 50, perPage: 60).isEmpty)

        try await api.setStatus(.doNotDisturb, me: me)
        #expect(try await api.statuses(ids: [me])[me] == .doNotDisturb)
        try await api.setStatus(.online, me: me)
        #expect(try await api.statuses(ids: [me])[me] == .online)

        let favorite = Preference(category: "favorite_channel", name: channel.id.rawValue, value: "true")
        try await api.savePreferences([favorite], me: me)
        #expect(try await api.preferences().contains(favorite))
        try await api.deletePreferences([favorite], me: me)
        #expect(!(try await api.preferences().contains(favorite)))

        let away = try await api.executeCommand("/away", channel: channel.id, team: team.id, rootID: nil)
        #expect(away.isEphemeral)
        #expect(!away.text.isEmpty)
        #expect(try await api.statuses(ids: [me])[me] == .away)
        _ = try await api.executeCommand("/online", channel: channel.id, team: team.id, rootID: nil)
        #expect(try await api.statuses(ids: [me])[me] == .online)
        do {
            _ = try await api.executeCommand("/matterMacNoSuchCommand", channel: channel.id, team: team.id, rootID: nil)
            Issue.record("unknown command succeeded")
        } catch {
            guard case .notFound(let info) = error else { Issue.record("unexpected \(error)"); return }
            #expect(info.id == ServerErrorID.commandNotFound)
        }

        let expires = CustomStatusDuration.today.expiry(from: Date(), timeZone: .current)
        try await api.setCustomStatus(CustomStatus(emoji: "palm_tree", text: "MatterMac check", expiresAt: expires),
                                      duration: CustomStatusDuration.today.rawValue, me: me)
        let withStatus = try await api.currentUser()
        #expect(withStatus.customStatus?.emoji == "palm_tree")
        #expect(withStatus.customStatus?.text == "MatterMac check")
        #expect(withStatus.customStatus?.expiresAt != nil)
        try await api.setCustomStatus(nil, duration: "", me: me)
        #expect(try await api.currentUser().customStatus == nil)

        try await api.setChannelMarkUnread(channel.id, level: .mention, me: me)
        #expect(try await api.channelMembership(channel.id).markUnread == .mention)
        try await api.setChannelMarkUnread(channel.id, level: .all, me: me)
        #expect(try await api.channelMembership(channel.id).markUnread == .all)
    }
}
