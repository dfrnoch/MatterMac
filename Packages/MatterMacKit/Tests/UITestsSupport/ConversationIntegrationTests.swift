import AppKit
import SwiftUI
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
    @Test func discardedPaneDoesNotRunQueuedCommands() async throws {
        let post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        let h = try await Harness(posts: [post])
        for _ in 0..<100 {
            if await h.model.session.post(post.id) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await h.model.session.post(post.id) != nil)
        let before = h.service.calls.filter { $0 == "addReaction" }
        h.controller.timeline(perform: .toggleReaction(post.id, emojiName: "smile"))
        h.controller.discardEditingState()
        for _ in 0..<100 { await Task.yield() }
        #expect(h.service.calls.filter { $0 == "addReaction" } == before)
        await h.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM_GLASS_SNAPSHOTS"] != nil))
    func captureFloatingChrome() async throws {
        let h = try await Harness(seedMessages: true, extraTeam: Team(
            id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "second", displayName: "Second"))
        await h.realtime.push(.state(.connected(resumed: false)))
        #expect(await waitUntil { h.model.connection == .connected })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = NSHostingController(rootView: MainWindowView(app: h.app, session: h.model)
            .frame(minWidth: 760, minHeight: 500))
        window.setContentSize(NSSize(width: 1000, height: 700))
        _ = NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.close() }
        let directory = ProcessInfo.processInfo.environment["MM_GLASS_SNAPSHOTS"]!
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for _ in 0..<25 {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
            if let pane = h.model.draftProvider as? ConversationController {
                let timelineFrame = pane.timeline.view.convert(pane.timeline.view.bounds, to: nil)
                #expect(timelineFrame.minX >= 199)
                #expect(timelineFrame.maxY > window.contentLayoutRect.maxY)
                #expect(pane.timeline.scrollView.contentInsets.top >= 50)
                #expect(pane.timeline.scrollView.contentInsets.bottom >= 60)
            }
            // Scroll away from the live edge to put real message pixels behind glass.
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            let tables = window.contentView.map { scrollViews($0).filter { $0.documentView is NSTableView } } ?? []
            if let scroll = tables.first {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - 160)))
                scroll.reflectScrolledClipView(clip)
            }
            // The channel list too, so rows pass under the sidebar's top edge.
            if let sidebar = tables.first(where: { $0.convert($0.bounds, to: nil).minX < 100 }) {
                let clip = sidebar.contentView
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 90))
                sidebar.reflectScrolledClipView(clip)
            }
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory + "/glass-" + name + ".png"]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        await h.close()
    }

    @Test func composerFloatsOverFullHeightTimelineAndTracksGrowth() async throws {
        let h = try await Harness()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = h.controller
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let pane = h.controller
        #expect(pane.timeline.view.frame.height == pane.view.bounds.height)
        let initial = pane.timeline.scrollView.contentInsets.bottom
        #expect(initial >= 60)
        pane.downloadBar.isHidden = false
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(pane.timeline.scrollView.contentInsets.bottom > initial)
        pane.downloadBar.isHidden = true
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(pane.timeline.scrollView.contentInsets.bottom == initial)
        pane.composer.load(draft: Draft(text: String(repeating: "line\n", count: 8)))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(pane.timeline.scrollView.contentInsets.bottom > initial)
        #expect(pane.timeline.view.frame.height == pane.view.bounds.height)
        window.setContentSize(NSSize(width: 460, height: 360))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(pane.timeline.scrollView.contentInsets.bottom >= pane.composer.view.frame.height)
        await h.close()
    }

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

    @Test(arguments: [false, true])
    func commandFeedbackStaysInItsConversation(navigate: Bool) async throws {
        let h = try await Harness()
        let gate = Gate()
        h.service.withState { state in
            state.commandHandler = { _ in
                await gate.wait()
                return CommandResult(isEphemeral: true, text: "Command completed", gotoLocation: nil)
            }
        }
        let key = h.controller.key
        h.controller.composer.load(draft: Draft(text: "/example"))
        h.controller.composerDidRequestSend(text: "/example")
        #expect(await waitUntil { h.service.calls.contains("executeCommand") })
        if navigate {
            h.model.select(channel: h.second.id)
            h.controller.update(target: .channel(h.second.id), snapshot: nil)
            h.controller.composer.load(draft: Draft(text: "unrelated draft"))
            h.controller.saveDraft()
        }
        await gate.open()
        #expect(await waitUntil { !h.app.environment.drafts.isSubmitting(key) })
        #expect(h.model.commandFeedback == (navigate ? nil : "Command completed"))
        #expect(h.app.environment.drafts.draft(for: key) == nil)
        #expect(h.app.environment.unsentLedger.usage.pendingOperations == 0)
        if navigate { #expect(h.controller.composer.text == "unrelated draft") }
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

    @Test func queuedSidebarCannotRevokeNewDirectMessageSelection() async throws {
        let h = try await Harness()
        let queued = try #require(h.model.sidebar)
        h.controller.composer.load(draft: Draft(text: "keep channel draft"))
        let key = h.controller.key
        let direct = try await h.model.session.directMessageChannel(with: CoreFixtures.bob.id)
        h.model.select(channel: direct)
        // The stream consumer may have dequeued this snapshot before the Core
        // request completed and resume only after the navigation continuation.
        await h.model.applySidebar(queued)
        #expect(h.model.selectedChannel == direct)
        #expect(h.controller.composer.textView.isEditable)
        #expect(h.app.environment.drafts.draft(for: key)?.text == "keep channel draft")
        #expect(await waitUntil { h.model.timeline?.target.channelID == direct })
        await h.close()
    }

    @Test func switchingTeamsStillSelectsVisibleChannelAndPreservesDraft() async throws {
        let team = Team(id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "second", displayName: "Second")
        var channel = CoreFixtures.channel(3)
        channel.teamID = team.id
        let h = try await Harness(extraTeam: team, extraChannel: channel)
        h.controller.composer.load(draft: Draft(text: "team draft"))
        let key = h.controller.key
        h.model.selectTeam(team.id)
        #expect(await waitUntil { h.model.selectedChannel == channel.id })
        #expect(h.app.environment.drafts.draft(for: key)?.text == "team draft")
        await h.close()
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
        MediaViewerController.isPresentationSuppressedForTesting = true
        defer { MediaViewerController.isPresentationSuppressedForTesting = false }
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
        #expect(await waitUntil { viewer.state == .loaded })
        // The server preview rendition, downsampled to the screen within the budget.
        #expect(requests.withLock { $0 } == [.filePreview(file.id)])
        let lease = try #require(viewer.lease)
        let expectedEdge = min(3_000, MediaViewerController.pixelSize(for: NSScreen.main, budget: h.app.environment.budget))
        #expect(lease.image.width == expectedEdge)
        #expect(lease.image.width <= h.app.environment.budget.maximumImagePixelDimension)
        #expect(await h.model.app!.images.decodedBytes >= lease.byteCost)
        #expect(viewer.imageView.image != nil)
        #expect(viewer.saveButton.isEnabled)
        // Escape closes the viewer and releases its lease and image.
        viewer.overlay.cancelOperation(nil)
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
        #expect(failed.messageLabel.stringValue == MediaViewerController.failureText)
        #expect(failed.lease == nil && failed.saveButton.isEnabled)
        // Leaving the channel closes the viewer.
        h.controller.update(target: .channel(h.second.id), snapshot: nil)
        #expect(h.controller.imageViewer == nil)
        await h.close()
    }

    /// A message with three images opens the in-window viewer over the whole window,
    /// moves between them releasing each previous image, and closes with Escape.
    /// `MM_SNAPSHOT_DIR` optionally captures only this test's window.
    @Test func mediaViewerCoversTheWindowAndMovesBetweenAMessagesImages() async throws {
        let files = (1...3).map { n in
            FileInfo(id: FileID(unchecked: CoreFixtures.id("image", n)), channelID: CoreFixtures.channel(1).id,
                     name: "screenshot-\(n).png", fileExtension: "png", size: 40_960, mimeType: "image/png",
                     width: 1_600, height: 1_000, hasPreviewImage: true)
        }
        var post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id, message: "Three screenshots")
        post.fileIDs = files.map(\.id)
        post.files = files
        let h = try await Harness(posts: [post])
        let image = Self.gradientPNG(width: 1_600, height: 1_000)
        let requests = OSAllocatedUnfairLock<[MattermostAPI.ImageResource]>(initialState: [])
        h.service.withState { state in
            state.imageHandler = { resource, _ in
                requests.withLock { $0.append(resource) }
                return image
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 680),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = h.controller
        window.setContentSize(NSSize(width: 1_000, height: 680))
        window.orderFrontRegardless()
        defer { window.close() }
        #expect(await waitUntil { h.model.timeline?.items.contains { $0.post?.postID == post.id } == true })
        h.controller.update(target: .channel(h.first.id), snapshot: h.model.timeline)
        window.contentView?.layoutSubtreeIfNeeded()

        h.controller.timeline(perform: .previewImage(files[1]))
        let viewer = try #require(h.controller.imageViewer)
        #expect(viewer.overlay.superview === window.contentView?.superview)
        #expect(viewer.overlay.frame == window.contentView?.superview?.bounds)
        #expect(window.firstResponder === viewer.overlay)
        #expect(viewer.content.files.map(\.id) == files.map(\.id))
        #expect(viewer.file.id == files[1].id)
        #expect(viewer.content.authorName?.isEmpty == false)
        #expect(viewer.content.timestamp == post.createAt)
        #expect(await waitUntil { viewer.state == .loaded })
        #expect(viewer.canMoveBackward && viewer.canMoveForward)
        await capture(window, "media-viewer.png")

        // → loads the next image and releases the previous lease.
        let firstLease = try #require(viewer.lease)
        viewer.overlay.keyDown(with: try #require(Self.key(.rightArrow)))
        #expect(viewer.file.id == files[2].id)
        #expect(!viewer.canMoveForward)
        #expect(await waitUntil { viewer.state == .loaded })
        #expect(viewer.lease !== firstLease)
        #expect(requests.withLock { $0 }.contains(.filePreview(files[2].id)))
        // Double-click zooms to actual size and back.
        #expect(!viewer.overlay.stage.isZoomedIn)
        viewer.overlay.stage.toggleZoom(at: nil)
        #expect(viewer.overlay.stage.userZoomed)
        #expect(viewer.overlay.zoomButton.accessibilityLabel() == String(localized: "Fit to Window"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(viewer.overlay.stage.isZoomedIn)
        await capture(window, "media-viewer-zoomed.png")
        viewer.overlay.stage.fit(animated: false)
        #expect(!viewer.overlay.stage.isZoomedIn)

        // Escape closes; the overlay leaves the window and releases its images.
        viewer.overlay.cancelOperation(nil)
        #expect(h.controller.imageViewer == nil)
        #expect(await waitUntil { viewer.overlay.superview == nil && viewer.lease == nil })
        #expect(viewer.imageView.image == nil)
        await h.close()
    }

    private static func key(_ key: NSEvent.SpecialKey) -> NSEvent? {
        let character = Unicode.Scalar(UInt32(key.rawValue)).map { String(Character($0)) } ?? ""
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                context: nil, characters: character, charactersIgnoringModifiers: character,
                                isARepeat: false, keyCode: key == .rightArrow ? 124 : 123)
    }

    private static func gradientPNG(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.95, green: 0.45, blue: 0.55, alpha: 1), CGColor(red: 0.35, green: 0.4, blue: 0.95, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: width / 2 - 140, y: height / 2 - 140, width: 280, height: 280))
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func capture(_ window: NSWindow, _ name: String) async {
        guard let directory = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] else { return }
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent(name).path]
        try? process.run()
        process.waitUntilExit()
    }

    @Test func permalinksToThisServerOpenTheChannelFocusedOnThePost() async throws {
        let h = try await Harness()
        let target = CoreFixtures.post(40, channel: h.second.id)
        h.service.withState { $0.posts[target.id] = target }
        let permalink = try #require(SafeLink(CoreFixtures.endpoint.url(path: ["qa", "pl", target.id.rawValue]).absoluteString))
        h.controller.timeline(perform: .openLink(permalink))
        #expect(await waitUntil { h.model.selectedChannel == h.second.id })
        #expect(await waitUntil { h.model.timeline?.items.contains { $0.id == TimelineItemID(.post(target.id)) } == true })
        // A channel link by name.
        let channelLink = try #require(SafeLink(CoreFixtures.endpoint.url(path: ["qa", "channels", h.first.name]).absoluteString))
        h.controller.timeline(perform: .openLink(channelLink))
        #expect(await waitUntil { h.model.selectedChannel == h.first.id })
        // A post in a channel the user is not a member of is reported, not opened.
        let foreign = CoreFixtures.post(41, channel: CoreFixtures.channel(9).id)
        h.service.withState { $0.posts[foreign.id] = foreign }
        let foreignLink = try #require(SafeLink(CoreFixtures.endpoint.url(path: ["qa", "pl", foreign.id.rawValue]).absoluteString))
        h.model.inlineError = nil
        h.controller.timeline(perform: .openLink(foreignLink))
        #expect(await waitUntil { h.model.inlineError != nil })
        #expect(h.model.selectedChannel == h.first.id)
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

        init(budget: ResourceBudget = .standard, posts: [Post] = [], seedMessages: Bool = false, extraTeam: Team? = nil, extraChannel: Channel? = nil) async throws {
            let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
            let channels = [first, second] + (extraChannel.map { [$0] } ?? [])
                + (seedMessages ? (3...30).map { CoreFixtures.channel($0) } : [])
            service.withState { state in
                state.teams = [CoreFixtures.team] + (extraTeam.map { [$0] } ?? [])
                for post in posts { state.posts[post.id] = post }
                if seedMessages {
                    for n in 0..<40 {
                        let message = n % 3 == 0 ? "## Release review\n\nA clear, native conversation with **readable details** and @alice."
                            : n % 3 == 1 ? "```swift\nlet client = MatterMac()\n```" : "A compact follow-up with a useful next step."
                        let post = CoreFixtures.post(n, channel: channels[0].id, message: message)
                        state.posts[post.id] = post
                    }
                }
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
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }
}
