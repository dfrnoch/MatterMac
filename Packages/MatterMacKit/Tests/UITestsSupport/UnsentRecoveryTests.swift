import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Unsent recovery integration", .serialized)
struct UnsentRecoveryTests {
    @Test func undoAndRedoRefuseClaimedDraftSlotWithoutConsumingHistory() async throws {
        var budget = ResourceBudget.standard
        budget.unsentText.count = 1
        let h = try await Harness(budget: budget)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = h.controller
        defer { window.close() }
        let text = h.controller.composer.textView
        window.makeFirstResponder(text)
        let undo = try #require(text.undoManager)
        text.insertText("retained undo", replacementRange: NSRange(location: NSNotFound, length: 0))
        await endEvent(text)
        h.controller.saveDraft()
        text.selectAll(nil)
        text.deleteBackward(nil)
        await endEvent(text)
        h.controller.saveDraft()
        #expect(text.string.isEmpty)
        let other = DraftKey(scope: h.model.scope, channelID: h.second.id, rootID: nil)
        try h.app.environment.drafts.save(Draft(text: "other slot"), for: other)
        text.undo(nil)
        #expect(text.string.isEmpty && undo.canUndo)
        #expect(h.model.inlineError != nil)
        h.app.environment.drafts.clear(other)
        text.undo(nil)
        h.controller.saveDraft()
        #expect(text.string == "retained undo")
        #expect(h.app.environment.drafts.draft(for: h.controller.key)?.text == text.string)
        text.redo(nil)
        h.controller.saveDraft()
        #expect(text.string.isEmpty)
        text.undo(nil) // Restore the deleted text, then undo its original insertion.
        h.controller.saveDraft()
        text.undo(nil)
        h.controller.saveDraft()
        #expect(text.string.isEmpty && undo.canRedo)
        try h.app.environment.drafts.save(Draft(text: "other slot"), for: other)
        text.redo(nil)
        #expect(text.string.isEmpty && undo.canRedo)
        h.app.environment.drafts.clear(other)
        text.redo(nil)
        h.controller.saveDraft()
        #expect(text.string == "retained undo")
        #expect(h.app.environment.unsentLedger.usage.totalBytes == text.string.utf8.count)
        await h.close()
    }

