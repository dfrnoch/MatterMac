import XCTest

/// Opt-in visual tour against the local test server: captures the app window (only)
/// in its main states as test attachments for design review. Same environment as
/// `LiveMemberListUITests`.
final class LiveVisualTourUITests: XCTestCase {
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
        app.buttons["Connect"].click()
        let loginID = app.textFields.firstMatch
        XCTAssertTrue(loginID.waitForExistence(timeout: 20))
        loginID.click()
        loginID.typeText("alice")
        let passwordField = app.secureTextFields["Password"]
        passwordField.click()
        passwordField.typeText(password + "\r")
        let interop = app.staticTexts["Interop"].firstMatch
        XCTAssertTrue(interop.waitForExistence(timeout: 30))
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
    }
}
