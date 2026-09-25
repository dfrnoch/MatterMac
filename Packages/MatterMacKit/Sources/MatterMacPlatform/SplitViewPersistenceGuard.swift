import AppKit
public import Foundation

/// SwiftUI assigns autosave names to scene-owned split views even when scene and
/// window restoration are disabled. Clear the name before AppKit resizes/saves.
/// One process-lifetime observer also covers split views created after sign-in or
/// when a thread/search pane appears; no polling, defaults access or stored frames.
@MainActor
public final class SplitViewPersistenceGuard: NSObject {
    public override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(willResize(_:)),
            name: NSSplitView.willResizeSubviewsNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func willResize(_ notification: Notification) {
        guard let split = notification.object as? NSSplitView, split.autosaveName != nil else { return }
        split.autosaveName = nil
    }
}
