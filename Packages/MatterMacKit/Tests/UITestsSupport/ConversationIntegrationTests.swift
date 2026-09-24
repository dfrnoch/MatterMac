import AppKit
import os
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Native conversation integration", .serialized)
struct ConversationIntegrationTests {
    @Test func draftsKeepSelectionAndEditModeAcrossNavigation() async throws {
        let h = try await Harness()
        let controller = h.controller
        let post = CoreFixtures.post(1, channel: h.first.id, user: CoreFixtures.me.id)
        let draft = Draft(text: "unfinished edit", selectedRange: NSRange(location: 3, length: 4), editingPost: post.id)
        try h.app.environment.drafts.save(draft, for: controller.key)
        controller.refreshDraft(for: controller.key)
        controller.update(target: .channel(h.second.id), snapshot: nil)
        controller.composer.load(draft: Draft(text: "other draft"))
        controller.saveDraft()
        controller.update(target: .channel(h.first.id), snapshot: nil)
        #expect(controller.composer.text == draft.text)
        #expect(controller.composer.textView.selectedRange() == draft.selectedRange)
        guard case .edit(let id, _) = controller.composer.mode else {
            Issue.record("Edit became a new-message draft")
            await h.close()
            return
        }
        #expect(id == post.id)
        controller.composerDidRequestCancelMode()
        #expect(h.app.environment.drafts.draft(for: controller.key) == nil)
        controller.update(target: .channel(h.second.id), snapshot: nil)
        #expect(controller.composer.text == "other draft")
        await h.close()
    }

    @Test(arguments: [false, true])
    func editAdmissionSurvivesPaneReplacementAndFailure(reject: Bool) async throws {
        let h = try await Harness()
        let gate = Gate()
        let post = CoreFixtures.post(1, channel: h.first.id, user: CoreFixtures.me.id)
        h.service.withState { state in
            state.editPostHandler = { _, text in
                await gate.wait()
                if reject { throw APIError.cancelled }
                var edited = post
                edited.message = text
                return edited
            }
        }
        let key = h.controller.key
        let draft = Draft(text: "edited text", selectedRange: NSRange(location: 2, length: 1), editingPost: post.id)
        try h.app.environment.drafts.save(draft, for: key)
        h.controller.refreshDraft(for: key)
        h.controller.composerDidRequestSend(text: draft.text)
        #expect(await waitUntil { h.service.calls.contains("editPost") })
        #expect(h.app.environment.drafts.isSubmitting(key))
        // SwiftUI may dismantle a pane while the service call is suspended.
        let replacement = ConversationController(session: h.model, target: .channel(h.first.id))
        #expect(!replacement.composer.textView.isEditable)
        replacement.saveDraft()
        #expect(h.app.environment.unsentLedger.usage.totalBytes == draft.byteCost)
        replacement.update(target: .channel(h.second.id), snapshot: nil)
        replacement.composer.load(draft: Draft(text: "unrelated draft"))
        replacement.saveDraft()
        await gate.open()
        #expect(await waitUntil { !h.app.environment.drafts.isSubmitting(key) })
        #expect(replacement.composer.text == "unrelated draft")
        h.controller.saveDraft() // A late dismantle must not resurrect a successful edit.
        replacement.update(target: .channel(h.first.id), snapshot: nil)
        #expect(replacement.composer.text == (reject ? draft.text : ""))
        #expect(replacement.composer.textView.isEditable)
        if reject {
            #expect(h.app.environment.drafts.draft(for: key) == draft)
            #expect(h.model.inlineError != nil)
        } else {
            #expect(replacement.composer.mode == .compose)
            #expect(h.app.environment.drafts.draft(for: key) == nil)
        }
        #expect(h.service.withState { $0.createdPosts.isEmpty })
        #expect(h.app.environment.unsentLedger.usage.pendingOperations == 0)
        await h.close()
    }

