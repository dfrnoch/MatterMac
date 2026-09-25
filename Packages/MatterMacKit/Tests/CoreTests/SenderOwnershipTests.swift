import Foundation
import Testing
import MatterMacModels
import MattermostAPI
import TestSupport
@testable import MatterMacCore

@Suite("Sender operation ownership")
struct SenderOwnershipTests {
    private func enqueue(_ text: String, channel: ChannelID, in h: SessionHarness) async throws -> PendingPostID {
        let reservation = try h.unsent.convertDraftToPending(nil, bytes: text.utf8.count)
        return try await h.session.enqueueSend(text: text, channel: channel, rootID: nil,
                                               attachments: [], reservation: reservation)
    }

    @Test(arguments: [false, true])
    func revocationCancelsOnlyTheCurrentlyExecutingSend(revokeCurrent: Bool) async throws {
        let clock = TestClock()
        let other = CoreFixtures.channel(2, total: 0)
        let h = await SessionHarness(clock: clock, configure: { state in
            state.channels[other.id] = other
            state.memberships[other.id] = ChannelMembership(channelID: other.id, userID: CoreFixtures.me.id)
        })
        await h.openChannel()
        let gate = Gate()
        let service = h.service, firstChannel = h.channel.id
        service.withState { state in
            state.createPostHandler = { outgoing, _ in
                if outgoing.channelID == firstChannel { throw APIError.rateLimited(retryAfterSeconds: 10) }
                await gate.wait() // Model a reply arriving even after cancellation.
                return service.storeCreated(outgoing)
            }
        }
        let first = try await enqueue("retry waiting", channel: firstChannel, in: h)
        #expect(await eventually { await h.session.isRunning(.sendRetry(first)) })
        let second = try await enqueue("current send", channel: other.id, in: h)
        #expect(await eventually { await h.session.pending.item(second)?.state == .sending })
        #expect(await h.session.activeSendID == second)
        let sender = try #require(await h.session.tasks[.sender])
        await h.session.purgeChannel(revokeCurrent ? other.id : firstChannel, reason: nil)
        #expect(sender.isCancelled == revokeCurrent)
        await gate.open()
        await sender.value
        if revokeCurrent {
            #expect(await h.session.pending.item(second)?.state == .outcomeUnknown)
            #expect(await h.session.pending.item(second)?.message == "current send")
            #expect(h.unsent.usage.pendingOperations == 2)
        } else {
            #expect(await h.session.pending.item(second) == nil)
            #expect(await h.session.pending.item(first) != nil)
            #expect(h.unsent.usage.pendingOperations == 1)
        }
        #expect(await h.session.activeSendID == nil)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func manualRetryCannotBeRequeuedByItsOlderAutomaticRetry() async throws {
        let clock = TestClock()
        let h = await SessionHarness(clock: clock)
        await h.openChannel()
        let gate = Gate(), service = h.service
        service.withState { state in
            state.createPostHandler = { outgoing, attempt in
                if attempt == 1 { throw APIError.outcomeUnknown(.timedOut) }
                await gate.wait()
                return service.storeCreated(outgoing)
            }
        }
        let id = try await enqueue("preserve during retry", channel: h.channel.id, in: h)
        #expect(await eventually { await h.session.pending.item(id)?.state == .outcomeUnknown })
        let automatic = try #require(await h.session.tasks[.sendRetry(id)])
        await h.session.retrySend(id)
        #expect(await eventually { h.service.withState { $0.createdPosts.count } == 2 })
        #expect(await h.session.pending.item(id)?.state == .sending)
        clock.advance(by: .seconds(2))
        await automatic.value
        #expect(automatic.isCancelled)
        #expect(await h.session.pending.item(id)?.state == .sending)
        #expect(await h.session.discardSend(id) == nil)
        await gate.open()
        #expect(await eventually { await h.session.pending.isEmpty })
        #expect(h.service.withState { $0.createdPosts.count } == 2)
        #expect(h.unsent.usage.pendingBytes == 0)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
