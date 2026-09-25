import XCTest

/// Accessibility audit report (contrast, element descriptions, hit regions, …) of the
/// connect screen, and with the local test server, of the signed-in main window.
/// Issues are printed as `AXAUDIT` lines rather than failing the run.
final class AccessibilityAuditUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-MatterMacUITesting", "YES",
                                "-MatterMacAllowInsecureLoopback", "YES"]
        app.launch()
        return app
    }

    @MainActor
    private func audit(_ app: XCUIApplication, _ name: String) {
        do {
            try app.performAccessibilityAudit { issue in
                let description = "\(name): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(200) ?? "nil")"
                print("AXAUDIT \(description)")
                // A report for review: system elements (Touch Bar, emoji & symbols,
                // SwiftUI container groups) cannot be fixed here, so issues do not fail
                // the test. Review the AXAUDIT lines in the test log.
                return true
            }
        } catch {
            XCTFail("\(name) audit failed: \(error)")
        }
    }

    @MainActor
    func testConnectScreen() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.textFields["Server URL"].waitForExistence(timeout: 20))
        audit(app, "connect")
    }

    @MainActor
    func testSignedInMainWindow() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MM_LIVE_TESTS"] == "1", let password = env["MM_TEST_ALICE_PASSWORD"] else {
            throw XCTSkip("Set TEST_RUNNER_MM_LIVE_TESTS=1 and TEST_RUNNER_MM_TEST_ALICE_PASSWORD to run.")
        }
        let app = launch()
        defer { app.terminate() }
        let server = app.textFields["Server URL"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.click()
        server.typeText("http://localhost:8065\r")
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
        app.buttons["Connect"].click()
        let loginID = app.textFields.firstMatch
        XCTAssertTrue(loginID.waitForExistence(timeout: 20))
        audit(app, "login")
        loginID.click()
        loginID.typeText("alice")
        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.click()
        sleep(1)
        passwordField.typeText(password + "\r")
        let interop = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Interop", "Interop, ")).firstMatch
        XCTAssertTrue(interop.waitForExistence(timeout: 30))
        interop.click()
        sleep(2)
        audit(app, "channel")
        app.typeKey("i", modifierFlags: [.command, .shift])
        sleep(2)
        audit(app, "channel-info")
    }
}
