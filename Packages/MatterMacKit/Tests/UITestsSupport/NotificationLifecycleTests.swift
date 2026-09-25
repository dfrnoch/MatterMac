import Foundation
import UserNotifications
import Testing
import MatterMacModels
import TestSupport
import MatterMacCore
import MattermostAPI
@testable import MatterMacPlatform
@testable import MatterMacUI

@MainActor
@Suite("Notification lifecycle", .serialized)
struct NotificationLifecycleTests {
    final class Center: NotificationCenterTransport {
        var lastInfo: [AnyHashable: Any] = [:]
        var delivered: Set<String> = []
        var pending: Set<String> = []
        var completions: [String: @Sendable () -> Void] = [:]
        var authorization: CheckedContinuation<Bool, Never>?
        func requestAuthorization() async throws -> Bool {
            await withCheckedContinuation { authorization = $0 }
        }
        func add(_ request: UNNotificationRequest, completion: @escaping @Sendable () -> Void) {
            lastInfo = request.content.userInfo
            pending.insert(request.identifier)
            completions[request.identifier] = completion
        }
        func finish(_ identifier: String) {
            pending.remove(identifier)
            delivered.insert(identifier)
            completions.removeValue(forKey: identifier)?()
        }
        func remove(identifiers: [String]?) {
            if let identifiers {
                delivered.subtract(identifiers)
                pending.subtract(identifiers)
            } else {
                delivered.removeAll()
                pending.removeAll()
            }
        }
    }

    private struct Factory: MattermostServiceFactory {
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("Unused") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fatalError("Unused") }
    }
    private func makeApp() -> AppModel {
        AppModel(environment: AppEnvironment(serviceFactory: Factory(),
            makeRealtime: { _, _, _ in FakeRealtimeConnection() },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
    }

    let target = SystemNotifications.Target(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id), channel: CoreFixtures.channel(1).id, root: nil)

    @Test func evictionAndSignOutWithdrawEveryNotificationIncludingLateDelivery() async throws {
        let center = Center()
        let notifications = SystemNotifications(center: center)
        for _ in 0...SystemNotifications.trackedPerAccount {
            notifications.post(title: "Fixture", body: "Fixture", target: target, sound: false)
        }
        #expect(center.pending.count == SystemNotifications.trackedPerAccount)
        let ids = Array(center.completions.keys)
        notifications.removeDelivered(scope: target.scope)
        #expect(center.pending.isEmpty)
        for id in ids { center.finish(id) }
        // Completion cleanup is dispatched to the main actor, like the native API.
        for _ in 0..<100 where !center.delivered.isEmpty { await Task.yield() }
        #expect(center.delivered.isEmpty)
    }

    @Test func deliveredHistoryIsBoundedAndSignOutPreservesOtherAccounts() {
        let center = Center()
        let notifications = SystemNotifications(center: center)
        for _ in 0...SystemNotifications.trackedPerAccount {
            notifications.post(title: "Fixture", body: "Fixture", target: target, sound: false)
            center.finish(center.pending.first!)
        }
        #expect(center.delivered.count == SystemNotifications.trackedPerAccount)
        let other = SystemNotifications.Target(scope: AccountScope(server: ServerSlotID(2), user: CoreFixtures.me.id),
            channel: target.channel, root: nil)
        notifications.post(title: "Other", body: "Other", target: other, sound: false)
        let otherID = center.pending.first!
        center.finish(otherID)
        notifications.removeDelivered(scope: target.scope)
        #expect(center.delivered == [otherID])
        notifications.removeDelivered()
        #expect(center.delivered.isEmpty)
    }

    @Test func previousInstanceCannotNavigateReusedAccountSlot() throws {
        let oldCenter = Center(), newCenter = Center()
        let previous = SystemNotifications(center: oldCenter)
        let current = SystemNotifications(center: newCenter)
        previous.post(title: "Fixture", body: "Fixture", target: target, sound: false)
        current.post(title: "Fixture", body: "Fixture", target: target, sound: false)
        let currentID = try #require(newCenter.lastInfo["instance"] as? String)
        #expect(SystemNotifications.target(from: newCenter.lastInfo, instanceID: currentID) == target)
        #expect(SystemNotifications.target(from: oldCenter.lastInfo, instanceID: currentID) == nil)
        var legacy = oldCenter.lastInfo
        legacy["instance"] = nil
        #expect(SystemNotifications.target(from: legacy, instanceID: currentID) == nil)
    }

    @Test func shutdownWithdrawsDeliveredAndPendingNotifications() async {
        let center = Center()
        let app = makeApp()
        app.notifications = SystemNotifications(center: center)
        app.notifications.post(title: "Fixture", body: "Fixture", target: target, sound: false)
        let id = center.pending.first!
        center.finish(id)
        await app.shutdownAll()
        #expect(center.delivered.isEmpty && center.pending.isEmpty)
    }

    @Test(arguments: [false, true]) func lateAuthorizationCannotUndoDisableOrShutdown(shutdown: Bool) async {
        let center = Center()
        let app = makeApp()
        app.notifications = SystemNotifications(center: center)
        let enabling = Task { await app.setNotificationsEnabled(true) }
        while center.authorization == nil { await Task.yield() }
        if shutdown { await app.shutdownAll() }
        else { await app.setNotificationsEnabled(false) }
        center.authorization?.resume(returning: true)
        await enabling.value
        #expect(!app.notificationsEnabled)
    }
}
