import XCTest

/// Opt-in: drives the real app against the repository-owned local test server
/// (`http://localhost:8065`, user alice). Pass the environment to the test runner
/// with `TEST_RUNNER_MM_LIVE_TESTS=1` and `TEST_RUNNER_MM_TEST_ALICE_PASSWORD`
/// (sourced from the ignored `.local/test-server.env`, never on the command line).
/// UI-testing mode keeps saved sign-ins out of Keychain.
final class LiveMemberListUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChannelInfoMembersAndProfileStayResponsive() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MM_LIVE_TESTS"] == "1", let password = env["MM_TEST_ALICE_PASSWORD"] else {
            throw XCTSkip("Set TEST_RUNNER_MM_LIVE_TESTS=1 and TEST_RUNNER_MM_TEST_ALICE_PASSWORD to run.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-MatterMacUITesting", "YES",
                                "-MatterMacAllowInsecureLoopback", "YES"]
        app.launch()
        defer { app.terminate() }

        let server = app.textFields["Server URL"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.click()
        server.typeText("http://localhost:8065\r")
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.click()

        let loginID = app.textFields.firstMatch
        XCTAssertTrue(loginID.waitForExistence(timeout: 20))
        loginID.click()
        loginID.typeText("alice")
        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.click()
        sleep(1)
        passwordField.typeText(password + "\r")

        let interop = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Interop", "Interop, ")).firstMatch
        XCTAssertTrue(interop.waitForExistence(timeout: 30), "sidebar did not load")
        interop.click()

        app.typeKey("i", modifierFlags: [.command, .shift])
        let members = app.textFields["Filter loaded members"].firstMatch
        let found = members.waitForExistence(timeout: 20)
        if !found { add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot())) }
        XCTAssertTrue(found, "members section missing")
        let bob = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", @bob")).firstMatch
        XCTAssertTrue(bob.waitForExistence(timeout: 20), "member row missing")
        sleep(3)
        // Still responsive: the menu bar opens and the profile popover appears.
        app.menuBars.menuBarItems["Go"].click()
        XCTAssertTrue(app.menuBars.menuItems["Quick Switcher…"].waitForExistence(timeout: 10), "app unresponsive")
        app.typeKey(.escape, modifierFlags: [])
        bob.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 15), "profile popover missing")
        let card = popover.buttons["Send Message"].firstMatch
        let loaded = card.waitForExistence(timeout: 15)
        if !loaded { add(XCTAttachment(screenshot: popover.screenshot())) }
        XCTAssertTrue(loaded, "profile card did not load")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(members.waitForNonExistence(timeout: 10), "channel info did not close")
    }
}
