import Testing
import MatterMacModels
import MattermostAPI
import TestSupport
@testable import MatterMacCore

@Suite("Membership snapshot revocation", .serialized)
struct MembershipSnapshotTests {
    @Test(arguments: ["event", "bulk", "explicit"])
    func staleChannelSnapshotCannotRestoreRevokedMembership(path: String) async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.memberships[h.channel.id] != nil }
        let gate = Gate(), started = Gate()
        let original = h.channel
        h.service.withState { state in
            state.channelHandler = { _ in await started.open(); await gate.wait(); return original }
            state.channelsHandler = { _ in await started.open(); await gate.wait(); return [original] }
        }
        let load: Task<Void, Never>
        if path == "event" {
            await h.session.fetchChannel(original.id)
            load = try #require(await h.session.tasks[.channelFetch(original.id)])
        } else {
            load = Task {
                if path == "bulk" { await h.session.loadChannels(team: CoreFixtures.team.id) }
                else { try? await h.session.loadMemberChannel(original.id) }
            }
        }
        await started.wait()
        await h.session.purgeChannel(original.id, reason: nil)
        await gate.open()
        await load.value
        #expect(await h.session.directory.channels[original.id] == nil)
        #expect(await h.session.directory.memberships[original.id] == nil)
        // A subsequent, fresh membership response is still allowed (rejoin).
        try await h.session.loadMemberChannel(original.id)
        #expect(await h.session.directory.memberships[original.id] != nil)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
