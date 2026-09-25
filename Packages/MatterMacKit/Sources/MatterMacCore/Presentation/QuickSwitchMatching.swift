import Foundation

/// Pure helpers for the ⌘K quick switcher: match quality and group message names.
enum QuickSwitchMatching {
    /// Match quality, best first. `nil` from `rank` means no match.
    enum Rank: Int, Comparable {
        case exact, prefix, wordPrefix, substring, allWords

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Case-, diacritic- and width-insensitive form used for matching, so that
    /// "dornicak" finds "Dorničák".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The best rank of a folded, non-empty `needle` among folded `candidates`. A
    /// needle with several words also matches when every word is found somewhere
    /// ("anna ben" finds the group "Anna Clark, Ben Ortiz").
    static func rank(_ needle: String, in candidates: [String]) -> Rank? {
        guard !needle.isEmpty else { return nil }
        var best: Rank?
        for candidate in candidates where !candidate.isEmpty {
            guard let rank = rank(needle, in: candidate) else { continue }
            if best.map({ rank < $0 }) ?? true { best = rank }
            if rank == .exact { return rank }
        }
        if best != nil { return best }
        let words = needle.split(whereSeparator: \.isWhitespace)
        guard words.count > 1 else { return nil }
        let everyWord = words.allSatisfy { word in candidates.contains { $0.contains(word) } }
        return everyWord ? .allWords : nil
    }

    private static func rank(_ needle: String, in candidate: String) -> Rank? {
        if candidate == needle { return .exact }
        if candidate.hasPrefix(needle) { return .prefix }
        guard candidate.contains(needle) else { return nil }
        var index = candidate.startIndex
        while index < candidate.endIndex {
            let next = candidate.index(after: index)
            if isSeparator(candidate[index]), next < candidate.endIndex, candidate[next...].hasPrefix(needle) {
                return .wordPrefix
            }
            index = next
        }
        return .substring
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }

    /// The other members' usernames of a group message. The server names a group
    /// channel by its members' usernames joined with ", ", including the caller.
    static func groupUsernames(_ displayName: String, excluding me: String) -> [String] {
        displayName.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != me }
    }

    /// A group message title from its members' names, in server order.
    static func groupTitle(_ names: [String], fallback: String) -> String {
        names.isEmpty ? fallback : names.joined(separator: ", ")
    }
}