    @Test func historyRequestDoesNotSwallowSendAndPendingTextSurvivesNavigation() async throws {
        let h = try await Harness()
        let gate = Gate()
        h.service.withState { state in
            state.createPostHandler = { _, _ in
                await gate.wait()
                throw APIError.cancelled
            }
        }
        h.controller.composer.load(draft: Draft(text: "queued text"))
        h.controller.timelineRequestsOlder()
        h.controller.composerDidRequestSend(text: "queued text")
        #expect(await waitUntil { h.service.calls.contains("createPost") && h.controller.composer.text.isEmpty })
        h.controller.update(target: .channel(h.second.id), snapshot: nil)
        h.controller.composer.load(draft: Draft(text: "second channel"))
        h.controller.saveDraft()
        await gate.open()
        #expect(await waitUntil { h.app.environment.unsentLedger.usage.pendingOperations == 1 })
        h.controller.update(target: .channel(h.first.id), snapshot: nil)
        #expect(h.controller.composer.text.isEmpty)
        #expect(h.service.withState { $0.createdPosts.count } == 1)
        #expect(h.app.environment.unsentLedger.usage.totalBytes == "queued textsecond channel".utf8.count)
        await h.close()
    }

    @Test func productionCompletionProviderAcceptsMentionWithoutSending() async throws {
        let h = try await Harness()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = h.controller
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let composer = h.controller.composer
        composer.completion.debounceInterval = .zero
        composer.textView.insertText("@ali", replacementRange: NSRange(location: NSNotFound, length: 0))
        await composer.completion.pendingFetch?.value
        #expect(composer.completion.popup.items.map(\.insertionText) == ["@alice"])
        composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(composer.text == "@alice ")
        #expect(h.service.withState { $0.createdPosts.isEmpty })
        let provider = try #require(composer.completionProvider)
        let channels = await provider.completions(for: .channel, query: "channel-")
        #expect(channels.map(\.insertionText) == ["~channel-1", "~channel-2"])
        await h.close()
        #expect(await provider.completions(for: .user, query: "al").isEmpty)
    }

