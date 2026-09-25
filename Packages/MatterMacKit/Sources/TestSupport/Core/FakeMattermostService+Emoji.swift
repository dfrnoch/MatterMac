import Foundation
import os
public import MatterMacModels
public import MattermostAPI

/// Scriptable custom emoji and slash-command state. Without an explicit handler the
/// fake behaves like the server: names are looked up in `emoji`, the list is sorted
/// by name and paged, autocomplete is a name-prefix match, and command suggestions
/// are prefix matches of `commands` triggers.
public struct EmojiCommandState: Sendable {
    public var emoji: [CustomEmoji] = []
    /// When set, every emoji call fails with it (e.g. 501 when custom emoji are off).
    public var emojiError: APIError?
    public var nameLookups: [[String]] = []
    public var listRequests: [(page: Int, perPage: Int)] = []
    public var autocompleteQueries: [String] = []
    public var commands: [CommandSuggestion] = []
    /// Argument suggestions per complete command prefix (e.g. `"call "`).
    public var argumentSuggestions: [String: [CommandSuggestion]] = [:]
    public var suggestionsError: APIError?
    public var suggestionInputs: [String] = []
    public var suggestionRoots: [PostID?] = []
    public var legacyCommandRequests = 0
    /// Suspends `customEmoji(names:)` until the gate opens (race tests).
    public var namesGate: Gate?

    public init() {}
}

extension FakeMattermostService {
    public func withEmojiCommands<T: Sendable>(_ body: @Sendable (inout EmojiCommandState) -> T) -> T {
        emojiCommands.withLock { body(&$0) }
    }

    private func mark(_ call: String) { withState { $0.calls.append(call) } }

    public func customEmoji(names: [String]) async throws(APIError) -> [CustomEmoji] {
        mark("customEmojiNames")
        let (error, gate) = emojiCommands.withLock { state in
            state.nameLookups.append(names)
            return (state.emojiError, state.namesGate)
        }
        if let gate { await gate.wait() }
        if let error { throw error }
        let wanted = Set(names.map { $0.lowercased() })
        return emojiCommands.withLock { $0.emoji.filter { wanted.contains($0.name) } }
    }

    public func customEmoji(named name: String) async throws(APIError) -> CustomEmoji? {
        mark("customEmojiNamed")
        if let error = emojiCommands.withLock({ $0.emojiError }) { throw error }
        return emojiCommands.withLock { $0.emoji.first { $0.name == name.lowercased() } }
    }

    public func customEmojiList(page: Int, perPage: Int) async throws(APIError) -> [CustomEmoji] {
        mark("customEmojiList")
        let (error, all) = emojiCommands.withLock { state in
            state.listRequests.append((page, perPage))
            return (state.emojiError, state.emoji.sorted { $0.name < $1.name })
        }
        if let error { throw error }
        let start = max(0, page) * max(1, perPage)
        guard start < all.count else { return [] }
        return Array(all[start..<min(all.count, start + max(1, perPage))])
    }

    public func autocompleteCustomEmoji(name: String) async throws(APIError) -> [CustomEmoji] {
        mark("autocompleteCustomEmoji")
        let (error, all) = emojiCommands.withLock { state in
            state.autocompleteQueries.append(name)
            return (state.emojiError, state.emoji)
        }
        if let error { throw error }
        let needle = name.lowercased()
        return Array(all.filter { $0.name.hasPrefix(needle) }.sorted { $0.name < $1.name }.prefix(100))
    }

    public func commandSuggestions(userInput: String, team: TeamID, channel: ChannelID, rootID: PostID?)
        async throws(APIError) -> [CommandSuggestion] {
        mark("commandSuggestions")
        let (error, commands, arguments) = emojiCommands.withLock { state in
            state.suggestionInputs.append(userInput)
            state.suggestionRoots.append(rootID)
            return (state.suggestionsError, state.commands, state.argumentSuggestions)
        }
        if let error { throw error }
        let input = String(userInput.dropFirst())
        if let space = input.firstIndex(of: " ") {
            let key = String(input[...space])
            let rest = String(input[input.index(after: space)...])
            let completeRest = rest.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            return (arguments[key] ?? []).filter { $0.suggestion.isEmpty || $0.suggestion.hasPrefix(completeRest) }
        }
        return commands.filter { $0.suggestion.hasPrefix(input) }
    }

    public func autocompleteCommands(team: TeamID) async throws(APIError) -> [CommandSuggestion] {
        mark("autocompleteCommands")
        return emojiCommands.withLock { state in
            state.legacyCommandRequests += 1
            return state.commands
        }
    }
}
