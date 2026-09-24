public import AppKit
public import Observation
import MatterMacPlatform

/// MatterMac's own presentation and attention settings. They live in memory only and
/// reset when the app quits (SPEC §19: appearance, text size, sound and the
/// notification opt-in are local session settings). Nothing here is written to
/// `UserDefaults` or to the server.
@MainActor
@Observable
public final class LocalSettings {
    public enum TextSize: String, CaseIterable, Identifiable, Sendable {
        case small, standard, large, extraLarge
        public var id: String { rawValue }
        /// Timeline font scale (applied to the system body font).
        public var scale: CGFloat {
            switch self {
            case .small: 0.9
            case .standard: 1
            case .large: 1.15
            case .extraLarge: 1.3
            }
        }
    }

    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
    }

    /// Return vs ⌘Return in the composer.
    public var sendBehavior: AppEnvironment.SendBehaviorSetting = .returnSends
    public var textSize: TextSize = .standard
    public var appearance: Appearance = .system {
        didSet { if oldValue != appearance { applyAppearance() } }
    }
    /// Plays `soundName` for incoming alerts (with or without Notification Center).
    public var playSound = true
    public var soundName: String = SystemSounds.defaultName
    /// Bounce the Dock icon once for mentions and direct messages while inactive.
    public var bounceDockIcon = true
    /// Explicit opt-in: include up to 100 characters of message text in Notification
    /// Center alerts. Off by default.
    public var showMessagePreview = false

    public init() {}

    public var fontScale: CGFloat { textSize.scale }

    /// Overrides the app's appearance (not the system's) for this run only.
    func applyAppearance() {
        let app = NSApplication.shared
        switch appearance {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
