import XCTest

/// The Settings scene (⌘,) in the real app, signed out. Nothing is toggled that
/// would ask macOS for notification permission or change a server.
final class SettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsOpensWithCommandCommaAndSeparatesLocalAndServerSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-MatterMacUITesting", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "main window did not appear")

        app.typeKey(",", modifierFlags: .command)
        let hint = app.staticTexts["settingsSignInHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "Settings did not open or lacks the sign-in hint")
        XCTAssertTrue(app.popUpButtons["sendBehaviorPicker"].exists || app.buttons["sendBehaviorPicker"].exists,
                      "local send behavior setting missing")
        let local = app.descendants(matching: .any)["localSettingsHeader"]
        XCTAssertTrue(local.exists, "local-settings header missing")
        XCTAssertTrue("\(local.label) \(local.value ?? "")".contains("Saved on this Mac"),
                      "local-settings disclosure missing: \(local.label)")
        XCTAssertTrue(app.descendants(matching: .any)["serverSettingsHeader"].exists, "server-settings header missing")

        app.toolbars.buttons["Notifications"].click()
        XCTAssertTrue(app.switches["notificationCenterToggle"].waitForExistence(timeout: 5)
                      || app.checkBoxes["notificationCenterToggle"].exists, "Notification Center opt-in missing")
        XCTAssertTrue(app.staticTexts["settingsSignInHint"].exists, "server notification settings shown while signed out")

        app.toolbars.buttons["Appearance"].click()
        XCTAssertTrue(app.descendants(matching: .any)["textSizePicker"].waitForExistence(timeout: 5), "text size missing")

        app.toolbars.buttons["Accounts"].click()
        let privacy = app.staticTexts["accountsPrivacyNote"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), "privacy note missing")
        let note = (privacy.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? privacy.label
        XCTAssertTrue(note.contains("Keychain"), "unexpected privacy note: \(note)")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(privacy.waitForNonExistence(timeout: 5), "Settings did not close")
    }
}
