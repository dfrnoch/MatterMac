import XCTest

/// Coordinated with an official web-client peer signed in as bob on the local QA
/// server. The peer must echo each synthetic marker with " web reply" appended.
/// Opt-in, because the normal test suite does not launch or control a browser.
final class OfficialClientInteropUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOfficialPeerChannelAndDMAfterRestart() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MM_LIVE_TESTS"] == "1", let marker = env["MM_WEB_INTEROP_MARKER"],
              marker.hasPrefix("MatterMac QA "), marker.count < 80,
              let password = env["MM_TEST_ALICE_PASSWORD"] else {
            throw XCTSkip("Requires local credentials and a coordinated official web peer marker.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-MatterMacUITesting", "YES",
                               "-MatterMacAllowInsecureLoopback", "YES"]
        defer { app.terminate() }
        func signIn() {
            app.launch()
            let server = app.textFields["Server URL"]
            XCTAssertTrue(server.waitForExistence(timeout: 20))
            server.click(); server.typeText("http://localhost:8065\r")
            XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
            app.buttons["Connect"].click()
            let passwordField = app.secureTextFields["Password"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 20))
            let login = app.textFields.firstMatch
            login.click(); login.typeText("alice")
            passwordField.click(); passwordField.typeText(password + "\r")
            XCTAssertTrue(channel("Interop").waitForExistence(timeout: 30))
        }
        func channel(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ", ")).firstMatch
        }
        func message(_ text: String) -> XCUIElement {
            app.tables["Messages"].descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        func open(_ name: String) {
            let row = channel(name)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.click()
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Message")).firstMatch.waitForExistence(timeout: 15))
        }
        func exchange(_ suffix: String) {
            let text = marker + " " + suffix
            let composer = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Message")).firstMatch
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            composer.typeText(text + "\r")
            XCTAssertTrue(message(text).waitForExistence(timeout: 20))
            XCTAssertTrue(message(text + " web reply").waitForExistence(timeout: 120), "Official peer did not reply")
        }
        signIn()
        open("Interop"); exchange("channel")
        open("bob"); exchange("dm")
        app.terminate()
        // Reauthentication must fetch canonical posts without any local history.
        signIn()
        for (name, suffix) in [("Interop", "channel"), ("bob", "dm")] {
            open(name)
            XCTAssertTrue(message(marker + " " + suffix).waitForExistence(timeout: 20))
            XCTAssertTrue(message(marker + " " + suffix + " web reply").waitForExistence(timeout: 20))
        }
    }
}
