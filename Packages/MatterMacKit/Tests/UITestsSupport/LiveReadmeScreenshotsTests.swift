import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
@testable import MatterMacUI

/// Opt-in: README screenshots of the native shell, signed in as **alice** on the
/// local 11.11 test server with the seeded "Design Demo" channel (`LiveSeedDemoTests`).
/// Only synthetic test content is shown. Captures only this test's own window into
/// `MM_README_SCREENSHOTS` (dark and light).
@MainActor
@Suite("README screenshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_README_SCREENSHOTS"] != nil))
struct LiveReadmeScreenshotsTests {
    enum Failure: Error { case missingCredentials, login, deadline, missingDemo }

    @Test func captureReadmeScreenshots() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["MM_TEST_ALICE_PASSWORD"], let directory = env["MM_README_SCREENSHOTS"] else {
            throw Failure.missingCredentials
        }
        // English dates for the README, for this test process only (volatile, never saved).
        UserDefaults.standard.setVolatileDomain(["AppleLocale": "en_US", "AppleLanguages": ["en"]],
                                                forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
        _ = NSApp.setActivationPolicy(.regular)
        let app = AppModel(environment: AppEnvironment(allowsInsecureLoopback: true,
            serviceFactory: DefaultMattermostServiceFactory(),
            makeRealtime: { MattermostRealtimeClient(endpoint: $0, credential: $1, currentUserID: $2) },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
        guard await app.beginLogin(serverText: "http://localhost:8065") == nil, case .login(let login) = app.phase else {
            throw Failure.login
        }
        login.loginID = "alice"
        login.password = password
        await login.submit()
        guard let model = app.activeSession else { await app.shutdownAll(); throw Failure.login }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = NSHostingController(rootView: MainWindowView(app: app, session: model)
            .frame(minWidth: 760, minHeight: 500))
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer {
            window.close()
            Task { await app.shutdownAll() }
        }
        try await wait(window) { model.sidebar?.sections.isEmpty == false && model.connection == .connected }
        let rows = model.sidebar?.sections.flatMap(\.rows) ?? []
        guard let demo = rows.first(where: { $0.displayName == "Design Demo" }) else { throw Failure.missingDemo }
        model.select(channel: demo.channelID)
        try await wait(window) {
            model.timeline?.target == .channel(demo.channelID) && (model.timeline?.items.count ?? 0) > 5
        }
        let pane = try #require(model.draftProvider as? ConversationController)
        pane.timeline.scrollToLiveEdge()
        func capture(_ name: String) async throws {
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await settle(window, seconds: 1.5)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                     URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png").path]
                try process.run()
                process.waitUntilExit()
            }
        }
        try await capture("conversation")

        // The thread about the release freeze, beside the channel.
        if let root = model.timeline?.items.compactMap(\.post).first(where: { $0.replyCount > 0 })?.postID {
            model.openThread(root: root)
            try await wait(window) { model.thread != nil && (model.thread?.items.count ?? 0) > 2 }
            try await capture("thread")
            model.closeThread()
            try await settle(window, seconds: 0.5)
        }

        // The in-window image viewer on the attached mockup.
        if let file = model.timeline?.items.compactMap(\.post).flatMap(\.files).last(where: \.isImage) {
            pane.timeline(perform: .previewImage(file))
            let viewer = try #require(pane.imageViewer)
            try await wait(window) { viewer.state != .loading }
            try await capture("image-viewer")
            viewer.close()
        }
    }

    private func settle(_ window: NSWindow, seconds: Double) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func wait(_ window: NSWindow, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
