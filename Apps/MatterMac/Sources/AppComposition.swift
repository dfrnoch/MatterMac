import Foundation
import MatterMacCore
import MatterMacPlatform
import MatterMacUI
import MatterMacModels
import MattermostAPI
import MattermostRealtime

/// Composition root, including the Keychain store for saved sign-ins, the
/// on-device content cache and saved local settings.
enum AppComposition {
    /// Development-only launch argument: `-MatterMacAllowInsecureLoopback YES`.
    static let allowInsecureLoopbackArgument = "-MatterMacAllowInsecureLoopback"
    /// Development-only launch argument for UI tests: `-MatterMacUITesting YES`.
    /// Saved sign-ins, the content cache and saved local settings are neither read
    /// nor written, so a test never restores (or connects with) the developer's
    /// real accounts or settings that share this bundle ID.
    static let uiTestingArgument = "-MatterMacUITesting"

    static func makeEnvironment(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppEnvironment {
        let budget = ResourceBudget.standard
        let uiTesting = debugFlag(uiTestingArgument, arguments: arguments)
        let development = allowsInsecureLoopback(arguments: arguments)
        let environment = AppEnvironment(
            budget: budget,
            allowsInsecureLoopback: development,
            accounts: uiTesting ? nil : KeychainAccounts(
                service: development ? "org.mattermac.MatterMac.development-accounts" : "org.mattermac.MatterMac.accounts",
                budget: budget, allowsInsecureLoopback: development),
            cacheStorage: uiTesting ? nil : cacheStorage(development: development),
            // "On This Mac" settings (decision 0032), saved under `MatterMac.*` keys.
            settingsStorage: uiTesting ? nil : UserDefaults.standard,
            serviceFactory: DefaultMattermostServiceFactory(budget: budget),
            makeRealtime: { endpoint, credential, user in
                MattermostRealtimeClient(endpoint: endpoint, credential: credential,
                                         currentUserID: user, budget: budget)
            },
            markupParse: { text, limits in MarkupParser.parse(text, limits: limits) })
        // A UI test must not ask macOS for notification permission or post to the
        // developer's Notification Center; this in-memory choice is never saved.
        if uiTesting { environment.settings.notificationsEnabled = false }
        return environment
    }

    /// The on-device cache in the app's Caches directory (inside the sandbox
    /// container), keyed per account in the Keychain. Development runs use their own
    /// directory and keys, like their saved sign-ins.
    static func cacheStorage(development: Bool) -> ContentCache.Storage? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("org.mattermac.MatterMac", isDirectory: true)
            .appendingPathComponent(development ? "Content-development" : "Content", isDirectory: true)
        let keys = KeychainCacheKeys(service: development ? "org.mattermac.MatterMac.development-cache-keys"
                                                          : "org.mattermac.MatterMac.cache-keys")
        return ContentCache.Storage(directory: directory, keys: keys)
    }

    /// Plain-HTTP loopback servers (e.g. a local Docker Mattermost) are allowed only
    /// in DEBUG builds and only when this launch passed
    /// `-MatterMacAllowInsecureLoopback YES`. The value is parsed from the process
    /// arguments, not `UserDefaults`, so a persisted `defaults write` has no effect,
    /// and it is never saved. Release builds always return `false`.
    static func allowsInsecureLoopback(arguments: [String]) -> Bool {
        debugFlag(allowInsecureLoopbackArgument, arguments: arguments)
    }

    /// `<flag> YES` in the launch arguments of a DEBUG build; always `false` in Release.
    static func debugFlag(_ name: String, arguments: [String]) -> Bool {
        #if DEBUG
        guard let flag = arguments.firstIndex(of: name), arguments.indices.contains(flag + 1) else { return false }
        return arguments[flag + 1] == "YES"
        #else
        return false
        #endif
    }
}
