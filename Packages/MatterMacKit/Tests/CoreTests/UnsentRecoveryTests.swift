import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("Unsent recovery")
struct UnsentRecoveryTests {
    @MainActor @Test func draftSnapshotsRejectChangesAndSubmissionWithoutLosingOtherWork() throws {
        var budget = ResourceBudget.standard
        budget.unsentText = .init(count: 2, bytes: 1_000)
        let ledger = UnsentWorkLedger(budget: budget)
        let store = DraftStore(ledger: ledger)
        let scope = AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id)
        let key = DraftKey(scope: scope, channelID: CoreFixtures.channel(1).id, rootID: nil)
        let thread = DraftKey(scope: scope, channelID: key.channelID, rootID: CoreFixtures.post(1, channel: key.channelID).id)
        let extra = DraftKey(scope: scope, channelID: CoreFixtures.channel(2).id, rootID: nil)
        try store.save(Draft(text: "draft"), for: key)
        try store.save(Draft(text: "thread", editingPost: CoreFixtures.post(2, channel: key.channelID).id), for: thread)
        let stale = try #require(store.recoveryDrafts(for: scope).first { $0.id == key })
        #expect(throws: UnsentWorkLedger.Refusal.tooManyPendingOperations(limit: 2)) {
            try store.save(Draft(text: "new"), for: extra)
        }
        #expect(store.remainingBytes(for: extra) == 0)
        // Draft-to-pending admission still works at the combined count cap.
        let reservation = try store.takeForSending(key)
        let submitting = try #require(store.recoveryDrafts(for: scope).first { $0.id == key })
        #expect(!submitting.canDiscard)
        #expect(!store.discardRecoveryDraft(stale))
        #expect(!store.discardRecoveryDraft(submitting))
        store.finishSending(key, reservation: reservation, accepted: false)
        store.clear(key)
        try store.save(Draft(text: "draft"), for: key)
        #expect(!store.discardRecoveryDraft(stale)) // Same text, different draft lifetime.
        try store.save(Draft(text: "changed"), for: key)
        let current = try #require(store.recoveryDrafts(for: scope).first { $0.id == key })
        try store.save(Draft(text: "changed"), for: key) // A composer flush of identical text is harmless.
        #expect(store.discardRecoveryDraft(current))
        #expect(store.recoveryDrafts(for: scope).map(\.id) == [thread])
        #expect(ledger.usage.pendingOperations == 0)
        #expect(ledger.usage.draftBytes == store.draft(for: thread)?.byteCost)
    }

    @Test func pendingRecoveryRejectsChangedRowsAndPreservesAccountAndImageOwnership() async throws {
        let h = await SessionHarness()
        h.service.withState { $0.uploadHandler = { _, _ in throw APIError.notSent(.offline) } }
        var source: UploadSource? = try h.unsent.pastedImage(CoreFixtures.png(), typeIdentifier: "public.png")
        let reservation = try h.unsent.convertDraftToPending(nil, bytes: source!.metadataBytes)
        let id = try await h.session.enqueueSend(text: "", channel: h.channel.id, rootID: nil,
                                                 attachments: [source!], reservation: reservation)
        source = nil
        #expect(await eventually { await h.session.pending.item(id)?.state == .failed(.offline) })
        var stale = Optional(try #require(await h.session.recoverySends().first))
        #expect(stale?.attachments.count == 1)
        await h.session.notify(.signedOutByServer)
        #expect(await h.session.discardRecoverySend(stale!) == false)
        var current = Optional(try #require(await h.session.recoverySends().first))
        #expect(current?.state == .failed(.authenticationRequired))
        let other = await SessionHarness()
        #expect(await other.session.discardRecoverySend(current!) == false)
        #expect(await h.session.discardRecoverySend(current!) == true)
        #expect(await h.session.recoverySends().isEmpty)
        #expect(h.unsent.usage.totalBytes == 0)
        #expect(h.unsent.usage.imageBytes > 0) // Snapshot leases are still accounted.
        stale = nil
        current = nil
        #expect(await eventually { h.unsent.usage.imageBytes == 0 })
        _ = await h.session.shutdown(revokeServerSession: false)
        _ = await other.session.shutdown(revokeServerSession: false)
    }

    @Test func inFlightRecoveryCannotDiscardOrTriggerAnotherSend() async throws {
        let h = await SessionHarness()
        let gate = Gate()
        let service = h.service
        h.service.withState { state in
            state.createPostHandler = { outgoing, _ in
                await gate.wait()
                return service.storeCreated(outgoing)
            }
        }
        _ = await h.send("in flight")
        #expect(await eventually { h.service.withState { $0.createdPosts.count == 1 } })
        let row = try #require(await h.session.recoverySends().first)
        #expect(!row.canDiscard)
        #expect(await h.session.discardRecoverySend(row) == false)
        #expect(h.unsent.usage.pendingOperations == 1)
        await gate.open()
        #expect(await eventually { await h.session.recoverySends().isEmpty })
        #expect(await h.session.discardRecoverySend(row) == false)
        #expect(h.service.withState { $0.createdPosts.count == 1 })
        #expect(h.unsent.usage.totalBytes == 0)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
