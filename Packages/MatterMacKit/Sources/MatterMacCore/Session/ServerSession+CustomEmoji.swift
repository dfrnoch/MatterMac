import Foundation
public import MatterMacModels
import MattermostAPI

extension ServerSession {
    var customEmojiEnabled: Bool { capabilities.customEmojiEnabled == true }

    func wantCustomEmoji(_ names: [String]) {
        guard customEmojiEnabled else { return }
        for name in names { customEmoji.want(name, now: now().date) }
    }

    func scheduleEmojiFetch() {
        guard customEmojiEnabled, !isRunning(.emojiFetch), !customEmoji.wanted.isEmpty else { return }
        run(.emojiFetch) { session in
            let epoch = session.epoch
            while !session.customEmoji.wanted.isEmpty, !Task.isCancelled {
                let names = session.customEmoji.takeWanted(limit: 200)
                let found = (try? await session.service.customEmoji(names: names)) ?? []
                guard session.epoch == epoch, session.isActiveSessionAlive, !Task.isCancelled else { return }
                session.customEmoji.record(requested: names, found: found, now: session.now().date)
                session.markDirty([.timeline, .thread])
            }
        }
    }

    func handleEmojiAdded(_ emoji: CustomEmoji?) {
        guard customEmojiEnabled, let emoji else { return }
        customEmoji.insert(emoji)
        markDirty([.timeline, .thread])
    }

    public func customEmojiPage(page: Int, query: String = "") async -> [CustomEmoji] {
        guard isActiveSessionAlive, customEmojiEnabled, !Task.isCancelled else { return [] }
        let epoch = epoch
        let result: [CustomEmoji]
        if query.isEmpty {
            result = (try? await service.customEmojiList(page: max(0, page), perPage: 60)) ?? []
        } else {
            result = (try? await service.autocompleteCustomEmoji(name: query)) ?? []
        }
        guard self.epoch == epoch, isActiveSessionAlive, !Task.isCancelled else { return [] }
        let bounded = Array(result.prefix(query.isEmpty ? 60 : 100))
        customEmoji.insert(contentsOf: bounded)
        markDirty([.timeline, .thread])
        return bounded
    }

    func emojiCompletions(_ needle: String, limit: Int) async -> [CompletionCandidate] {
        var items = EmojiCatalog.system.search(needle, limit: limit).map { match in
            CompletionCandidate(kind: .special, id: match.matchedName, title: ":" + match.matchedName + ":",
                                subtitle: match.emoji.glyph, insertion: ":" + match.matchedName + ":")
        }
        let custom = await customEmojiPage(page: 0, query: needle)
        guard isActiveSessionAlive, !Task.isCancelled else { return [] }
        items += custom.map {
            CompletionCandidate(kind: .customEmoji, id: $0.name, title: ":" + $0.name + ":", subtitle: ":",
                                insertion: ":" + $0.name + ":", customEmojiID: $0.id)
        }
        func rank(_ item: CompletionCandidate) -> Int {
            item.id == needle ? 0 : item.id.hasPrefix(needle) ? 1 : 2
        }
        return Array(items.sorted { rank($0) == rank($1) ? $0.id < $1.id : rank($0) < rank($1) }.prefix(limit))
    }

    func commandCompletions(_ query: String, channel: ChannelID?, rootID: PostID?) async -> [CompletionCandidate] {
        guard let channel, let team = directory.channels[channel]?.teamID ?? selectedTeam else { return [] }
        let epoch = epoch
        var suggestions: [CommandSuggestion]
        do {
            suggestions = try await service.commandSuggestions(userInput: "/" + query, team: team,
                                                               channel: channel, rootID: rootID)
        } catch {
            switch error {
            case .notFound, .notImplemented:
                guard !query.contains(where: \.isWhitespace) else { return [] }
                suggestions = ((try? await service.autocompleteCommands(team: team)) ?? [])
                    .filter { $0.complete.hasPrefix(query) }
            default: return []
            }
        }
        guard self.epoch == epoch, isActiveSessionAlive, !Task.isCancelled else { return [] }
        var seen = Set<String>()
        return suggestions.filter { !$0.suggestion.isEmpty && seen.insert($0.complete).inserted }.prefix(8).map {
            CompletionCandidate(kind: .command, id: $0.complete, title: "/" + $0.complete,
                                subtitle: [$0.hint, $0.description].filter { !$0.isEmpty }.joined(separator: " — "),
                                insertion: "/" + $0.complete)
        }
    }
}
