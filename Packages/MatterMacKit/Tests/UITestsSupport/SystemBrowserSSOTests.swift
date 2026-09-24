import AppKit
import Testing
import Foundation
import MatterMacModels
import MatterMacCore
import MatterMacPlatform
import MattermostAPI
import TestSupport

/// Explicit opt-in: opens the real macOS authentication browser. The HTTP fixture
/// emulates the server's JavaScript desktop callback; it is not a Keycloak test.
@MainActor
@Suite("System browser SSO callback", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_BROWSER_TESTS"] == "1"))
struct SystemBrowserSSOTests {
    @Test func scopedBrowserCallbackCompletesNativeLogin() async throws {
        let server = try await LocalHTTPServer.start { request in
            if request.path.hasSuffix("/system/ping") { return .json(#"{"status":"OK"}"#, headers: ["X-Version-Id": "11.11.1"]) }
            if request.path.hasSuffix("/config/client") { return .json(#"{"EnableSignUpWithOpenId":"true","SiteName":"Local SSO Callback Test"}"#) }
            if request.path.hasSuffix("/oauth/openid/login") {
                let host = request.headers["Host"] ?? ""
                let client = request.queryValue("desktop_token") ?? ""
                let callback = "mattermost://\(host)/company/chat/login/desktop?client_token=\(client)&server_token=\(String(repeating: "a", count: 64))"
                // Same JS-initiated scheme navigation used by Mattermost's desktop
                // completion page. No bearer credential travels through this URL.
                let html = "<html><head><title>MatterMac SSO callback fixture</title></head><body>Returning to MatterMac…<script>window.location.href='\(callback)';</script></body></html>"
                return LocalHTTPServer.Response(status: 200, headers: ["Content-Type": "text/html", "Cache-Control": "no-store"], body: .data(Data(html.utf8)))
            }
            if request.path.hasSuffix("/login/desktop_token") {
                #expect(request.method == "POST")
                #expect(request.headers["Cookie"] == nil)
                return .json("{\"id\":\"\(CoreFixtures.me.id.rawValue)\",\"username\":\"alice\"}",
                             headers: ["Token": "synthetic-browser-session", "Set-Cookie": "must-not-persist=1; Path=/"])
            }
            if request.path.hasSuffix("/users/me") {
                #expect(request.headers["Cookie"] == nil)
                #expect(request.headers["Authorization"] == "Bearer synthetic-browser-session")
                return .json("{\"id\":\"\(CoreFixtures.me.id.rawValue)\",\"username\":\"alice\"}")
            }
            if request.path.hasSuffix("/users/logout") { return .json("{}") }
            return .json("[]")
        }
        defer { server.stop() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        var budget = ResourceBudget.standard
        budget.authenticationTimeoutSeconds = 120
        let coordinator = LoginCoordinator(factory: DefaultMattermostServiceFactory())
        let endpoint = server.endpoint(pathSegments: ["company", "chat"])
        let discovery = try await coordinator.discover(endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MatterMac SSO callback test"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        let attempt = try BrowserLoginAttempt(discovery: discovery, provider: .openID, budget: budget)
        let browser = BrowserAuthentication(budget: budget)
        let callback = try await browser.authenticate(attempt, anchor: window)
        let result = try await coordinator.completeBrowserLogin(attempt, callback: callback)
        #expect(result.user.id == CoreFixtures.me.id)
        await coordinator.discardNewLogin(result, endpoint: discovery.endpoint)
        #expect(server.requests.filter { $0.path.hasSuffix("/desktop_token") }.count == 1)
    }
}
