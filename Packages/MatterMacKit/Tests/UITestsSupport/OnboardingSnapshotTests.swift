import AppKit
import SwiftUI
import Testing
import MatterMacModels
@testable import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

/// Visual review of the sign-in screens. Opt-in: `MM_ONBOARDING_SNAPSHOTS=<dir>`
/// hosts every onboarding state in a test window with synthetic data (no network)
/// and captures only that window, in light and dark. `MM_ONBOARDING_APP_ICON` may
/// name a built `MatterMac.app` whose icon replaces the test runner's;
/// `MM_ONBOARDING_ONLY=<prefix>` limits the capture to matching screens.
@MainActor
@Suite("Onboarding snapshots", .serialized)
struct OnboardingSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM_ONBOARDING_SNAPSHOTS"] != nil))
    func captureSignInScreens() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = try #require(environment["MM_ONBOARDING_SNAPSHOTS"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let app = environment["MM_ONBOARDING_APP_ICON"] {
            NSApplication.shared.applicationIconImage = NSWorkspace.shared.icon(forFile: app)
        }

        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        func makeApp() -> AppModel {
            AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
                makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) }))
        }
        let app = makeApp()
        let adding = makeApp()
        _ = try adding.registry.add(endpoint: CoreFixtures.endpoint,
            login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
            capabilities: ServerCapabilities(siteName: "QA Chat"))
        adding.isAddingServer = true
        // The message the app shows after signing out, on the first screen.
        let signedOut = makeApp()
        signedOut.lastSignOutMessage = SignOutText.describe(.serverSessionRevoked)

        let secure = try ServerURLNormalizer.normalize("https://chat.example.org", allowInsecureLoopback: false)
        let local = try ServerURLNormalizer.normalize("http://localhost:8065", allowInsecureLoopback: true)
        let options = LoginOptions(email: true, username: true, gitlab: true, openID: true,
                                   ssoProviderLabels: [.openID: "Example ID"])
        let discovery = DiscoveryResult(endpoint: secure, version: ServerVersion(major: 11, minor: 11, patch: 1),
            capabilities: ServerCapabilities(version: ServerVersion(major: 11, minor: 11, patch: 1),
                                             siteName: "Example Chat", login: options))
        let untested = DiscoveryResult(endpoint: local, version: ServerVersion(major: 9, minor: 5, patch: 2),
            capabilities: ServerCapabilities(version: ServerVersion(major: 9, minor: 5, patch: 2),
                                             login: LoginOptions(username: true)))
        let password = "not-a-real-password"

        func login(_ discovery: DiscoveryResult, _ configure: (LoginModel) -> Void = { _ in }) -> LoginModel {
            let model = LoginModel(discovery: discovery, app: app)
            configure(model)
            return model
        }

        // Built per appearance: leaving a sign-in screen clears its secrets.
        func screens() -> [(String, Int, AnyView)] { [
            ("1-connect", 0, AnyView(ConnectView(model: app, serverText: .constant("")))),
            ("2-connect-invalid", 0, AnyView(ConnectView(model: app, serverText: .constant("ftp://chat.example.org"),
                validation: .invalid(ServerURLErrorText.describe(.unsupportedScheme("ftp")))))),
            ("3-connect-confirm", 1, AnyView(ConnectView(model: app, serverText: .constant("chat.example.org"),
                validation: .normalized(secure.description)))),
            ("4-add-server", 0, AnyView(ConnectView(model: adding, serverText: .constant("")))),
            ("5-restoring", 0, AnyView(RestoringSignInsView())),
            ("6-login-password", 2, AnyView(LoginView(login: login(discovery) {
                $0.loginID = "alice"; $0.password = password
            }, app: app))),
            ("7-login-mfa", 2, AnyView(LoginView(login: login(discovery) {
                $0.loginID = "alice"; $0.password = password; $0.needsMFA = true
                $0.errorMessage = "That code was not accepted. Codes can be used only once; wait for the next code and try again."
            }, app: app))),
            ("8-login-token", 2, AnyView(LoginView(login: login(discovery) { $0.method = .personalAccessToken }, app: app))),
            ("9-login-sso", 2, AnyView(LoginView(login: login(discovery) { $0.method = .browserSSO }, app: app))),
            ("10-login-working", 2, AnyView(LoginView(login: login(discovery) {
                $0.loginID = "alice"; $0.password = password; $0.isWorking = true
            }, app: app))),
            ("11-login-untested-http", 2, AnyView(LoginView(login: login(untested), app: app))),
            ("12-signed-out", 0, AnyView(ConnectView(model: signedOut, serverText: .constant("")))),
        ] }

        // A non-activating panel becomes key without activating the test runner, so
        // default buttons and focus rings draw as they do in the app's key window.
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.title = "MatterMac"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        _ = NSApp.setActivationPolicy(.regular)
        defer { window.close() }
        let only = environment["MM_ONBOARDING_ONLY"]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for (screen, stage, view) in screens() where only.map({ screen.hasPrefix($0) }) ?? true {
                window.contentViewController = NSHostingController(rootView: ZStack {
                    OnboardingBackdrop(stage: stage)
                    view
                }
                .frame(minWidth: 760, minHeight: 500)
                // The test runner cannot take focus from the user's frontmost app;
                // render controls as they look in the key window.
                .environment(\.controlActiveState, .key)
                // The app's AccentColor asset (the test runner has none).
                .tint(Self.appAccent))
                window.setContentSize(NSSize(width: 1000, height: 700))
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                for _ in 0..<12 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(60))
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                     URL(fileURLWithPath: directory).appendingPathComponent("\(screen)-\(name).png").path]
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
            }
        }
        window.contentViewController = nil
        await adding.registry.removeAll()
        await app.shutdownAll()
        await adding.shutdownAll()
        await signedOut.shutdownAll()
    }

    private static let appAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.408, green: 0.643, blue: 0.941, alpha: 1)
            : NSColor(srgbRed: 0.141, green: 0.282, blue: 0.627, alpha: 1)
    })

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }
}
