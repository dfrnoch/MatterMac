import AppKit
import MatterMacUI
import SwiftUI

/// Process entry point. `SceneBuilder` cannot express "modifier on macOS 15+,
/// plain scene on macOS 14" (it only accepts `if #available` without `else`), so
/// the availability decision is made once here, before SwiftUI starts.
@main
enum MatterMacMain {
    static func main() {
        if #available(macOS 15.0, *) {
            MatterMacApp.main()
        } else {
            MatterMacLegacyApp.main()
        }
    }
}

/// macOS 15 and later: the main window scene additionally opts out of SwiftUI
/// scene restoration.
@available(macOS 15.0, *)
struct MatterMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MainWindowScene(environment: appDelegate.environment)
            .restorationBehavior(.disabled)
    }
}

/// macOS 14: restoration is disabled through AppKit only (see `AppDelegate` and
/// `WindowRestorationDisabler`).
struct MatterMacLegacyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MainWindowScene(environment: appDelegate.environment)
    }
}

/// The single main window. A `Window` (not `WindowGroup`): one window per process,
/// no "New Window" command, and nothing to restore.
struct MainWindowScene: Scene {
    static let id = "main"
    let environment: AppEnvironment

    var body: some Scene {
        Window("MatterMac", id: Self.id) {
            MatterMacRootView(environment: environment)
                .background(WindowRestorationDisabler())
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            MainWindowCommands()
            MatterMacCommands(environment: environment)
        }
    }
}

/// Window ▸ MatterMac (⌘0): reopens or focuses the main window. Closing the window
/// keeps the app running (see `AppDelegate`), and SwiftUI does not list a primary
/// `Window` scene in the Window menu by itself (verified with XCUITest).
struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("MatterMac") { openWindow(id: MainWindowScene.id) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

/// Opts the hosting `NSWindow` out of state persistence as soon as the SwiftUI
/// content is attached to it (see `NSWindow.disableStatePersistence()`).
struct WindowRestorationDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> RestorationDisablingView {
        RestorationDisablingView()
    }

    func updateNSView(_ nsView: RestorationDisablingView, context: Context) {}

    final class RestorationDisablingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.disableStatePersistence()
        }
    }
}

extension NSWindow {
    /// Keeps AppKit from persisting anything about this window: no saved
    /// application state (`isRestorable`), and no "NSWindow Frame <name>" entry in
    /// the app's preferences plist. Measured: without the autosave-name reset, the
    /// macOS 14 code path (no `.restorationBehavior`) writes the SwiftUI window
    /// frame to UserDefaults at launch.
    func disableStatePersistence() {
        isRestorable = false
        if !frameAutosaveName.isEmpty {
            setFrameAutosaveName("")
        }
    }
}
