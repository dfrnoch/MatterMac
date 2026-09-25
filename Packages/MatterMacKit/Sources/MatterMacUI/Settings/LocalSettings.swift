public import AppKit
public import Observation
public import MatterMacPlatform

/// Where "On This Mac" settings are saved between launches. The app passes
/// `UserDefaults.standard`; tests and `-MatterMacUITesting` pass nothing (memory
/// only) or a private in-memory store.
public protocol LocalSettingsStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: LocalSettingsStorage {}

/// MatterMac's own presentation and attention settings (Settings › "On This Mac").
/// At the user's request (2026-09-25, decision 0032) they are saved on this Mac in
/// the injected storage under `MatterMac.*` keys: small typed values only, validated
/// on load (anything unknown falls back to the default). Nothing here is sent to the
/// server, and no message content, draft or account data is ever stored here.
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

    /// Storage keys (namespaced; values are `Bool` or a known `String`).
    enum Key: String, CaseIterable {
        case sendBehavior = "MatterMac.sendBehavior"
        case textSize = "MatterMac.textSize"
        case appearance = "MatterMac.appearance"
        case notificationsEnabled = "MatterMac.notificationsEnabled"
        case showMessagePreview = "MatterMac.showMessagePreview"
        case playSound = "MatterMac.playSound"
        case soundName = "MatterMac.soundName"
        case bounceDockIcon = "MatterMac.bounceDockIcon"
        case checksForUpdates = "MatterMac.checksForUpdates"
        case updateChannel = "MatterMac.updateChannel"
        /// Versioned JSON `Data` (`AppTheme`), at most `AppTheme.maximumStoredBytes`.
        case theme = "MatterMac.theme"
    }

    /// Window theme (Settings › Appearance). Applies live to every window; invalid
    /// saved data loads as `.system` (decision 0035).
    public var theme: AppTheme = .system {
        didSet {
            guard oldValue != theme, isLoaded, let data = theme.storageData() else { return }
            storage?.set(data, forKey: Key.theme.rawValue)
        }
    }

    /// Return vs ⌘Return in the composer.
    public var sendBehavior: AppEnvironment.SendBehaviorSetting = .returnSends {
        didSet { save(.sendBehavior, sendBehavior.rawValue) }
    }
    public var textSize: TextSize = .standard {
        didSet { save(.textSize, textSize.rawValue) }
    }
    public var appearance: Appearance = .system {
        didSet {
            if oldValue != appearance { applyAppearance() }
            save(.appearance, appearance.rawValue)
        }
    }
    /// The user's Notification Center choice (on by default). Delivery also needs
    /// macOS authorization; see `AppModel.notificationsEnabled`.
    public var notificationsEnabled = true {
        didSet { save(.notificationsEnabled, notificationsEnabled) }
    }
    /// Include up to 100 characters of message text in Notification Center alerts.
    /// On by default (user request 2026-09-25).
    public var showMessagePreview = true {
        didSet { save(.showMessagePreview, showMessagePreview) }
    }
    /// Plays `soundName` for incoming alerts (with or without Notification Center).
    public var playSound = true {
        didSet { save(.playSound, playSound) }
    }
    public var soundName: String = SystemSounds.defaultName {
        didSet { save(.soundName, soundName) }
    }
    /// Bounce the Dock icon once for mentions and direct messages while inactive.
    public var bounceDockIcon = true {
        didSet { save(.bounceDockIcon, bounceDockIcon) }
    }

    /// Check GitHub for new releases and download them in the background.
    public var checksForUpdates = true {
        didSet { save(.checksForUpdates, checksForUpdates) }
    }
    /// `nil`: follow the running build (nightly builds follow nightlies).
    public var updateChannel: UpdateChannel? {
        didSet { if let updateChannel { save(.updateChannel, updateChannel.rawValue) } }
    }

    @ObservationIgnored private let storage: (any LocalSettingsStorage)?
    /// Set after loading so restoring values does not write them straight back.
    @ObservationIgnored private var isLoaded = false

    /// `storage == nil` keeps every setting in memory for this run only.
    public init(storage: (any LocalSettingsStorage)? = nil) {
        self.storage = storage
        if let storage {
            let read = Reader(storage: storage)
            sendBehavior = read.value(.sendBehavior) ?? sendBehavior
            textSize = read.value(.textSize) ?? textSize
            appearance = read.value(.appearance) ?? appearance
            notificationsEnabled = read.bool(.notificationsEnabled) ?? notificationsEnabled
            showMessagePreview = read.bool(.showMessagePreview) ?? showMessagePreview
            playSound = read.bool(.playSound) ?? playSound
            soundName = read.string(.soundName).flatMap { SystemSounds.names.contains($0) ? $0 : nil } ?? soundName
            bounceDockIcon = read.bool(.bounceDockIcon) ?? bounceDockIcon
            checksForUpdates = read.bool(.checksForUpdates) ?? checksForUpdates
            updateChannel = read.value(.updateChannel)
            theme = read.data(.theme).flatMap(AppTheme.init(storageData:)) ?? theme
        }
        isLoaded = true
        if appearance != .system { applyAppearance() }
    }

    public var fontScale: CGFloat { textSize.scale }

    /// Overrides the app's appearance (not the system's).
    func applyAppearance() {
        let app = NSApplication.shared
        switch appearance {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func save(_ key: Key, _ value: Bool) {
        guard isLoaded else { return }
        storage?.set(value, forKey: key.rawValue)
    }

    private func save(_ key: Key, _ value: String) {
        guard isLoaded else { return }
        storage?.set(value, forKey: key.rawValue)
    }

    /// Typed, validated reads: a wrong type or unknown value yields `nil`.
    private struct Reader {
        let storage: any LocalSettingsStorage

        func bool(_ key: Key) -> Bool? {
            // Only a real boolean (`NSNumber` 0/1 or `Bool`); strings like "YES" are ignored.
            guard let number = storage.object(forKey: key.rawValue) as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }

        func string(_ key: Key) -> String? {
            guard let text = storage.object(forKey: key.rawValue) as? String, text.utf8.count <= 64 else { return nil }
            return text
        }

        func data(_ key: Key) -> Data? {
            storage.object(forKey: key.rawValue) as? Data
        }

        func value<Value: RawRepresentable<String>>(_ key: Key) -> Value? {
            guard let text = string(key) else { return nil }
            return Value(rawValue: text)
        }
    }
}
