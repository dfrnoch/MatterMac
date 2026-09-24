import Foundation
import Testing
import MatterMacModels
@testable import MattermostRealtime
import TestSupport

@Suite("Realtime liveness")
struct LivenessTests {
    /// Regression: the periodic ping wrote `socket?.outstandingPing` while evaluating
    /// `sendAction`, which reads `socket` — a runtime exclusivity violation that
    /// aborted the process on the first liveness tick after the handshake.
    @Test func periodicPingsAfterHandshakeDoNotConflict() async throws {
        let transport = FakeWebSocketTransport()
        var configuration = RealtimeConfiguration.standard
        configuration.pingInterval = .milliseconds(20)
        let endpoint = try ServerURLNormalizer.normalize("http://localhost:8065", allowInsecureLoopback: true)
        let client = MattermostRealtimeClient(
            endpoint: endpoint, credential: BearerCredential(token: "tokentokentokentokentoken1", kind: .session)!,
            currentUserID: UserID(unchecked: RealtimeFixtures.aliceID), transport: transport,
            configuration: configuration)
        await client.start()
        let attempt = try #require(await transport.attempt(1))
        let channel = try #require(attempt.channel)
        #expect(await channel.completeNewConnection())
        // Handshake ping plus two periodic liveness pings, each answered.
        let second = try #require(await channel.waitForAction("ping", occurrence: 2))
        channel.replyOK(to: second.seq)
        #expect(await channel.waitForAction("ping", occurrence: 3) != nil)
        await client.stop()
    }
}
