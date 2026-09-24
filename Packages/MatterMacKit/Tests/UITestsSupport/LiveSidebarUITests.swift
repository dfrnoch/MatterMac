import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
@testable import MatterMacUI

/// Opt-in: the native shell signed in as **bob** on the local servers shows the
/// server's sidebar categories, browses channels and collapses/expands a category
/// (restored). `MM_SNAPSHOT_DIR` optionally captures only this test's window.
@MainActor
@Suite("Live native sidebar", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveSidebarUITests {
    enum Failure: Error { case missingCredentials, login, deadline }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8067"])
    func categoriesBrowseAndCollapse(base: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_BOB_PASSWORD"] else {
            throw Failure.missingCredentials
        }
        _ = NSApplication.shared
        let app = AppModel(environment: AppEnvironment(allowsInsecureLoopback: true,
            serviceFactory: DefaultMattermostServiceFactory(),
            makeRealtime: { MattermostRealtimeClient(endpoint: $0, credential: $1, currentUserID: $2) },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
        guard await app.beginLogin(serverText: base) == nil, case .login(let login) = app.phase else { throw Failure.login }
        login.loginID = "bob"
        login.password = password
        await login.submit()
        guard let model = app.activeSession else { await app.shutdownAll(); throw Failure.login }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = NSHostingController(rootView: MainWindowView(app: app, session: model)
            .frame(minWidth: 760, minHeight: 500))
        window.orderFrontRegardless()
        var restore: (SidebarSection, Bool)?
        do {
            try await wait(window) { model.sidebar?.usesServerCategories == true }
            let sidebar = try #require(model.sidebar)
            #expect(sidebar.sections.contains { $0.kind == .channels })
            #expect(sidebar.sections.contains { $0.kind == .directMessages })
            #expect(sidebar.visibleRows(selected: model.selectedChannel).contains { $0.displayName.lowercased() == "interop" }
                || sidebar.sections.contains { $0.isCollapsed })
            if let dir = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] { await snapshot(window, dir, base) }

            let page = try await model.browseChannels(term: "interop", archived: false, page: 0)
            #expect(page.items.contains { $0.name == "interop" && $0.isMember && ($0.memberCount ?? 0) >= 3 })

            let channels = try #require(sidebar.sections.first { $0.kind == .channels })
            restore = (channels, channels.isCollapsed)
            model.setCategoryCollapsed(channels, collapsed: !channels.isCollapsed)
            try await wait(window) { model.sidebar?.sections.first { $0.kind == .channels }?.isCollapsed == !channels.isCollapsed }
            // The server's copy changed too (re-read after the realtime event or directly).
            let fresh = try #require(model.sidebar?.sections.first { $0.kind == .channels })
            model.setCategoryCollapsed(fresh, collapsed: channels.isCollapsed)
            try await wait(window) { model.sidebar?.sections.first { $0.kind == .channels }?.isCollapsed == channels.isCollapsed }
            restore = nil
            #expect(model.inlineError == nil)
        } catch {
            if let (section, collapsed) = restore { model.setCategoryCollapsed(section, collapsed: collapsed) }
            try? await Task.sleep(for: .seconds(1))
            window.close()
            await app.shutdownAll()
            throw error
        }
        window.close()
        await app.shutdownAll()
    }

    private func wait(_ window: NSWindow, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func snapshot(_ window: NSWindow, _ directory: String, _ base: String) async {
        for _ in 0..<20 {
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        let port = URL(string: base)?.port.map(String.init) ?? "default"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent("live-sidebar-\(port).png").path]
        try? process.run()
        process.waitUntilExit()
    }
}
