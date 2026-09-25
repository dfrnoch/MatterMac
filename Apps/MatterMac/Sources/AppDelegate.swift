import AppKit
import MatterMacUI
import MatterMacPlatform

/// Application lifecycle hooks (installed through `@NSApplicationDelegateAdaptor`).
/// Owns the single `AppEnvironment` for the process so the scene and the
/// termination path share one instance without a global.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created on first use (the scene body); lives until the process exits.
    private(set) lazy var environment: AppEnvironment = AppComposition.makeEnvironment()
    private let events = SystemEventMonitor()
    private let activity = UserActivityMonitor()
    private let splitViewPersistence = SplitViewPersistenceGuard()
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Catch-all for windows that do not host `MatterMacRootView` (e.g. the About
        // panel). The observer lives as long as the delegate, i.e. the process.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows {
            window.disableStatePersistence()
        }
        events.onWake = { [weak self] in
            for model in self?.environment.appModel?.sessionModels.values ?? [:].values { model.systemDidWake() }
        }
        events.onNetworkPathChange = { [weak self] _ in
            for model in self?.environment.appModel?.sessionModels.values ?? [:].values { model.networkPathChanged() }
        }
        events.onActivationChange = { [weak self] isActive in
            self?.updateVisibility()
            if isActive { self?.activity.evaluate() }
        }
        events.start()
        // Without activity reports the server turns the account "away" after ~5 min.
        activity.onActivity = { [weak self] isActive in
            for model in self?.environment.appModel?.sessionModels.values ?? [:].values {
                model.userActivity(isActive: isActive)
            }
        }
        activity.start()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            window.disableStatePersistence()
        }
        updateVisibility()
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) { updateVisibility() }

    private func updateVisibility() {
        guard let app = environment.appModel else { return }
        let visible = NSApp.windows.contains { $0.canBecomeMain && $0.occlusionState.contains(.visible) }
        for model in app.sessionModels.values {
            model.updateAppState(isActive: NSApp.isActive && model === app.activeSession,
                                 isWindowVisible: visible && model === app.activeSession)
        }
    }

    /// Opts in to secure restorable-state coding (silences AppKit's insecure-coding
    /// warning). MatterMac never encodes any state: it implements no
    /// `application(_:willEncodeRestorableState:)` and every window is
    /// non-restorable.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Warns before discarding RAM-only drafts or unconfirmed sends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard environment.confirmTermination() == .terminateNow else { return .terminateCancel }
        terminating = true
        events.stop()
        activity.stop()
        Task {
            await environment.appModel?.shutdownAll(preservingSavedSignIns: true)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Standard macOS behavior: closing the window keeps the app (and its
    /// in-memory session) running; Window ▸ MatterMac (⌘0) reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}
