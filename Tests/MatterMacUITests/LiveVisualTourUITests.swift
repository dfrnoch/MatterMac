import XCTest

/// Opt-in visual tour against the local test server: captures the app window (only)
/// in its main states as test attachments for design review. Same environment as
/// `LiveMemberListUITests`.
final class LiveVisualTourUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureMainStates() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MM_LIVE_TESTS"] == "1", let password = env["MM_TEST_ALICE_PASSWORD"] else {
            throw XCTSkip("Set TEST_RUNNER_MM_LIVE_TESTS=1 and TEST_RUNNER_MM_TEST_ALICE_PASSWORD to run.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-MatterMacUITesting", "YES",
                                "-MatterMacAllowInsecureLoopback", "YES"]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        func capture(_ name: String) {
            app.activate()
            sleep(2)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let server = app.textFields["Server URL"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        capture("01-connect")
        server.click()
        server.typeText("http://localhost:8065\r")
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
        app.buttons["Connect"].click()
        let loginID = app.textFields.firstMatch
        XCTAssertTrue(loginID.waitForExistence(timeout: 20))
        loginID.click()
        loginID.typeText("alice")
        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.click()
        sleep(1)
        passwordField.typeText(password + "\r")
        let interop = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Interop", "Interop, ")).firstMatch
        if !interop.waitForExistence(timeout: 30) { capture("00-signin-failure") }
        XCTAssertTrue(interop.exists)
        interop.click()
        capture("02-channel")
        app.typeKey("i", modifierFlags: [.command, .shift])
        capture("03-channel-info")
        app.typeKey("i", modifierFlags: [.command, .shift])
        app.typeKey("t", modifierFlags: [.command, .shift])
        capture("04-threads")
        app.typeKey("t", modifierFlags: [.command, .shift])
        app.typeKey("k", modifierFlags: .command)
        capture("05-quick-switcher")
        app.typeKey(.escape, modifierFlags: [])
        // Seeded content (MM_SEED_DEMO): rendering, reactions, image, thread, search.
        let demo = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Design Demo", "Design Demo, ")).firstMatch
        if demo.waitForExistence(timeout: 5) {
            demo.click()
            capture("06-design-demo")
            let replies = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "repl")).firstMatch
            if replies.waitForExistence(timeout: 5) {
                replies.click()
                capture("07-thread")
            }
            app.typeKey("f", modifierFlags: .command)
            app.typeText("release")
            app.typeKey(.return, modifierFlags: [])
            capture("08-search")
        }
        app.typeKey(",", modifierFlags: .command)
        sleep(2)
        let settings = app.windows.element(boundBy: 0)
        let shot = XCTAttachment(screenshot: settings.screenshot())
        shot.name = "09-settings"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
