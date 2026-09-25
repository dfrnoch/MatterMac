import AppKit
import Foundation
import Testing
import MatterMacModels
import MattermostAPI
import MatterMacPlatform
import TestSupport
@testable import MatterMacUI

/// In-memory stand-in for `UserDefaults`: tests never touch a real defaults domain.
final class MemorySettingsStorage: LocalSettingsStorage {
    var values: [String: Any] = [:]
    private(set) var writes = 0

    init(_ values: [String: Any] = [:]) { self.values = values }

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        writes += 1
        values[key] = value
    }
}

/// "On This Mac" settings: defaults, saving through injected storage, validation of
/// stored values, and memory-only mode (package tests, `-MatterMacUITesting`).
@MainActor
@Suite("Local settings persistence", .serialized)
struct LocalSettingsPersistenceTests {
    private struct Factory: MattermostServiceFactory {
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("Unused") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fatalError("Unused") }
    }

    private func environment(_ storage: (any LocalSettingsStorage)?) -> AppEnvironment {
        AppEnvironment(settingsStorage: storage, serviceFactory: Factory(),
                       makeRealtime: { _, _, _ in FakeRealtimeConnection() },
                       markupParse: { MarkupParser.parse($0, limits: $1) })
    }

    @Test func notificationsAndPreviewsAreOnByDefault() {
        let storage = MemorySettingsStorage()
        for settings in [LocalSettings(), LocalSettings(storage: storage)] {
            #expect(settings.notificationsEnabled)
            #expect(settings.showMessagePreview)
            #expect(settings.playSound && settings.bounceDockIcon)
            #expect(settings.soundName == SystemSounds.defaultName)
            #expect(settings.sendBehavior == .returnSends && settings.textSize == .standard && settings.appearance == .system)
            #expect(settings.checksForUpdates && settings.updateChannel == nil)
        }
        // Loading defaults writes nothing.
        #expect(storage.writes == 0 && storage.values.isEmpty)
    }

    @Test func everySettingIsSavedAndRestoredByANewEnvironment() throws {
        defer { NSApplication.shared.appearance = nil }
        let storage = MemorySettingsStorage()
        let first = environment(storage).settings
        let sound = try #require(SystemSounds.names.first { $0 != SystemSounds.defaultName })
        first.notificationsEnabled = false
        first.showMessagePreview = false
        first.playSound = false
        first.soundName = sound
        first.bounceDockIcon = false
        first.sendBehavior = .commandReturnSends
        first.textSize = .extraLarge
        first.appearance = .dark
        first.checksForUpdates = false
        first.updateChannel = .nightly
        #expect(storage.values["MatterMac.notificationsEnabled"] as? Bool == false)
        #expect(storage.values["MatterMac.textSize"] as? String == "extraLarge")
        #expect(Set(storage.values.keys) == Set(LocalSettings.Key.allCases.map(\.rawValue)))

        NSApplication.shared.appearance = nil
        let restored = environment(storage).settings
        #expect(!restored.notificationsEnabled && !restored.showMessagePreview)
        #expect(!restored.playSound && !restored.bounceDockIcon && restored.soundName == sound)
        #expect(restored.sendBehavior == .commandReturnSends && restored.textSize == .extraLarge)
        #expect(restored.appearance == .dark)
        #expect(!restored.checksForUpdates && restored.updateChannel == .nightly)
        // The saved appearance is applied at launch, not only on change.
        #expect(NSApplication.shared.appearance?.name == .darkAqua)
        #expect(environment(storage).sendBehavior == .commandReturnSends)
    }

    @Test func invalidStoredValuesFallBackToDefaults() {
        let storage = MemorySettingsStorage([
            "MatterMac.notificationsEnabled": "NO",
            "MatterMac.showMessagePreview": 0,
            "MatterMac.playSound": [false],
            "MatterMac.bounceDockIcon": 2.5,
            "MatterMac.soundName": "Not A System Sound",
            "MatterMac.sendBehavior": "shiftReturnSends",
            "MatterMac.textSize": true,
            "MatterMac.appearance": String(repeating: "dark", count: 40),
        ])
        let settings = LocalSettings(storage: storage)
        #expect(settings.notificationsEnabled && settings.showMessagePreview)
        #expect(settings.playSound && settings.bounceDockIcon)
        #expect(settings.soundName == SystemSounds.defaultName)
        #expect(settings.sendBehavior == .returnSends && settings.textSize == .standard && settings.appearance == .system)
        #expect(storage.writes == 0)
        // Only real booleans count; a valid value next to invalid ones is kept.
        let mixed = LocalSettings(storage: MemorySettingsStorage([
            "MatterMac.notificationsEnabled": false, "MatterMac.textSize": "small", "MatterMac.playSound": "false",
        ]))
        #expect(!mixed.notificationsEnabled && mixed.textSize == .small && mixed.playSound)
    }

    @Test func withoutStorageSettingsStayInMemory() {
        let keys = LocalSettings.Key.allCases.map(\.rawValue)
        let before = keys.map { UserDefaults.standard.object(forKey: $0) == nil }
        let first = environment(nil).settings
        first.notificationsEnabled = false
        first.showMessagePreview = false
        first.textSize = .large
        let next = environment(nil).settings
        #expect(next.notificationsEnabled && next.showMessagePreview && next.textSize == .standard)
        // Nothing reached this process's real defaults either.
        #expect(keys.map { UserDefaults.standard.object(forKey: $0) == nil } == before)
    }
}
