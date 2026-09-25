public import AppKit
import CoreGraphics

/// When to report the user as active or inactive, from the Mac's input idle time.
/// Mattermost sets an account "away" once `UserStatusAwayTimeout` (default 300 s)
/// passes without activity, and only a connect, a post, a manual status change or
/// `user_update_active_status` counts (docs/research/websocket.md §7). Like the
/// Desktop App, activity is any keyboard, mouse or trackpad input on the Mac, not
/// only in MatterMac.
public struct UserActivityPolicy: Sendable, Hashable {
    /// Input within this interval counts as active.
    public var activeWithin: TimeInterval = 60
    /// Idle this long reports inactive once (the server's default away timeout).
    public var inactiveAfter: TimeInterval = 300
    public private(set) var isActive: Bool?

    public init() {}

    /// The report to send for `idle` seconds without input, if any. Active is
    /// reported every time; the realtime client throttles repeated refreshes.
    public mutating func update(idle: TimeInterval) -> Bool? {
        if idle < activeWithin {
            isActive = true
            return true
        }
        guard idle >= inactiveAfter, isActive != false else { return nil }
        isActive = false
        return false
    }

    /// The screen slept or locked, or the Mac is going to sleep.
    public mutating func systemBecameInactive() -> Bool? {
        guard isActive != false else { return nil }
        isActive = false
        return false
    }
}

/// Polls the system input idle time (no permission needed) every 15 seconds and
/// reports activity changes; the screen sleeping or locking reports inactive at once.
@MainActor
public final class UserActivityMonitor {
    public var onActivity: ((_ isActive: Bool) -> Void)?
    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    public var idleTime: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: UserActivityMonitor.anyInput)
    }
    public private(set) var policy = UserActivityPolicy()
    public static let pollInterval: TimeInterval = 15
    /// `kCGAnyInputEventType`.
    nonisolated static let anyInput = CGEventType(rawValue: ~0)!

    private var timer: Timer?
    private var observers: [any NSObjectProtocol] = []

    public init() {}

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemBecameInactive() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        evaluate()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    /// Checks the idle time now (also called when MatterMac becomes active).
    public func evaluate() {
        if let report = policy.update(idle: idleTime()) { onActivity?(report) }
    }

    private func systemBecameInactive() {
        if let report = policy.systemBecameInactive() { onActivity?(report) }
    }
}
