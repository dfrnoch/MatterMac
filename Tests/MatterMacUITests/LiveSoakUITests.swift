import AppKit
import XCTest

/// Opt-in, real app process with local-test flags enabled against the repository's local test server.
/// Requires the existing Design Demo fixture (LiveSeedDemoTests). All sampling is
/// test-owned: the shipped app gets no diagnostic endpoint or automatic log.
final class LiveSoakUITests: XCTestCase {
    @MainActor
    func testNativeClientSoak() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MM_LIVE_SOAK"] == "1", let password = env["MM_TEST_ALICE_PASSWORD"],
              let path = env["MM_SOAK_APP_PATH"] else {
            throw XCTSkip("Set live-soak opt-in, local credentials and an exact built app path.")
        }
        let duration = min(21_600, max(30, Double(env["MM_SOAK_SECONDS"] ?? "7200") ?? 7200))
        let idleDuration = min(300, max(0, Double(env["MM_SOAK_IDLE_SECONDS"] ?? "300") ?? 300))
        executionTimeAllowance = duration + idleDuration + 300
        continueAfterFailure = false
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let app = XCUIApplication(url: url)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-MatterMacUITesting", "YES",
                                "-MatterMacAllowInsecureLoopback", "YES"]
        app.launch()
        defer { app.terminate() }
        try signIn(app, password: password)
        let interop = channel("Interop", app: app)
        let demo = channel("Design Demo", app: app)
        XCTAssertTrue(interop.waitForExistence(timeout: 30))
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "Seed the local Design Demo fixture first.")
        interop.click()

        var rows = ["phase,uptime_seconds,elapsed_seconds,cycle"]
        let start = ProcessInfo.processInfo.systemUptime
        var samples = 0, cycles = 0, imageOpens = 0, threadOpens = 0, searches = 0, recoveries = 0
        func sample(_ phase: String) {
            // 30-second sampling over the maximum six hours stays below this cap.
            guard samples < 1_024 else { return }
            rows.append("\(phase),\(ProcessInfo.processInfo.systemUptime),\(ProcessInfo.processInfo.systemUptime - start),\(cycles)")
            samples += 1
        }
        defer {
            rows.append("# cycles=\(cycles),image_opens=\(imageOpens),thread_opens=\(threadOpens),searches=\(searches),reconnect_buttons=\(recoveries)")
            let report = XCTAttachment(string: rows.joined(separator: "\n"))
            report.name = "native-app-soak-numeric-samples"
            report.lifetime = .keepAlways
            add(report)
        }
        if idleDuration >= 300 { Thread.sleep(forTimeInterval: 30) }
        sample("idle")
        let idleEnd = ProcessInfo.processInfo.systemUptime + idleDuration
        while ProcessInfo.processInfo.systemUptime < idleEnd {
            Thread.sleep(forTimeInterval: min(30, max(0, idleEnd - ProcessInfo.processInfo.systemUptime)))
            sample("idle")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        var lastSample = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            try autoreleasepool {
                app.activate()
                if app.buttons["Reconnect"].exists {
                    app.buttons["Reconnect"].click()
                    recoveries += 1
                }
                XCTAssertTrue(interop.waitForExistence(timeout: 30))
                interop.click()
                // Exercise member/profile lifetimes and their avatar requests.
                app.typeKey("i", modifierFlags: [.command, .shift])
                let filter = app.textFields["Filter loaded members"]
                XCTAssertTrue(filter.waitForExistence(timeout: 15))
                let bob = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", @bob")).firstMatch
                XCTAssertTrue(bob.waitForExistence(timeout: 15))
                bob.click()
                XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 10))
                XCTAssertTrue(app.popovers.firstMatch.buttons["Send Message"].waitForExistence(timeout: 10))
                app.typeKey(.escape, modifierFlags: [])
                app.typeKey("i", modifierFlags: [.command, .shift])
                XCTAssertTrue(filter.waitForNonExistence(timeout: 10))

                demo.click()
                let image = try visibleButton(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Image ")), app: app)
                image.click()
                let save = app.buttons["Save…"]
                XCTAssertTrue(save.waitForExistence(timeout: 10))
                app.typeKey("w", modifierFlags: .command)
                XCTAssertTrue(save.waitForNonExistence(timeout: 10))
                imageOpens += 1

                let replies = try visibleButton(app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ repl.*")), app: app)
                replies.click()
                XCTAssertTrue(app.staticTexts["Thread"].waitForExistence(timeout: 10))
                threadOpens += 1
                // Search replaces the thread pane and must release its image/view state.
                app.typeKey("f", modifierFlags: .command)
                let search = app.textFields["Search messages"]
                XCTAssertTrue(search.waitForExistence(timeout: 10))
                search.click()
                app.typeKey("a", modifierFlags: .command)
                search.typeText("release\r")
                XCTAssertTrue(app.buttons["Close results"].waitForExistence(timeout: 10))
                let result = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Can we freeze the release branch on Friday? :thinking:")).firstMatch
                XCTAssertTrue(result.waitForExistence(timeout: 15))
                app.buttons["Close results"].click()
                searches += 1
                interop.click()
                XCTAssertTrue(app.state == .runningForeground)
                cycles += 1
                if ProcessInfo.processInfo.systemUptime - lastSample >= 30 {
                    sample("active")
                    lastSample = ProcessInfo.processInfo.systemUptime
                }
            }
            Thread.sleep(forTimeInterval: 5)
        }
        sample("active")
        XCTAssertGreaterThan(cycles, 0)
        XCTAssertEqual(cycles, imageOpens)
        XCTAssertEqual(cycles, threadOpens)
        XCTAssertEqual(cycles, searches)
    }

    @MainActor private func visibleButton(_ query: XCUIElementQuery, app: XCUIApplication) throws -> XCUIElement {
        let table = app.tables["Messages"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        for attempt in 0..<16 {
            if let button = query.allElementsBoundByIndex.first(where: {
                let frame = $0.frame
                return $0.isHittable && !frame.isEmpty && frame.minX.isFinite && frame.minY.isFinite
                    && frame.width.isFinite && frame.height.isFinite && table.frame.intersects(frame)
            }) { return button }
            table.scroll(byDeltaX: 0, deltaY: attempt < 8 ? 400 : -400)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("The seeded attachment or reply summary could not be scrolled into view.")
        throw NSError(domain: "MatterMacSoak", code: 1)
    }

    @MainActor private func signIn(_ app: XCUIApplication, password: String) throws {
        let server = app.textFields["Server URL"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.click()
        server.typeText("http://localhost:8065\r")
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
        app.buttons["Connect"].click()
        let login = app.textFields.firstMatch
        XCTAssertTrue(login.waitForExistence(timeout: 20))
        login.click()
        login.typeText("alice")
        let secret = app.secureTextFields["Password"]
        XCTAssertTrue(secret.waitForExistence(timeout: 10))
        secret.click()
        secret.typeText(password + "\r")
    }

    @MainActor private func channel(_ label: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ", ")).firstMatch
    }

}
