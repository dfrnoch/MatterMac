import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

/// Real login, SwiftUI shell, AppKit composer and timeline, REST and WebSocket.
/// Both peers are MatterMac; this does not certify the official web-client gate.
@MainActor
@Suite("Live native conversations", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveConversationTests {
    enum Failure: Error { case missingCredentials, login, channel, deadline, composer }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func nativeLoginDraftsMessagesEditsThreadsAndDMs(base: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data("MatterMac explicit attachment test".utf8)
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: destination) }
        let env = ProcessInfo.processInfo.environment
        guard let alicePassword = env["MM_TEST_ALICE_PASSWORD"], let bobPassword = env["MM_TEST_BOB_PASSWORD"]
        else { throw Failure.missingCredentials }
        _ = NSApplication.shared
        let alice = try await login(base: base, user: "alice", password: alicePassword)
        let bob: AppModel
        do { bob = try await login(base: base, user: "bob", password: bobPassword) }
        catch { await alice.shutdownAll(); throw error }
        guard let a = alice.activeSession, let b = bob.activeSession else {
            await alice.shutdownAll(); await bob.shutdownAll(); throw Failure.login
        }
        let windows = [window(app: alice, model: a), window(app: bob, model: b)]
        var created: [(model: SessionViewModel, id: PostID)] = []
        do {
            try await wait { a.sidebar != nil && b.sidebar != nil }
            guard let channel = a.sidebar?.sections.flatMap(\.rows).first(where: { $0.displayName == "Interop" || $0.displayName == "interop" })?.channelID,
                  let other = a.sidebar?.sections.flatMap(\.rows).first(where: { $0.channelID != channel })?.channelID
            else { throw Failure.channel }
            a.select(channel: channel); b.select(channel: channel)
            let composer = try await pane(a, channel: channel)
            _ = try await pane(b, channel: channel)
            composer.composer.textView.insertText("session draft", replacementRange: NSRange(location: NSNotFound, length: 0))
            composer.composer.textView.setSelectedRange(NSRange(location: 2, length: 3))
            composer.composerDidReceiveFiles([file])
            try await wait { composer.selectionTask == nil }
            #expect(composer.selectedFiles.count == 1)
            let png = CoreFixtures.png()
            let pasted = composer.composerDidPasteImage(data: png, typeIdentifier: "public.png")
            #expect(pasted)
            a.select(channel: other)
            _ = try await pane(a, channel: other)
            a.select(channel: channel)
            let restored = try await pane(a, channel: channel)
            #expect(restored.composer.text == "session draft")
            #expect(restored.selectedFiles.count == 2)
            #expect(restored.composer.textView.selectedRange() == NSRange(location: 2, length: 3))
            let marker = "MatterMac native check " + UUID().uuidString
            restored.composer.clear()
            send(marker, in: restored)
            let root = try await ownPost(a, target: .channel(channel), text: marker)
            created.append((a, root.id))
            try await wait { b.timeline?.items.contains(where: { $0.id == TimelineItemID(.post(root.id)) }) == true }
            #expect(restored.composer.text.isEmpty)
            #expect(restored.selectedFiles.isEmpty)
            #expect(root.fileIDs.count == 2)
            try await wait { await b.session.post(root.id)?.files.count == 2 }
            let received = try #require(await b.session.post(root.id))
            let fileID = try #require(received.files.first(where: { $0.fileExtension == "txt" })?.id)
            try await b.session.downloadAttachment(fileID, channel: channel, to: destination)
            #expect(try Data(contentsOf: destination) == payload)
            let imageID = try #require(received.files.first(where: { $0.fileExtension == "png" })?.id)
            let receiver = try await pane(b, channel: channel)
            for window in windows {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            try await wait { receiver.displayedImages[.thumbnail(imageID)] != nil }
            let preview = try #require(receiver.displayedImages[.thumbnail(imageID)]?.lease)
            #expect(preview.image.width > 0 && preview.image.width <= bob.environment.budget.maximumImagePixelDimension)
            #expect(preview.image.height > 0 && preview.image.height <= bob.environment.budget.maximumImagePixelDimension)
            try await b.session.downloadAttachment(imageID, channel: channel, to: destination)
            #expect(try Data(contentsOf: destination) == png)
            try await wait { alice.environment.unsentLedger.usage.imageBytes == 0 }
            restored.timeline(perform: .edit(root.id))
            try await wait { if case .edit = restored.composer.mode { true } else { false } }
            restored.composer.textView.setSelectedRange(NSRange(location: 0, length: (restored.composer.text as NSString).length))
            send(marker + " edited", in: restored)
            try await wait { await b.session.post(root.id)?.message == marker + " edited" }
            try await wait { restored.composer.text.isEmpty }
            a.openThread(root: root.id); b.openThread(root: root.id)
            try await wait { b.threadDraftProvider != nil && a.thread != nil }
            guard let thread = b.threadDraftProvider as? ConversationController else { throw Failure.composer }
            send(marker + " reply", in: thread)
            let reply = try await ownPost(b, target: .thread(root: root.id, channel: channel), text: marker + " reply")
            created.append((b, reply.id))
            try await wait { a.thread?.items.contains(where: { $0.id == TimelineItemID(.post(reply.id)) }) == true }
            a.openDirectMessage(with: b.scope.user); b.openDirectMessage(with: a.scope.user)
            try await wait { a.selectedChannel != channel && a.selectedChannel == b.selectedChannel }
            guard let dm = a.selectedChannel else { throw Failure.channel }
            let direct = try await pane(a, channel: dm)
            _ = try await pane(b, channel: dm)
            #expect(a.replyTarget == nil && b.replyTarget == nil)
            send(marker + " direct", in: direct)
            let directPost = try await ownPost(a, target: .channel(dm), text: marker + " direct")
            created.append((a, directPost.id))
            try await wait { b.timeline?.items.contains(where: { $0.id == TimelineItemID(.post(directPost.id)) }) == true }
        } catch {
            for post in created.reversed() { try? await post.model.session.delete(post.id) }
            await alice.shutdownAll(); await bob.shutdownAll()
            for window in windows { window.close() }
            throw error
        }
        var cleanupFailed = false
        for post in created.reversed() {
            do { try await post.model.session.delete(post.id) }
            catch { cleanupFailed = true }
        }
        await alice.shutdownAll(); await bob.shutdownAll()
        for window in windows { window.close() }
        #expect(!cleanupFailed)
        #expect(alice.activeSession == nil && bob.activeSession == nil)
    }

    private func login(base: String, user: String, password: String) async throws -> AppModel {
        let app = AppModel(environment: AppEnvironment(allowsInsecureLoopback: true,
            serviceFactory: DefaultMattermostServiceFactory(),
            makeRealtime: { MattermostRealtimeClient(endpoint: $0, credential: $1, currentUserID: $2) },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
        guard await app.beginLogin(serverText: base) == nil, case .login(let login) = app.phase else { throw Failure.login }
        login.loginID = user
        login.password = password
        await login.submit()
        guard app.activeSession != nil else { throw Failure.login }
        #expect(login.password.isEmpty)
        return app
    }

    private func window(app: AppModel, model: SessionViewModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = NSHostingController(rootView: MainWindowView(app: app, session: model)
            .frame(minWidth: 760, minHeight: 500))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func pane(_ model: SessionViewModel, channel: ChannelID) async throws -> ConversationController {
        try await wait {
            (model.draftProvider as? ConversationController)?.target == .channel(channel)
                && model.timeline?.target == .channel(channel)
        }
        guard let pane = model.draftProvider as? ConversationController else { throw Failure.composer }
        return pane
    }

    private func send(_ text: String, in pane: ConversationController) {
        pane.composer.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        pane.composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    private func ownPost(_ model: SessionViewModel, target: TimelineTarget, text: String) async throws -> Post {
        try await wait { await model.session.lastOwnPost(in: target)?.message == text }
        guard let post = await model.session.lastOwnPost(in: target) else { throw Failure.deadline }
        return post
    }

    private func wait(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { Issue.record("Timed out waiting for native state", sourceLocation: sourceLocation); throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
