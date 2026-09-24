import XCTest

/// First-launch connect screen (SPEC §4, Milestone 0). These tests only exercise
/// local URL validation/normalization: no server request is made, and nothing
/// is typed that resembles a credential.
final class FirstLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Argument domain only (in memory): never reopen saved window state.
        // UI-testing mode: no Keychain sign-ins are restored, so the connect screen
        // always appears and the developer's real accounts are never used.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-MatterMacUITesting", "YES"] + extraArguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "main window did not appear")
        return app
    }

    @MainActor
    private func serverField(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["Server URL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "server URL field missing")
        return field
    }

    /// SwiftUI `Text` on macOS exposes its string as the accessibility *value*
    /// (the label is empty), so prefix matches check both.
    @MainActor
    private func staticText(in app: XCUIApplication, beginningWith prefix: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix))
            .firstMatch
    }

    /// Replaces the field's contents and submits with Return.
    @MainActor
    private func submit(_ text: String, in field: XCUIElement) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text + "\r")
    }

    @MainActor
    func testFirstLaunchShowsBrandingServerFieldAndDisclosure() throws {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["MatterMac"].firstMatch.waitForExistence(timeout: 10))
        _ = serverField(in: app)

        let disclosure = app.staticTexts["sessionDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10), "session-only disclosure missing")
        let disclosureText = (disclosure.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? disclosure.label
        XCTAssertTrue(
            disclosureText.contains("Messages and drafts stay in memory only"),
            "unexpected disclosure text: \(disclosureText)")

        XCTAssertFalse(app.buttons["Continue"].isEnabled, "Continue must be disabled while the field is empty")
    }

    @MainActor
    func testUnsupportedSchemeShowsError() throws {
        let app = launchApp()
        submit("ftp://x", in: serverField(in: app))

        let error = app.staticTexts["Only https:// server addresses are supported."]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "no validation error for ftp:// address")
        XCTAssertFalse(staticText(in: app, beginningWith: "Will connect to").exists, "invalid address was normalized")
    }

    @MainActor
    func testSubpathAddressShowsNormalizedOriginWithoutConnecting() throws {
        let app = launchApp()
        let field = serverField(in: app)

        submit("ftp://x", in: field)
        XCTAssertTrue(app.staticTexts["Only https:// server addresses are supported."].waitForExistence(timeout: 10))

        submit("https://chat.example.org/company/chat", in: field)
        let normalized = app.staticTexts["Will connect to https://chat.example.org/company/chat"]
        XCTAssertTrue(normalized.waitForExistence(timeout: 10), "normalized origin not shown")
        XCTAssertFalse(app.staticTexts["Only https:// server addresses are supported."].exists, "stale error still visible")
    }

    /// UI tests run the Debug configuration. Without the development launch
    /// argument, plain HTTP is rejected even for loopback hosts.
    @MainActor
    func testPlainHTTPLoopbackRejectedWithoutDevelopmentArgument() throws {
        let app = launchApp()
        submit("http://localhost:8065", in: serverField(in: app))

        let error = staticText(in: app, beginningWith: "Plain http:// is not allowed")
        XCTAssertTrue(error.waitForExistence(timeout: 10), "no error for plain HTTP without the development argument")
        XCTAssertFalse(staticText(in: app, beginningWith: "Will connect to").exists, "plain HTTP loopback accepted")
    }

    /// `-MatterMacAllowInsecureLoopback YES` (DEBUG builds only) permits plain HTTP
    /// to a loopback host for this launch.
    @MainActor
    func testPlainHTTPLoopbackAllowedWithDevelopmentArgument() throws {
        let app = launchApp(extraArguments: ["-MatterMacAllowInsecureLoopback", "YES"])
        submit("http://localhost:8065", in: serverField(in: app))

        XCTAssertTrue(app.staticTexts["Will connect to http://localhost:8065"].waitForExistence(timeout: 10))
    }

    /// Closing the only window keeps the process (and any in-memory session)
    /// alive; the Window menu reopens the single `Window` scene.
    @MainActor
    func testClosingWindowKeepsAppRunningAndWindowMenuReopensIt() throws {
        let app = launchApp()
        _ = serverField(in: app)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 10), "window did not close")
        XCTAssertNotEqual(app.state, .notRunning, "app quit after its last window closed")

        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems.matching(NSPredicate(format: "title == %@", "MatterMac")).firstMatch.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Window menu did not reopen the main window")
        _ = serverField(in: app)

        // ⌘0 (same command) with the window open focuses it instead of adding one.
        app.typeKey("0", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 1, "the main window must stay unique")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 10))
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "⌘0 did not reopen the main window")
    }

    /// A reopen event (Dock click / `open`) brings the existing window back.
    @MainActor
    func testReopenEvent() throws {
        let app = launchApp()
        _ = serverField(in: app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 10))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // Several recovered builds share the bundle ID. Reopen the app next to
        // this test runner, rather than letting Launch Services choose another copy.
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("MatterMac.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        p.arguments = [appURL.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "reopen event did not reopen window")
    }
}
