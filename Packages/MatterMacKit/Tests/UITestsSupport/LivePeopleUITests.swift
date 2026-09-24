import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
@testable import MatterMacUI

/// Real login and native shell: channel details, profile cards, and a slash command
/// typed into the AppKit composer. Server-side status changes are restored.
/// Snapshots are written only when `MM_SNAPSHOT_DIR` is set (development review).
@MainActor
@Suite("Live native people and commands", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LivePeopleUITests {
    enum Failure: Error { case missingCredentials, login, channel, deadline, composer }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8067"])
    func detailsProfilesAndCommands(base: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_ALICE_PASSWORD"] else {
            throw Failure.missingCredentials
        }
        _ = NSApplication.shared
        let app = try await login(base: base, password: password)
        guard let model = app.activeSession else { await app.shutdownAll(); throw Failure.login }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let host = NSHostingController(rootView: MainWindowView(app: app, session: model)
            .frame(minWidth: 760, minHeight: 500))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: ProcessInfo.processInfo.environment["MM_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 1100, height: 720))
        do {
            try await wait {
                model.sidebar?.sections.flatMap(\.rows).contains { $0.displayName.lowercased() == "interop" } == true
            }
            guard let channel = model.sidebar?.sections.flatMap(\.rows)
                .first(where: { $0.displayName.lowercased() == "interop" })?.channelID else { throw Failure.channel }
            model.select(channel: channel)
            let pane = try await pane(model, channel: channel)

            // Channel details and paged members through the view model.
            let details = try await model.channelDetails(channel)
            #expect(details.name == "interop")
            #expect(details.canLeave)
            let members = try await model.channelMembers(channel, page: 0)
            #expect(members.members.contains { $0.username == "bob" })
            model.isChannelInfoVisible = true
            try await settle(window)
            await snapshot(window, "channel-info-\(port(base)).png")

            // Profile card by @mention username.
            let bob = try #require(await model.profile(username: "bob"))
            #expect(bob.user.username == "bob")
            let card = NSHostingView(rootView: UserProfileCard(session: model, lookup: .username("bob")))
            card.frame = NSRect(x: 0, y: 0, width: 300, height: 320)
            let cardWindow = NSWindow(contentRect: card.frame, styleMask: [.titled], backing: .buffered, defer: false)
            cardWindow.isReleasedWhenClosed = false
            cardWindow.contentView = card
            try await settle(cardWindow)
            await snapshot(cardWindow, "profile-card-\(port(base)).png")

            // A slash command through the real composer consumes the draft and shows the reply.
            pane.composer.textView.insertText("/away", replacementRange: NSRange(location: NSNotFound, length: 0))
            pane.composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await wait { model.commandFeedback != nil }
            #expect(pane.composer.text.isEmpty)
            try await wait { await model.profile(for: model.slot.user.id)?.status == .away }
            try await settle(window)
            await snapshot(window, "command-feedback-\(port(base)).png")
            pane.composer.textView.insertText("/online", replacementRange: NSRange(location: NSNotFound, length: 0))
            pane.composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await wait { await model.profile(for: model.slot.user.id)?.status == .online }

            // Unknown commands keep the draft and explain the leading-space escape.
            try await wait { pane.composer.text.isEmpty && pane.composer.isSendAllowed }
            model.inlineError = nil
            pane.composer.textView.insertText("/matterMacNoSuchCommand", replacementRange: NSRange(location: NSNotFound, length: 0))
            pane.composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await wait { model.inlineError != nil }
            #expect(pane.composer.text == "/matterMacNoSuchCommand")
            pane.composer.clear()
        } catch {
            model.setStatus(.online)
            window.close()
            await app.shutdownAll()
            throw error
        }
        window.close()
        await app.shutdownAll()
    }

    private func login(base: String, password: String) async throws -> AppModel {
        let app = AppModel(environment: AppEnvironment(allowsInsecureLoopback: true,
            serviceFactory: DefaultMattermostServiceFactory(),
            makeRealtime: { MattermostRealtimeClient(endpoint: $0, credential: $1, currentUserID: $2) },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
        guard await app.beginLogin(serverText: base) == nil, case .login(let login) = app.phase else { throw Failure.login }
        login.loginID = "alice"
        login.password = password
        await login.submit()
        guard app.activeSession != nil else { throw Failure.login }
        return app
    }

    private func pane(_ model: SessionViewModel, channel: ChannelID) async throws -> ConversationController {
        try await wait { (model.draftProvider as? ConversationController)?.target == .channel(channel)
                && model.timeline?.target == .channel(channel)
        }
        guard let pane = model.draftProvider as? ConversationController else { throw Failure.composer }
        return pane
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func port(_ base: String) -> String { URL(string: base)?.port.map(String.init) ?? "default" }

    /// Captures only this test's own window (never the rest of the screen).
    private func snapshot(_ window: NSWindow, _ name: String) async {
        guard let directory = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] else { return }
        window.orderFrontRegardless()
        try? await settle(window)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent(name).path]
        try? process.run()
        process.waitUntilExit()
        window.orderOut(nil)
    }

    private func wait(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for native state", sourceLocation: sourceLocation)
                throw Failure.deadline
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