    @Test func openingDirectMessageResetsThreadAndPublishesMatchingHistory() async throws {
        let h = try await Harness()
        let root = CoreFixtures.post(1, channel: h.first.id)
        h.service.withState { $0.posts[root.id] = root }
        h.controller.composer.load(draft: Draft(text: "keep channel draft"))
        let channelKey = h.controller.key
        h.model.openThread(root: root.id)
        #expect(await waitUntil { h.model.thread != nil })
        h.model.openDirectMessage(with: CoreFixtures.bob.id)
        #expect(await waitUntil {
            h.model.selectedChannel != h.first.id && h.model.timeline?.target.channelID == h.model.selectedChannel
        })
        #expect(h.model.thread == nil)
        #expect(h.model.replyTarget == nil)
        // The reused pane may already show the DM; the draft belongs to the channel.
        #expect(h.app.environment.drafts.draft(for: channelKey)?.text == "keep channel draft")
        #expect(h.model.header == nil || h.model.header?.channelID == h.model.selectedChannel)
        await h.close()
        h.controller.composer.load(draft: Draft(text: "late teardown"))
        h.controller.saveDraft()
        #expect(!h.app.environment.drafts.hasAnyDraft)
    }

    @Test func attachmentOnlyDraftSurvivesNavigationAndSendFailure() async throws {
        let h = try await Harness()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("attachment fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        h.controller.composerDidReceiveFiles([file])
        #expect(await waitUntil { h.controller.selectionTask == nil })
        #expect(h.controller.selectedFiles.count == 1)
        let key = h.controller.key
        let cost = try #require(h.app.environment.drafts.draft(for: key)?.byteCost)
        #expect(cost > 0 && h.app.environment.hasUnsentWork)
        #expect(h.app.environment.unsentLedger.usage.totalBytes == cost)
        h.controller.update(target: .channel(h.second.id), snapshot: nil)
        #expect(h.controller.selectedFiles.isEmpty)
        h.controller.update(target: .channel(h.first.id), snapshot: nil)
        #expect(h.controller.composer.attachments.count == 1)
        h.service.withState { $0.createPostHandler = { _, _ in throw APIError.cancelled } }
        h.controller.composerDidRequestSend(text: "")
        #expect(await waitUntil { h.service.calls.contains("createPost") && h.controller.selectedFiles.isEmpty })
        #expect(h.service.withState { $0.createdPosts.first?.fileIDs.count } == 1)
        #expect(h.app.environment.drafts.draft(for: key) == nil)
        #expect(h.app.environment.unsentLedger.usage.totalBytes == cost)
        #expect(h.app.environment.unsentLedger.usage.pendingOperations == 1)
        await h.close()
        #expect(h.app.environment.unsentLedger.usage.totalBytes == 0)
    }

    @Test func refusedSelectionAndLateMetadataKeepOriginalDraft() async throws {
        let h = try await Harness()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        h.controller.composer.load(draft: Draft(text: "keep this"))
        h.controller.saveDraft()
        h.controller.composerDidReceiveFiles(Array(repeating: file, count: 11))
        #expect(h.controller.composer.text == "keep this" && h.controller.selectedFiles.isEmpty)
        h.controller.composerDidReceiveFiles([file])
        h.controller.update(target: .channel(h.second.id), snapshot: nil)
        #expect(await waitUntil { h.controller.selectionTask == nil })
        #expect(h.controller.selectedFiles.isEmpty)
        h.controller.update(target: .channel(h.first.id), snapshot: nil)
        #expect(h.controller.composer.text == "keep this" && h.controller.selectedFiles.isEmpty)
        #expect(ConversationController.safeDownloadName("../../folder/evil\\name.txt") == "name.txt")
        #expect(ConversationController.safeDownloadName("..") == "attachment")
        await h.close()
    }

    @Test func pastedImageBudgetIsSharedAcrossDraftsAndRefusalKeepsOriginal() async throws {
        let data = CoreFixtures.png()
        var budget = ResourceBudget.standard
        budget.pastedImageBytes = data.count
        let h = try await Harness(budget: budget)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(data, forType: .png)
        let text = h.controller.composer.textView
        #expect(text.readSelection(from: board, type: .png))
        #expect(h.controller.selectedFiles.count == 1)
        h.controller.update(target: .channel(h.second.id), snapshot: nil)
        #expect(!text.readSelection(from: board, type: .png))
        #expect(h.controller.selectedFiles.isEmpty)
        #expect(h.app.environment.unsentLedger.usage.imageBytes == data.count)
        h.controller.update(target: .channel(h.first.id), snapshot: nil)
        let id = try #require(h.controller.selectedFiles.first?.id)
        h.controller.composerDidRemoveAttachment(id: id)
        #expect(h.app.environment.unsentLedger.usage.imageBytes == 0)
        #expect(text.readSelection(from: board, type: .png))
        h.controller.composerDidRemoveAttachment(id: try #require(h.controller.selectedFiles.first?.id))
        #expect(h.app.environment.unsentLedger.usage.imageBytes == 0)
        await h.close()
    }

    @Test func revokedChannelNavigationCannotReplaceSavedDraftWithClearedComposer() async throws {
        let h = try await Harness()
        h.controller.composer.load(draft: Draft(text: "keep revoked draft"))
        let accepted = h.controller.composerDidPasteImage(data: CoreFixtures.png(), typeIdentifier: "public.png")
        #expect(accepted)
        let key = h.controller.key
        await h.realtime.push(.userRemoved(userID: CoreFixtures.me.id, channelID: h.first.id, removerID: nil))
        #expect(await waitUntil { h.model.selectedChannel != h.first.id && h.model.pendingNotice == .accessRevoked(channel: h.first.id) })
        #expect(h.controller.composer.text.isEmpty)
        #expect(!h.controller.composer.textView.isEditable)
        h.controller.saveDraft()
        h.controller.refreshDraft(for: key) // A late send callback must not restore a dismantled pane.
        #expect(h.controller.composer.text.isEmpty)
        #expect(h.app.environment.drafts.draft(for: key)?.text == "keep revoked draft")
        #expect(h.app.environment.drafts.draft(for: key)?.attachments.count == 1)
        h.controller.update(target: .channel(h.second.id), snapshot: nil)
        #expect(h.app.environment.drafts.draft(for: key)?.text == "keep revoked draft")
        await h.close()
    }

    @Test func endedSessionClearsViewsWithoutOverwritingSavedDraft() async throws {
        let h = try await Harness()
        h.controller.composer.load(draft: Draft(text: "keep my draft"))
        let pasted = h.controller.composerDidPasteImage(data: CoreFixtures.png(), typeIdentifier: "public.png")
        #expect(pasted)
        let key = h.controller.key
        await h.model.handleNotice(.signedOutByServer)
        #expect(h.model.requiresAuthentication)
        #expect(h.model.selectedChannel == nil && h.model.timeline == nil && h.model.search == nil)
        #expect(h.controller.composer.text.isEmpty && h.controller.selectedFiles.isEmpty)
        #expect(!h.controller.composer.textView.isEditable)
        h.controller.saveDraft() // Late SwiftUI dismantle must not replace the retained draft.
        #expect(h.app.environment.drafts.draft(for: key)?.text == "keep my draft")
        #expect(h.app.environment.drafts.draft(for: key)?.attachments.count == 1)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        h.model.copyUnsentText(to: clipboard)
        #expect(await waitUntil { !h.model.isCopyingUnsentText })
        #expect(clipboard.string(forType: .string) == "keep my draft")
        h.model.dismissNotice()
        await h.model.handleNotice(.operationFailed(.offline))
        #expect(h.model.pendingNotice == .signedOutByServer)
        h.model.select(channel: h.second.id)
        #expect(h.model.selectedChannel == nil)
        await h.close()
    }

    @Test func attachmentCapabilityChangesDisableInputAndKeepSelectedImages() async throws {
        let h = try await Harness()
        let png = CoreFixtures.png()
        let pasted = h.controller.composerDidPasteImage(data: png, typeIdentifier: "public.png")
        #expect(pasted)
        h.service.withState { $0.attachmentsEnabled = false }
        await h.realtime.push(.configChanged)
        #expect(await waitUntil { h.model.header?.fileAttachmentsEnabled == false })
        #expect(!h.controller.composer.isAttachmentSelectionAllowed)
        let refused = h.controller.composerDidPasteImage(data: png, typeIdentifier: "public.png")
        #expect(!refused)
        #expect(h.controller.selectedFiles.count == 1)
        await #expect(throws: ServerSession.SendRejection.attachmentsDisabled) {
            try await h.model.session.validateSend(text: "", channel: h.first.id, attachments: h.controller.selectedFiles)
        }
        h.service.withState { $0.attachmentsEnabled = nil }
        await h.realtime.push(.configChanged)
        #expect(await waitUntil { h.model.header?.fileAttachmentsEnabled == nil })
        await #expect(throws: ServerSession.SendRejection.attachmentsUnavailable) {
            try await h.model.session.validateSend(text: "", channel: h.first.id, attachments: h.controller.selectedFiles)
        }
        h.service.withState { $0.attachmentsEnabled = true }
        await h.realtime.push(.configChanged)
        #expect(await waitUntil { h.controller.composer.isAttachmentSelectionAllowed })
        #expect(h.controller.selectedFiles.count == 1)
        await h.close()
    }

    @Test func expiredSessionReturnsToItsSubpathLoginAndSSOProvider() async throws {
        let server = try await LocalHTTPServer.start { request in
            if request.path.hasSuffix("/system/ping") {
                return .json(#"{"status":"OK"}"#, headers: ["X-Version-Id": "10.11.24"])
            }
            if request.path.hasSuffix("/config/client") {
                return .json(#"{"Version":"10.11.24","EnableSignUpWithGitLab":"true","GitLabButtonText":"Fixture SSO"}"#)
            }
            if request.path.hasSuffix("/users/me/teams") {
                return .json(#"{"id":"api.context.session_expired.app_error","status_code":401}"#, status: 401)
            }
            return .json("[]")
        }
        defer { server.stop() }
        let app = AppModel(environment: AppEnvironment(allowsInsecureLoopback: true,
            serviceFactory: DefaultMattermostServiceFactory(), makeRealtime: { _, _, _ in FakeRealtimeConnection() },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
        let endpoint = server.endpoint(pathSegments: ["company", "chat"])
        #expect(await app.beginLogin(serverText: endpoint.description) == nil)
        guard case .login(let first) = app.phase else { Issue.record("Missing login form"); return }
        try await app.completeLogin(LoginResult(credential: BearerCredential(token: "expired-fixture", kind: .session)!,
                                          user: CoreFixtures.me), discovery: first.discovery)
        let model = try #require(app.activeSession)
        #expect(await waitUntil { model.requiresAuthentication })
        await app.reauthenticate(model.slot.id) // No unsent work, so no discard alert.
        #expect(app.registry.slots.isEmpty)
        #expect(model.isDetached)
        guard case .login(let replacement) = app.phase else { Issue.record("Recovery did not return to login"); return }
        #expect(replacement.discovery.endpoint == endpoint)
        #expect(replacement.discovery.browserSSOProviders == [.gitlab])
        #expect(!server.requests.contains { $0.path.hasSuffix("/users/logout") })
        app.cancelLogin()
        await app.shutdownAll()
    }

    @Test func imagePreviewOpensABoundedInMemoryViewerAndReleasesItOnClose() async throws {
        let h = try await Harness()
        ImageViewerWindowController.isPresentationSuppressedForTesting = true
        defer { ImageViewerWindowController.isPresentationSuppressedForTesting = false }
        let png = CoreFixtures.png(width: 3_000, height: 1_500)
        let requests = OSAllocatedUnfairLock<[MattermostAPI.ImageResource]>(initialState: [])
        h.service.withState { state in
            state.imageHandler = { resource, _ in
                requests.withLock { $0.append(resource) }
                return png
            }
        }
        let file = FileInfo(id: FileID(unchecked: "imagexzzzzzzzzzzzzzzzzzzz"), name: "photo.png", fileExtension: "png",
                            size: 4_096, mimeType: "image/png", width: 3_000, height: 1_500, hasPreviewImage: true)
        h.controller.timeline(perform: .previewImage(file))
        let viewer = try #require(h.controller.imageViewer)
        #expect(viewer.window?.isRestorable == false)
        #expect(await waitUntil { viewer.state == .loaded })
        // The server preview rendition, downsampled to the screen within the budget.
        #expect(requests.withLock { $0 } == [.filePreview(file.id)])
        let lease = try #require(viewer.lease)
        let expectedEdge = min(3_000, ImageViewerWindowController.pixelSize(for: NSScreen.main, budget: h.app.environment.budget))
        #expect(lease.image.width == expectedEdge)
        #expect(lease.image.width <= h.app.environment.budget.maximumImagePixelDimension)
        #expect(await h.model.app!.images.decodedBytes >= lease.byteCost)
        #expect(viewer.imageView.image != nil)
        #expect(viewer.saveButton.isEnabled)
        // Escape closes the viewer and releases its lease and image.
        viewer.window?.cancelOperation(nil)
        #expect(h.controller.imageViewer == nil)
        #expect(viewer.lease == nil)
        #expect(viewer.imageView.image == nil)

        // No preview rendition: the thumbnail is used; a failure is reported honestly.
        h.service.withState { state in
            state.imageHandler = { resource, _ in
                requests.withLock { $0.append(resource) }
                throw APIError.cancelled
            }
        }
        let plain = FileInfo(id: FileID(unchecked: "plainxzzzzzzzzzzzzzzzzzzz"), name: "icon.png", fileExtension: "png",
                             size: 128, mimeType: "image/png", width: 16, height: 16, hasPreviewImage: false)
        h.controller.timeline(perform: .previewImage(plain))
        let failed = try #require(h.controller.imageViewer)
        #expect(await waitUntil { failed.state == .failed })
        #expect(requests.withLock { $0.last } == .fileThumbnail(plain.id))
        #expect(failed.messageLabel.stringValue == ImageViewerWindowController.failureText)
        #expect(failed.lease == nil && failed.saveButton.isEnabled)
        // Leaving the channel closes the viewer.
        h.controller.update(target: .channel(h.second.id), snapshot: nil)
        #expect(h.controller.imageViewer == nil)
        await h.close()
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    @MainActor private final class Harness {
        let first = CoreFixtures.channel(1)
        let second = CoreFixtures.channel(2)
        let service: FakeMattermostService
        let app: AppModel
        let model: SessionViewModel
        let controller: ConversationController
        let realtime = FakeRealtimeConnection()

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
            let realtime = self.realtime
            app = AppModel(environment: AppEnvironment(budget: budget, serviceFactory: Factory(fake: service),
                makeRealtime: { _, _, _ in realtime }, markupParse: { text, _ in MarkupParser.parse(text) }))
            let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
                login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
                capabilities: ServerCapabilities())
            model = SessionViewModel(slot: slot, app: app)
            await slot.session.start()
            model.select(channel: first.id)
            controller = ConversationController(session: model, target: .channel(first.id))
            let deadline = ContinuousClock.now + .seconds(3)
            while model.header?.channelID != first.id, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(model.header?.fileAttachmentsEnabled == true)
            controller.updateComposerAvailability()
        }

        func close() async {
            model.prepareForSignOut()
            app.environment.drafts.discardAll(for: model.scope)
            await app.registry.removeAll()
        }
    }

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }
}
