import Foundation
import Testing
import MatterMacModels
import MattermostAPI
@testable import MatterMacCore
import TestSupport

@Suite("Image ownership and bounds")
struct ImagePipelineTests {
    let scope = AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id)

    @MainActor @Test func pastedBytesFollowLastOwnerAfterDraftAndPendingRelease() throws {
        let data = CoreFixtures.png()
        var budget = ResourceBudget.standard
        budget.pastedImageBytes = data.count
        let ledger = UnsentWorkLedger(budget: budget)
        let store = DraftStore(ledger: ledger)
        let key = DraftKey(scope: scope, channelID: CoreFixtures.channel(1).id, rootID: nil)
        var source: UploadSource? = try ledger.pastedImage(data, typeIdentifier: "public.png")
        try store.save(Draft(text: "", attachments: [source!]), for: key)
        source = nil
        var activeUpload = store.draft(for: key)?.attachments.first
        let pending = try store.takeForSending(key)
        store.finishSending(key, reservation: pending, accepted: true)
        ledger.release(pending)
        #expect(ledger.usage.totalBytes == 0)
        #expect(ledger.usage.imageBytes == data.count)
        #expect(throws: UnsentWorkLedger.Refusal.imageBudgetExceeded(limitBytes: data.count)) {
            _ = try ledger.pastedImage(data, typeIdentifier: "public.png")
        }
        #expect(activeUpload?.memoryBytes == data.count)
        activeUpload = nil
        #expect(ledger.usage.imageBytes == 0)
        #expect(throws: APIError.self) {
            _ = try ledger.pastedImage(Data([1, 2]), typeIdentifier: "public.png")
        }
        #expect(ledger.usage.imageBytes == 0)
    }

    @Test func visibleImageRemainsChargedAfterCachePurge() async throws {
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let data = CoreFixtures.png(width: 128, height: 64)
        service.withState { $0.imageHandler = { _, _ in data } }
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let key = ImagePipeline.Key(scope: scope, resource: .profileImage(CoreFixtures.me.id, revision: 0), maxPixelSize: 32)
        var visible = await pipeline.image(for: key, using: service)
        #expect(visible?.image.width == 32)
        #expect(visible?.image.height == 16)
        let cost = try #require(visible?.byteCost)
        var cached = await pipeline.image(for: key, using: service)
        #expect(service.calls.filter { $0 == "imageData" }.count == 1)
        #expect(cached === visible)
        await pipeline.purge(scope: scope)
        #expect(await pipeline.decodedCount == 0)
        #expect(await pipeline.decodedBytes == cost)
        visible = nil
        // The second visible owner also keeps its charge.
        #expect(await pipeline.decodedBytes == cost)
        cached = nil
        #expect(await pipeline.decodedBytes == 0)
    }

    @Test func boundsAndCancelledLateResponsesCannotPopulateCache() async {
        let data = CoreFixtures.png()
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let gate = Gate()
        service.withState { $0.imageHandler = { _, _ in await gate.wait(); return data } }
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let key = ImagePipeline.Key(scope: scope, resource: .profileImage(CoreFixtures.me.id, revision: 0), maxPixelSize: 32)
        let task = Task { await pipeline.image(for: key, using: service) }
        #expect(await eventually { service.calls.contains("imageData") })
        await pipeline.purge(scope: scope)
        await gate.open()
        #expect(await task.value == nil)
        #expect(await pipeline.decodedBytes == 0)
        #expect(await pipeline.decodedCount == 0)
        #expect(await pipeline.inflightCount == 0)
        var budget = ResourceBudget.standard
        budget.maximumSourceImagePixels = 100
        let bounded = ImagePipeline(budget: budget, diagnostics: DiagnosticRing(byteBudget: 1_024))
        #expect(await bounded.image(for: key, using: service) == nil)
        #expect(await bounded.decodedBytes == 0)
        budget.compressedImagePerObjectBytes = data.count - 1
        let compressed = ImagePipeline(budget: budget, diagnostics: DiagnosticRing(byteBudget: 1_024))
        #expect(await compressed.image(for: key, using: service) == nil)
        #expect(await compressed.decodedBytes == 0)
    }

    @Test func cancelledQueuedDecodeReleasesItsWaiterWithoutAFreeSlot() async {
        let gate = AsyncGate(limit: 1, maximumWaiters: 1)
        #expect(await gate.enter())
        let queued = Task { await gate.enter() }
        #expect(await eventually { await gate.waitingCount == 1 })
        #expect(await gate.enter() == false)
        queued.cancel()
        #expect(await eventually { await gate.waitingCount == 0 })
        #expect(await queued.value == false)
        #expect(await gate.activeCount == 1)
        await gate.leave()
        #expect(await gate.activeCount == 0)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return await condition()
    }
}
