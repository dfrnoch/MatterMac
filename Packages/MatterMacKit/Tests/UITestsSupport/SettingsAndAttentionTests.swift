import AppKit
import SwiftUI
import Testing
import MatterMacModels
@testable import MatterMacCore
import MattermostAPI
import MattermostRealtime
import UserNotifications
@testable import MatterMacPlatform
import TestSupport
@testable import MatterMacUI

/// Settings window, local settings plumbing, in-app attention and the channel
/// notification sheet, against the fake service. Snapshots of the test's own windows
/// are written only when `MM_SNAPSHOT_DIR` is set (development review).
@MainActor
@Suite("Settings and attention", .serialized)
struct SettingsAndAttentionTests {
    @MainActor final class RecordingAttention: AttentionRequesting {
        var sounds: [String] = []
        var bounces = 0
        func playSound(named name: String) { sounds.append(name) }
        func requestAttention() { bounces += 1 }
    }

    @MainActor struct Harness {
        let service: FakeMattermostService
        let realtime = FakeRealtimeConnection()
        let app: AppModel
        let model: SessionViewModel
        let channel = CoreFixtures.channel(1)
        let attention = RecordingAttention()

        init(notifications: SystemNotifications? = nil, notificationsOn: Bool = true) async throws {
            let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
            let channel = channel
            var me = CoreFixtures.me
            me.notifyProps = UserNotifyProps.serverDefault
            let signedIn = me
            service.withState { state in
                state.me = signedIn
                state.teams = [CoreFixtures.team]
                state.channels[channel.id] = channel
                state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: CoreFixtures.me.id)
                state.users[CoreFixtures.bob.id] = CoreFixtures.bob
            }
            self.service = service
            let realtime = realtime
            app = AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
                makeRealtime: { _, _, _ in realtime }, markupParse: { text, _ in MarkupParser.parse(text) }))
            app.attention = attention
            if let notifications { app.notifications = notifications }
            app.environment.settings.notificationsEnabled = notificationsOn
            try await app.completeLogin(
                LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: signedIn),
                discovery: DiscoveryResult(endpoint: CoreFixtures.endpoint, version: nil, capabilities: ServerCapabilities()),
                remember: false)
            model = try #require(app.activeSession)
            let deadline = ContinuousClock.now + .seconds(3)
            while model.accountSettings?.notifications == nil || model.sidebar == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func close() async {
            model.prepareForSignOut()
            await app.registry.removeAll()
        }
    }

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }

    private func alert(_ scope: AccountScope, _ kind: IncomingMessageAlert.Kind, preview: String? = nil,
                       sound: Bool = true) -> IncomingMessageAlert {
        IncomingMessageAlert(scope: scope, channelID: CoreFixtures.channel(1).id, rootID: nil, kind: kind,
                             channelName: "Town Square", senderName: "bob", preview: preview, soundEnabled: sound)
    }

    private func settle(_ window: NSWindow?, iterations: Int = 100, until condition: () -> Bool = { false }) async throws {
        for _ in 0..<iterations {
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func snapshot(_ window: NSWindow, _ name: String) async {
        guard let directory = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] else { return }
        try? await settle(window, iterations: 30)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent(name).path]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Attention

    @Test func soundsAndBouncesFollowLocalAndServerSettings() async throws {
        let h = try await Harness()
        let settings = h.app.environment.settings
        #expect(settings.playSound && settings.bounceDockIcon && settings.showMessagePreview)
        h.app.deliver(alert(h.model.scope, .mention))
        h.app.deliver(alert(h.model.scope, .directMessage))
        h.app.deliver(alert(h.model.scope, .channelMessage))
        #expect(h.attention.sounds == [settings.soundName, settings.soundName, settings.soundName])
        // Channel-wide "all" posts do not bounce the Dock; mentions and DMs do.
        #expect(h.attention.bounces == 2)
        // The account's server-side `desktop_sound = false` silences the in-app sound.
        h.app.deliver(alert(h.model.scope, .mention, sound: false))
        #expect(h.attention.sounds.count == 3)
        settings.playSound = false
        settings.bounceDockIcon = false
        h.app.deliver(alert(h.model.scope, .mention))
        #expect(h.attention.sounds.count == 3 && h.attention.bounces == 3)
        // Alerts for accounts that are not signed in are ignored.
        settings.playSound = true
        h.app.deliver(alert(AccountScope(server: ServerSlotID(99), user: CoreFixtures.bob.id), .mention))
        #expect(h.attention.sounds.count == 3)
        #expect(h.app.notificationSounds)
        await h.close()
    }

    @Test func notificationTextIsContentFreeUnlessPreviewsAreIncluded() {
        let scope = AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id)
        let mention = AppModel.notificationContent(for: alert(scope, .mention, preview: "secret"), includePreview: false)
        #expect(mention.title == "bob mentioned you" && mention.subtitle == nil && mention.body == "in Town Square")
        let previewed = AppModel.notificationContent(for: alert(scope, .mention, preview: "secret"), includePreview: true)
        #expect(previewed.subtitle == "in Town Square" && previewed.body == "secret")
        let channel = AppModel.notificationContent(for: alert(scope, .channelMessage), includePreview: true)
        #expect(channel.title == "Town Square" && channel.body == "New message from bob")
        let direct = IncomingMessageAlert(scope: scope, channelID: CoreFixtures.channel(1).id, rootID: nil, kind: .directMessage,
                                          channelName: "bob", senderName: "bob", preview: "hi")
        let dm = AppModel.notificationContent(for: direct, includePreview: true)
        #expect(dm.title == "bob" && dm.subtitle == nil && dm.body == "hi")
        #expect(AppModel.notificationContent(for: direct, includePreview: false).body == "New direct message")
    }

    @Test func previewsReachCoreOnlyWithNotificationCenterEnabled() async throws {
        let h = try await Harness()
        h.app.setShowMessagePreview(true)
        #expect(h.app.environment.settings.showMessagePreview)
        // No app bundle here, so Notification Center stays off and Core keeps alerts text-free.
        await h.app.setNotificationsEnabled(true)
        #expect(!h.app.notificationsEnabled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.model.slot.session.alertPreviewsEnabled == false)
        await h.close()
    }

    // MARK: - Automatic notification authorization

    /// macOS's side: the current decision and the permission request.
    @MainActor final class AuthorizationCenter: NotificationCenterTransport {
        var status: SystemNotifications.Authorization
        /// The user's answer to the request; `nil` leaves it unanswered.
        let answer: Bool?
        var statusQueries = 0
        var requests = 0
        var posted = 0
        init(status: SystemNotifications.Authorization, answer: Bool? = nil) {
            self.status = status
            self.answer = answer
        }
        func authorizationStatus() async -> SystemNotifications.Authorization {
            statusQueries += 1
            return status
        }
        func requestAuthorization() async throws -> Bool {
            requests += 1
            if let answer { status = answer ? .granted : .denied }
            return answer ?? false
        }
        func add(_ request: UNNotificationRequest, completion: @escaping @Sendable () -> Void) { posted += 1 }
        func remove(identifiers: [String]?) {}
    }

    private func settleAuthorization(_ app: AppModel, _ center: AuthorizationCenter, queries: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while center.statusQueries < queries || app.notificationAuthorization == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func firstSignInAsksMacOSOnceAndDeliversWithPreviews() async throws {
        let center = AuthorizationCenter(status: .notDetermined, answer: true)
        let h = try await Harness(notifications: SystemNotifications(center: center))
        try await settleAuthorization(h.app, center, queries: 1)
        #expect(center.requests == 1)
        #expect(h.app.notificationsEnabled && h.app.notificationAuthorization == .granted)
        #expect(h.model.inlineError == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.model.slot.session.alertPreviewsEnabled == true)
        h.app.deliver(alert(h.model.scope, .mention, preview: "fixture"))
        #expect(center.posted == 1)
        // Becoming active again only reads the decision.
        h.app.refreshNotificationAuthorization()
        try await settleAuthorization(h.app, center, queries: 2)
        #expect(center.statusQueries == 2 && center.requests == 1)
        await h.close()
    }

    @Test func unansweredOrDeniedPermissionIsNotRequestedAgainThisLaunch() async throws {
        let center = AuthorizationCenter(status: .notDetermined)
        let h = try await Harness(notifications: SystemNotifications(center: center))
        try await settleAuthorization(h.app, center, queries: 1)
        #expect(center.requests == 1 && !h.app.notificationsEnabled)
        h.app.refreshNotificationAuthorization()
        try await settleAuthorization(h.app, center, queries: 2)
        #expect(center.requests == 1)
        #expect(h.app.notificationAuthorization == .notDetermined && !h.app.notificationsEnabled)
        // The saved choice stays on; Settings explains instead of an error banner.
        #expect(h.app.environment.settings.notificationsEnabled && h.model.inlineError == nil)
        #expect(NotificationSettingsTab.authorizationText(h.app.notificationAuthorization, signedIn: true) != nil)
        await h.close()

        let denied = AuthorizationCenter(status: .denied)
        let blocked = try await Harness(notifications: SystemNotifications(center: denied))
        try await settleAuthorization(blocked.app, denied, queries: 1)
        #expect(denied.requests == 0 && blocked.app.notificationAuthorization == .denied)
        #expect(!blocked.app.notificationsEnabled && blocked.model.inlineError == nil)
        blocked.app.deliver(alert(blocked.model.scope, .mention))
        #expect(denied.posted == 0)
        await blocked.close()
    }

    @Test func notificationsTurnedOffAreNeitherCheckedNorRequested() async throws {
        let center = AuthorizationCenter(status: .notDetermined, answer: true)
        let h = try await Harness(notifications: SystemNotifications(center: center), notificationsOn: false)
        h.app.refreshNotificationAuthorization()
        try await Task.sleep(for: .milliseconds(50))
        #expect(center.statusQueries == 0 && center.requests == 0)
        #expect(!h.app.notificationsEnabled && h.app.notificationAuthorization == nil)
        await h.close()
    }

    @Test func settingsExplainWhyNotificationsAreNotDelivered() {
        #expect(NotificationSettingsTab.authorizationText(.denied, signedIn: true)?.contains("System Settings") == true)
        #expect(NotificationSettingsTab.authorizationText(.notDetermined, signedIn: true) != nil)
        #expect(NotificationSettingsTab.authorizationText(nil, signedIn: false) != nil)
        #expect(NotificationSettingsTab.authorizationText(nil, signedIn: true) == nil)
        #expect(NotificationSettingsTab.authorizationText(.granted, signedIn: true) == nil)
    }

    // MARK: - Local settings plumbing

    @Test func conversationPanesFollowTextSizeSendBehaviorAndServerClock() async throws {
        let h = try await Harness()
        defer { TimelineStrings.clockOverride = nil }
        let settings = h.app.environment.settings
        h.model.select(channel: h.channel.id)
        let controller = ConversationController(session: h.model, target: .channel(h.channel.id))
        #expect(controller.timeline.fontScale == 1)
        settings.textSize = .large
        try await settle(nil) { controller.timeline.fontScale == LocalSettings.TextSize.large.scale }
        #expect(controller.timeline.fontScale == LocalSettings.TextSize.large.scale)
        settings.sendBehavior = .commandReturnSends
        try await settle(nil) { controller.composer.sendBehavior == .commandReturnSends }
        #expect(controller.composer.sendBehavior == .commandReturnSends)
        #expect(h.app.environment.sendBehavior == .commandReturnSends)

        #expect(controller.timeline.uses24HourClock == nil)
        try await h.model.setMilitaryTime(true)
        try await settle(nil) { controller.timeline.uses24HourClock == true }
        #expect(controller.timeline.uses24HourClock == true)
        let afternoon = MattermostTimestamp(date: Date(timeIntervalSince1970: 13 * 3_600 + 5 * 60))
        TimelineStrings.clockOverride = true
        let twentyFour = TimelineStrings.time(afternoon)
        TimelineStrings.clockOverride = false
        let twelve = TimelineStrings.time(afternoon)
        #expect(twentyFour != twelve)
        #expect(!twentyFour.contains(Calendar.current.pmSymbol))
        #expect(twelve.contains(Calendar.current.pmSymbol))
        settings.textSize = .standard
        settings.sendBehavior = .returnSends
        await h.close()
    }

    @Test func appearanceOverrideAppliesToTheAppOnly() {
        let settings = LocalSettings()
        settings.appearance = .dark
        #expect(NSApplication.shared.appearance?.name == .darkAqua)
        settings.appearance = .light
        #expect(NSApplication.shared.appearance?.name == .aqua)
        settings.appearance = .system
        #expect(NSApplication.shared.appearance == nil)
    }

    // MARK: - Windows

    @Test func settingsTabsRenderLocalAndServerSections() async throws {
        let h = try await Harness()
        let previous = h.app.environment.appModel
        h.app.environment.appModel = h.app
        defer { h.app.environment.appModel = previous }
        let tabs: [(String, AnyView)] = [
            ("settings-general.png", AnyView(GeneralSettingsTab(environment: h.app.environment))),
            ("settings-notifications.png", AnyView(NotificationSettingsTab(environment: h.app.environment))),
            ("settings-appearance.png", AnyView(AppearanceSettingsTab(settings: h.app.environment.settings))),
            ("settings-accounts.png", AnyView(AccountsSettingsTab(environment: h.app.environment))),
            ("settings-window.png", AnyView(MatterMacSettingsView(environment: h.app.environment))),
        ]
        for (name, view) in tabs {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentViewController = NSHostingController(rootView: view.frame(width: 540, height: 560))
            window.orderFrontRegardless()
            try await settle(window, iterations: 20)
            await snapshot(window, name)
            window.close()
        }
        // Without a session the server sections only offer a sign-in hint.
        let empty = AppEnvironment(serviceFactory: Factory(fake: h.service),
                                   makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MatterMacSettingsView(environment: empty))
        window.orderFrontRegardless()
        try await settle(window, iterations: 20)
        await snapshot(window, "settings-signed-out.png")
        window.close()
        await h.close()
    }

    @Test func channelNotificationSheetPresentsOnceAndSavesExplicitChanges() async throws {
        let h = try await Harness()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.orderFrontRegardless()
        defer { window.close() }
        let sheet = try #require(ChannelNotificationSheet.present(session: h.model, channel: h.channel.id, on: window))
        try await settle(window) { window.attachedSheet === sheet }
        #expect(window.attachedSheet === sheet)
        #expect(ChannelNotificationSheet.present(session: h.model, channel: h.channel.id, on: window) == nil)
        try await settle(sheet, iterations: 30)
        await snapshot(sheet, "channel-notification-preferences.png")
        window.endSheet(sheet)
        try await settle(window) { window.attachedSheet == nil }

        let revision = h.model.channelInfoRevision
        try await h.model.setChannelNotificationPreferences(h.channel.id, desktop: .mention, muted: false,
                                                            ignoreChannelMentions: .on)
        #expect(h.model.channelInfoRevision != revision)
        let change = try #require(h.service.withState { $0.channelNotifyChanges.last })
        #expect(change.1 == ChannelNotifyPropsChange(desktop: .mention, ignoreChannelMentions: .on))
        await h.close()
    }
}
