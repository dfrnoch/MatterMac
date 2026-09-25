import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import MatterMacPlatform
import MattermostAPI
import TestSupport
@testable import MatterMacUI

/// Activity reports keep the server from turning the account "away" while the user
/// is at the Mac (the server's away timeout is 5 minutes without activity).
@MainActor
@Suite("User activity")
struct UserActivityTests {
    @Test func policyReportsActiveOnRecentInputAndInactiveOnceAfterTheAwayTimeout() {
        var policy = UserActivityPolicy()
        #expect(policy.update(idle: 2) == true)
        #expect(policy.update(idle: 30) == true, "Repeated: the realtime client throttles refreshes")
        #expect(policy.update(idle: 120) == nil, "Between thresholds nothing is sent")
        #expect(policy.update(idle: 301) == false)
        #expect(policy.update(idle: 600) == nil, "Inactive is sent once")
        #expect(policy.update(idle: 1) == true)
        #expect(policy.systemBecameInactive() == false)
        #expect(policy.systemBecameInactive() == nil)
    }

    @Test func monitorReadsTheSystemIdleTimeAndReportsChanges() {
        let monitor = UserActivityMonitor()
        // The real system reading works without any permission.
        #expect(monitor.idleTime() >= 0)
        var idle: TimeInterval = 5
        var reports: [Bool] = []
        monitor.idleTime = { idle }
        monitor.onActivity = { reports.append($0) }
        monitor.evaluate()
        idle = 400
        monitor.evaluate()
        monitor.evaluate()
        #expect(reports == [true, false])
    }

    @Test func sessionModelsForwardActivityToTheRealtimeConnection() async throws {
        _ = NSApplication.shared
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let realtime = FakeRealtimeConnection()
        let app = AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
            makeRealtime: { _, _, _ in realtime }, markupParse: { text, _ in MarkupParser.parse(text) }))
        let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
            login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
            capabilities: ServerCapabilities())
        let model = SessionViewModel(slot: slot, app: app)
        model.userActivity(isActive: true)
        model.userActivity(isActive: false)
        let deadline = ContinuousClock.now + .seconds(3)
        while await realtime.activityReports.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await realtime.activityReports == [true, false])
        model.prepareForSignOut()
        model.userActivity(isActive: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await realtime.activityReports.count == 2, "A detached model reports nothing")
        await app.registry.removeAll()
    }

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }
}
