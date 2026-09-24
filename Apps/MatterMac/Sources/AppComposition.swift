import Foundation
import MatterMacPlatform
import MatterMacUI
import MatterMacModels
import MattermostAPI
import MattermostRealtime

/// Composition root, including the Keychain store for saved sign-ins.
enum AppComposition {
    /// Development-only launch argument: `-MatterMacAllowInsecureLoopback YES`.
    static let allowInsecureLoopbackArgument = "-MatterMacAllowInsecureLoopback"

    static func makeEnvironment(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppEnvironment {
        let budget = ResourceBudget.standard
        return AppEnvironment(
            budget: budget,
            allowsInsecureLoopback: allowsInsecureLoopback(arguments: arguments),
            accounts: KeychainAccounts(
                service: allowsInsecureLoopback(arguments: arguments) ? "org.mattermac.MatterMac.development-accounts" : "org.mattermac.MatterMac.accounts",
                budget: budget, allowsInsecureLoopback: allowsInsecureLoopback(arguments: arguments)),
            serviceFactory: DefaultMattermostServiceFactory(budget: budget),
            makeRealtime: { endpoint, credential, user in
                MattermostRealtimeClient(endpoint: endpoint, credential: credential,
                                         currentUserID: user, budget: budget)
            },
            markupParse: { text, limits in MarkupParser.parse(text, limits: limits) })
    }

    /// Plain-HTTP loopback servers (e.g. a local Docker Mattermost) are allowed only
    /// in DEBUG builds and only when this launch passed
    /// `-MatterMacAllowInsecureLoopback YES`. The value is parsed from the process
    /// arguments, not `UserDefaults`, so a persisted `defaults write` has no effect,
    /// and it is never saved. Release builds always return `false`.
    static func allowsInsecureLoopback(arguments: [String]) -> Bool {
        #if DEBUG
        guard let flag = arguments.firstIndex(of: allowInsecureLoopbackArgument),
              arguments.indices.contains(flag + 1)
        else { return false }
        return arguments[flag + 1] == "YES"
        #else
        return false
        #endif
    }
}
