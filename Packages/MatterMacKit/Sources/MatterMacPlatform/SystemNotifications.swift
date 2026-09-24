import AppKit
public import Foundation
public import MatterMacModels
import UserNotifications

/// Opt-in Notification Center delivery (SPEC §19). Authorization is requested only
/// after the user explicitly enables notifications; nothing is requested at launch.
/// Notifications carry a sender and conversation name but never message text, and
/// only the conversation identity is attached so a click can open it. Delivery
/// stops (and delivered notifications are removed) when the user turns it off or
/// the process ends; there is no push service after quitting.
@MainActor
public final class SystemNotifications: NSObject {
    /// Where a clicked notification should navigate.
    public struct Target: Sendable, Hashable {
        public let scope: AccountScope
        public let channel: ChannelID
        public let root: PostID?

        public init(scope: AccountScope, channel: ChannelID, root: PostID?) {
            self.scope = scope
            self.channel = channel
            self.root = root
        }
    }

    public enum Authorization: Sendable, Hashable {
        case granted
        case denied
        /// No app bundle (for example a command-line test host).
        case unavailable
    }

    public var onOpen: ((Target) -> Void)?
    /// Request identifiers posted per account, so sign-out can withdraw them (bounded).
    private var posted: [AccountScope: [String]] = [:]
    static let trackedPerAccount = 64
    private lazy var delegate = NotificationDelegate { [weak self] target in self?.onOpen?(target) }
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    public override init() {
        super.init()
    }

    public func requestAuthorization() async -> Authorization {
        guard let center else { return .unavailable }
        center.delegate = delegate
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge]) ? .granted : .denied
        } catch {
            return .denied
        }
    }

    public func post(title: String, body: String, target: Target, sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(128))
        content.body = String(body.prefix(256))
        content.threadIdentifier = target.channel.rawValue
        if sound { content.sound = .default }
        var info: [String: String] = [
            "server": String(target.scope.server.rawValue), "user": target.scope.user.rawValue,
            "channel": target.channel.rawValue,
        ]
        if let root = target.root { info["root"] = root.rawValue }
        content.userInfo = info
        let identifier = UUID().uuidString
        var ids = posted[target.scope, default: []]
        if ids.count >= Self.trackedPerAccount { ids.removeFirst() }
        ids.append(identifier)
        posted[target.scope] = ids
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Removes delivered notifications for one account (sign-out) or all of them.
    public func removeDelivered(scope: AccountScope? = nil) {
        guard let center else { return }
        if let scope {
            center.removeDeliveredNotifications(withIdentifiers: posted.removeValue(forKey: scope) ?? [])
        } else {
            center.removeAllDeliveredNotifications()
            posted.removeAll()
        }
    }

    fileprivate nonisolated static func target(from info: [AnyHashable: Any]) -> Target? {
        guard let server = (info["server"] as? String).flatMap(UInt64.init),
              let user = (info["user"] as? String).flatMap(UserID.init(rawValue:)),
              let channel = (info["channel"] as? String).flatMap(ChannelID.init(rawValue:)) else { return nil }
        return Target(scope: AccountScope(server: ServerSlotID(server), user: user), channel: channel,
                      root: (info["root"] as? String).flatMap(PostID.init(rawValue:)))
    }
}

/// Kept separate so the public type does not expose UserNotifications.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let open: @MainActor @Sendable (SystemNotifications.Target) -> Void

    init(open: @escaping @MainActor @Sendable (SystemNotifications.Target) -> Void) {
        self.open = open
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let target = SystemNotifications.target(from: response.notification.request.content.userInfo) else { return }
        let open = self.open
        await MainActor.run {
            NSApp.activate()
            open(target)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        // Core already suppresses the conversation the user is looking at.
        [.banner, .sound]
    }
}