    @Test func groupedUndoGrowthAtByteLimitPreservesTextSelectionAndHistoryAcrossPanes() async throws {
        var budget = ResourceBudget.standard
        budget.unsentText = .init(count: 2, bytes: 64)
        let h = try await Harness(budget: budget)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = h.controller
        defer { window.close() }
        let composer = h.controller.composer
        let text = composer.textView
        window.makeFirstResponder(text)
        let undo = try #require(text.undoManager)
        composer.load(draft: Draft(text: "abcdefgh"))
        h.controller.saveDraft()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let replaced = text.replaceAsUserEdit(NSRange(location: 0, length: 4), with: "é")
        let deleted = text.replaceAsUserEdit(NSRange(location: 1, length: 4), with: "")
        undo.endUndoGrouping()
        #expect(replaced && deleted)
        #expect(composer.text == "é")
        let selection = NSRange(location: 0, length: 1)
        text.setSelectedRange(selection)
        let other = ConversationController(session: h.model, target: .channel(h.second.id))
        other.loadViewIfNeeded()
        let inserted = other.composer.insertAtCaret(String(repeating: "b", count: 62))
        #expect(inserted)
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 64)
        text.undo(nil)
        #expect(composer.text == "é")
        #expect(text.selectedRange() == selection)
        #expect(text.metrics == ComposerTextMetrics("é"))
        #expect(undo.canUndo && !undo.canRedo)
        #expect(h.app.environment.drafts.draft(for: h.controller.key)?.text == "é")
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 64)
        #expect(h.model.inlineError != nil)
        // Free precisely the six bytes needed, then retry the same undo group.
        let shrank = other.composer.textView.replaceAsUserEdit(NSRange(location: 56, length: 6), with: "")
        #expect(shrank)
        text.undo(nil)
        #expect(composer.text == "abcdefgh")
        #expect(!undo.canUndo && undo.canRedo)
        #expect(h.app.environment.drafts.draft(for: h.controller.key)?.text == "abcdefgh")
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 64)
        // Redo shrinks and must remain useful even when shared capacity is full.
        text.redo(nil)
        #expect(composer.text == "é")
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 58)
        #expect(text.metrics == ComposerTextMetrics("é"))
        await h.close()
    }

    @Test func growingRedoAtByteLimitCanBeRetriedWithoutConsumingHistory() async throws {
        var budget = ResourceBudget.standard
        budget.unsentText = .init(count: 2, bytes: 32)
        let h = try await Harness(budget: budget)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = h.controller
        defer { window.close() }
        let text = h.controller.composer.textView
        window.makeFirstResponder(text)
        text.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        await endEvent(text)
        text.insertAtCaret("123456")
        await endEvent(text)
        text.undo(nil)
        #expect(text.string == "é")
        let other = ConversationController(session: h.model, target: .channel(h.second.id))
        other.loadViewIfNeeded()
        let inserted = other.composer.insertAtCaret(String(repeating: "b", count: 30))
        #expect(inserted)
        text.undoManager?.redo() // Native callers using the manager share admission.
        #expect(text.string == "é" && text.undoManager?.canRedo == true)
        #expect(h.app.environment.drafts.draft(for: h.controller.key)?.text == "é")
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 32)
        let shrank = other.composer.textView.replaceAsUserEdit(NSRange(location: 24, length: 6), with: "")
        #expect(shrank)
        text.redo(nil)
        #expect(text.string == "é123456")
        #expect(h.app.environment.drafts.draft(for: h.controller.key)?.text == text.string)
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 32)
        // A shrinking undo succeeds with no spare bytes or count slots.
        text.undo(nil)
        #expect(text.string == "é")
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 26)
        await h.close()
    }

    private func endEvent(_ text: ComposerTextView) async {
        var turns = 0
        repeat {
            await Task.yield()
            turns += 1
        } while (text.undoManager?.groupingLevel ?? 0) > 0 && turns < 100
        text.breakUndoCoalescing()
    }

    @Test func recoverySheetLaysOutInNativeHostingView() async throws {
        let h = try await Harness()
        h.controller.composer.load(draft: Draft(text: "layout fixture"))
        h.controller.saveDraft()
        let view = NSHostingView(rootView: UnsentRecoveryView(session: h.model))
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0 && view.fittingSize.height > 0)
        await h.close()
    }

    @Test func closingRecoveryReleasesItsLastImageSnapshotAndCannotReload() async throws {
        let h = try await Harness()
        let data = CoreFixtures.png()
        let pasted = h.controller.composerDidPasteImage(data: data, typeIdentifier: "public.png")
        #expect(pasted)
        let recovery = UnsentRecoveryModel(session: h.model)
        await recovery.refresh()
        #expect(recovery.draftItems.first?.draft.attachments.count == 1)
        // Simulate deletion through another owner while the sheet still has a row.
        h.app.environment.drafts.clear(h.controller.key)
        h.controller.discardEditingState()
        #expect(h.app.environment.unsentLedger.usage.imageBytes == data.count)
        recovery.close()
        #expect(h.app.environment.unsentLedger.usage.imageBytes == 0)
        await recovery.refresh()
        #expect(recovery.draftItems.isEmpty && recovery.sendItems.isEmpty)
        await h.close()
    }

    @Test func staleDraftCannotDiscardNewTextAndSelectedDiscardClearsComposer() async throws {
        let h = try await Harness()
        h.controller.composer.load(draft: Draft(text: "first version"))
        h.controller.saveDraft()
        let otherKey = DraftKey(scope: h.model.scope, channelID: h.second.id, rootID: nil)
        try h.app.environment.drafts.save(Draft(text: "keep other draft"), for: otherKey)
        let recovery = UnsentRecoveryModel(session: h.model)
        await recovery.refresh()
        let stale = try #require(recovery.draftItems.first { $0.id == h.controller.key })
        h.controller.composer.load(draft: Draft(text: "changed while reviewing"))
        #expect(await recovery.discardDraft(stale) == false)
        #expect(h.app.environment.drafts.draft(for: h.controller.key)?.text == "changed while reviewing")
        let current = try #require(recovery.draftItems.first { $0.id == h.controller.key })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(recovery.copy(current.draft.text, to: board))
        #expect(board.string(forType: .string) == "changed while reviewing")
        #expect(await recovery.discardDraft(current))
        #expect(h.controller.composer.text.isEmpty)
        h.controller.saveDraft() // A later pane teardown must not resurrect deleted text.
        #expect(h.app.environment.drafts.draft(for: h.controller.key) == nil)
        #expect(h.app.environment.drafts.draft(for: otherKey)?.text == "keep other draft")
        #expect(h.app.environment.unsentLedger.usage.totalBytes == "keep other draft".utf8.count)
        recovery.close()
        await h.close()
    }

    @Test func discardCancelsSendBeforeActorAdmissionWithoutResurrectingDraft() async throws {
        let h = try await Harness()
        h.controller.composer.load(draft: Draft(text: "discard before admission"))
        h.controller.saveDraft()
        let recovery = UnsentRecoveryModel(session: h.model)
        await recovery.refresh()
        let item = try #require(recovery.draftItems.first)
        h.controller.composerDidRequestSend(text: item.draft.text)
        #expect(await recovery.discardDraft(item))
        #expect(await waitUntil { h.controller.composer.isSendAllowed })
        h.controller.saveDraft()
        #expect(h.controller.composer.text.isEmpty)
        #expect(h.app.environment.drafts.draft(for: item.id) == nil)
        #expect(h.service.withState { $0.createdPosts.isEmpty })
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 0)
        #expect(h.app.environment.unsentLedger.usage.pendingOperations == 0)
        recovery.close()
        await h.close()
    }

    @Test func endedSessionRecoveryKeepsPendingImageUntilExplicitDiscard() async throws {
        let h = try await Harness()
        h.service.withState { $0.createPostHandler = { _, _ in throw APIError.cancelled } }
        let data = CoreFixtures.png()
        h.controller.composer.load(draft: Draft(text: "pending image text"))
        let pasted = h.controller.composerDidPasteImage(data: data, typeIdentifier: "public.png")
        #expect(pasted)
        h.controller.composerDidRequestSend(text: "pending image text")
        #expect(await waitUntil {
            let items = await h.model.session.recoverySends()
            return items.first?.state == .failed(.cancelled) && h.controller.selectedFiles.isEmpty
        })
        h.controller.composer.load(draft: Draft(text: "separate unsent draft"))
        h.controller.saveDraft()
        await h.model.handleNotice(.signedOutByServer)
        let recovery = UnsentRecoveryModel(session: h.model)
        await recovery.refresh()
        #expect(recovery.draftItems.map(\.draft.text) == ["separate unsent draft"])
        #expect(recovery.sendItems.map(\.message) == ["pending image text"])
        #expect(recovery.sendItems.first?.attachments.count == 1)
        #expect(h.app.environment.unsentLedger.usage.imageBytes == data.count)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(recovery.copy(try #require(recovery.sendItems.first?.message), to: board))
        #expect(board.string(forType: .string) == "pending image text")
        try await discardFirstSend(recovery)
        #expect(await waitUntil { h.app.environment.unsentLedger.usage.imageBytes == 0 })
        #expect(h.app.environment.unsentLedger.usage.pendingOperations == 0)
        #expect(recovery.sendItems.isEmpty)
        #expect(recovery.draftItems.map(\.draft.text) == ["separate unsent draft"])
        #expect(h.service.withState { $0.createdPosts.count } == 1)
        recovery.close()
        #expect(recovery.draftItems.isEmpty && recovery.sendItems.isEmpty)
        await h.close()
    }

    @Test func submittingEditIsCopyableButCannotBeDiscarded() async throws {
        let h = try await Harness()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let post = CoreFixtures.post(1, channel: h.first.id, user: CoreFixtures.me.id)
        h.service.withState { state in
            state.editPostHandler = { _, _ in
                await gate.wait()
                throw APIError.cancelled
            }
        }
        let key = h.controller.key
        try h.app.environment.drafts.save(Draft(text: "edit still in flight", editingPost: post.id), for: key)
        h.controller.refreshDraft(for: key)
        h.controller.composerDidRequestSend(text: "edit still in flight")
        #expect(await waitUntil { h.service.calls.contains("editPost") })
        let recovery = UnsentRecoveryModel(session: h.model)
        await recovery.refresh()
        let item = try #require(recovery.draftItems.first)
        #expect(!item.canDiscard)
        #expect(recovery.sendItems.isEmpty)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(recovery.copy(item.draft.text, to: board))
        #expect(board.string(forType: .string) == "edit still in flight")
        #expect(await recovery.discardDraft(item) == false)
        #expect(h.app.environment.drafts.isSubmitting(key))
        await gate.open()
        #expect(await waitUntil { !h.app.environment.drafts.isSubmitting(key) })
        await recovery.refresh()
        #expect(recovery.draftItems.first?.canDiscard == true)
        #expect(h.app.environment.drafts.draft(for: key)?.text == "edit still in flight")
        recovery.close()
        await h.close()
    }

    private func discardFirstSend(_ recovery: UnsentRecoveryModel) async throws {
        let item = try #require(recovery.sendItems.first)
        #expect(await recovery.discardSend(item))
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @MainActor private final class Harness {
        let first = CoreFixtures.channel(1)
        let second = CoreFixtures.channel(2)
        let service: FakeMattermostService
        let app: AppModel
        let model: SessionViewModel
        let controller: ConversationController

        init(budget: ResourceBudget = .standard) async throws {
            let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
            let channels = [first, second]
            service.withState { state in
                state.teams = [CoreFixtures.team]
                for channel in channels {
                    state.channels[channel.id] = channel
                    state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: CoreFixtures.me.id)
                }
            }
            self.service = service
            let realtime = FakeRealtimeConnection()
            app = AppModel(environment: AppEnvironment(budget: budget, serviceFactory: Factory(fake: service),
                makeRealtime: { _, _, _ in realtime }, markupParse: { MarkupParser.parse($0, limits: $1) }))
            let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
                login: LoginResult(credential: BearerCredential(token: "recovery-fixture", kind: .session)!, user: CoreFixtures.me),
                capabilities: ServerCapabilities())
            model = SessionViewModel(slot: slot, app: app)
            await slot.session.start()
            // Registry startup is asynchronous. Wait for the directory before selecting;
            // an earlier empty sidebar correctly retires any premature conversation.
            let channelID = first.id
            let deadline = ContinuousClock.now + .seconds(3)
            while model.sidebar?.sections.contains(where: { $0.rows.contains(where: { $0.channelID == channelID }) }) != true,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(model.sidebar?.sections.contains(where: { $0.rows.contains(where: { $0.channelID == channelID }) }) == true)
            model.select(channel: first.id)
            // Navigation starts only after directory readiness. Main-actor contention
            // may have consumed the directory deadline before selection was possible.
            let navigationDeadline = ContinuousClock.now + .seconds(3)
            while model.header?.channelID != first.id, ContinuousClock.now < navigationDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(model.header?.channelID == first.id)
            try #require(model.header?.fileAttachmentsEnabled == true)
            controller = ConversationController(session: model, target: .channel(first.id))
            controller.updateComposerAvailability()
            #expect(controller.composer.textView.isEditable, "Fixture controller was discarded during initial directory loading")
        }

        func close() async {
            model.prepareForSignOut()
            app.environment.drafts.discardAll(for: model.scope)
            await app.registry.removeAll()
        }
    }

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in recovery fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }
}
