import Foundation
import MatterMacCore
import MatterMacPlatform
import MatterMacUI
import MatterMacModels
import MatterMacUpdateSupport
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
    /// Development-only launch argument: `-MatterMacUpdateFeed <url>` serves
    /// `releases.json` in GitHub's format, to exercise updates locally.
    static let updateFeedArgument = "-MatterMacUpdateFeed"
    /// Development-only: `-MatterMacUpdateAutoInstall YES` installs a ready update
    /// without the banner (end-to-end testing of the installer).
    static let updateAutoInstallArgument = "-MatterMacUpdateAutoInstall"

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
        environment.updater = makeUpdater(settings: environment.settings, arguments: arguments, uiTesting: uiTesting)
        return environment
    }

    /// Release builds update from GitHub releases. Development builds (`-dev`
    /// label) and UI tests do not, unless a development feed is given.
    static func makeUpdater(settings: LocalSettings, arguments: [String], uiTesting: Bool) -> AppUpdater? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let buildText = info["CFBundleVersion"] as? String, let build = Int(buildText),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let label = (info["MatterMacVersionLabel"] as? String).flatMap { $0.hasPrefix("$(") ? nil : $0 } ?? short
        let feed = debugValue(updateFeedArgument, arguments: arguments).flatMap(URL.init(string:))
        guard feed != nil || (!uiTesting && !label.hasSuffix("-dev")) else { return nil }
        #if DEBUG
        // Development builds are signed with Apple Development and not notarized.
        let requirement = """
            identifier "\(UpdateSupport.bundleIdentifier)" and anchor apple generic \
            and certificate leaf[subject.OU] = "\(UpdateSupport.teamIdentifier)"
            """
        #else
        let requirement = UpdateSupport.updateRequirement
        #endif
        let configuration = AppUpdater.Configuration(
            installedApp: Bundle.main.bundleURL, currentBuild: build, currentLabel: label,
            workDirectory: caches.appendingPathComponent("org.mattermac.MatterMac/Updates", isDirectory: true),
            requirement: requirement, relaunchArguments: Array(arguments.dropFirst()), overrideReleasesURL: feed,
            firstCheckDelay: feed == nil ? .seconds(20) : .seconds(1),
            installsWhenReady: debugFlag(updateAutoInstallArgument, arguments: arguments))
        return AppUpdater(settings: settings, http: URLSessionUpdateHTTP(userAgent: "MatterMac/\(label) (macOS)"),
                          configuration: configuration)
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

    /// The value after `<flag>` in the launch arguments of a DEBUG build; always
    /// `nil` in Release.
    static func debugValue(_ name: String, arguments: [String]) -> String? {
        #if DEBUG
        guard let flag = arguments.firstIndex(of: name), arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
        #else
        return nil
        #endif
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
