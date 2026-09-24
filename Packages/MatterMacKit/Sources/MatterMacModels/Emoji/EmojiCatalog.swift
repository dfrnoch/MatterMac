// Mattermost *system* (Unicode) emoji: short name ↔ glyph lookup, picker order and
// bounded search. The table is static, generated at development time by
// Tools/GenerateEmojiCatalog.swift from pinned upstream data (docs/assets.md); the
// app never fetches emoji data. Custom (server-uploaded) emoji are not included and
// keep rendering as `:name:` text.

/// A Mattermost system emoji category (Mattermost's normalized keys), in picker order.
public enum EmojiCategory: String, CaseIterable, Hashable, Sendable {
    case smileysEmotion = "smileys-emotion"
    case peopleBody = "people-body"
    case animalsNature = "animals-nature"
    case foodDrink = "food-drink"
    case activities
    case travelPlaces = "travel-places"
    case objects
    case symbols
    case flags
    /// Skin-tone swatches and hair components. Valid names, but not shown in a picker
    /// (Mattermost's picker hides them as well).
    case component

    public var isShownInPicker: Bool { self != .component }
}

/// One system emoji (or one skin-tone variant of it).
public struct SystemEmoji: Hashable, Sendable, Identifiable {
    /// Primary short name: the name Mattermost clients send for reactions.
    public let name: String
    /// Every accepted short name, primary first (e.g. `+1`, `thumbsup`).
    public let names: [String]
    /// The Unicode presentation.
    public let glyph: String
    public let category: EmojiCategory
    /// `true` for `*_skin_tone` variants, which pickers and default searches omit.
    public let isSkinToneVariant: Bool

    public var id: String { name }
}

/// A search hit: the emoji plus the short name that matched the query.
public struct EmojiMatch: Hashable, Sendable {
    public let emoji: SystemEmoji
    public let matchedName: String
}

public final class EmojiCatalog: Sendable {
    /// Mattermost v11.11.1 `SystemEmojis`, parsed lazily once on first use.
    public static let system = EmojiCatalog(packed: packedSystemEmoji)

    /// Static "frequently used" row for pickers. Usage is never recorded or persisted.
    public static let defaultQuickReactions = ["+1", "smile", "white_check_mark", "heart", "joy", "tada", "eyes", "pray"]

    /// Hard ceiling for `search(_:limit:)`, whatever the caller asks for.
    public static let maximumSearchResults = 256

    /// Longest query considered (system names reach 72 characters).
    public static let maximumQueryLength = 80

    /// All records in picker order, skin-tone variants directly after their base emoji.
    public let all: [SystemEmoji]
    private let indexByName: [String: Int]

    init(packed: StaticString) {
        let text = packed.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
        var all: [SystemEmoji] = []
        var index: [String: Int] = [:]
        var category: EmojiCategory?
        var base: SystemEmoji?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == "@" {
                category = EmojiCategory(rawValue: String(line.dropFirst()))
                base = nil
                continue
            }
            guard let category, let tab = line.firstIndex(of: "\t") else { continue }
            let isVariant = line.first == "~"
            let glyph = String(line[line.index(line.startIndex, offsetBy: isVariant ? 1 : 0)..<tab])
            let field = line[line.index(after: tab)...]
            let names: [String]
            if !isVariant {
                names = field.split(separator: " ").map(String.init)
            } else if field.first == "=" {
                names = field.dropFirst().split(separator: " ").map(String.init)
            } else if let base {
                let suffix = field.compactMap(Self.skinToneSuffix).joined(separator: "_")
                names = base.names.map { $0 + "_" + suffix }
            } else {
                continue
            }
            guard let primary = names.first, !glyph.isEmpty else { continue }
            let emoji = SystemEmoji(name: primary, names: names, glyph: glyph, category: category,
                                    isSkinToneVariant: isVariant)
            for name in names where index[name] == nil { index[name] = all.count }
            all.append(emoji)
            if !isVariant { base = emoji }
        }
        self.all = all
        self.indexByName = index
    }

    private static func skinToneSuffix(_ digit: Character) -> String? {
        switch digit {
        case "1": "light_skin_tone"
        case "2": "medium_light_skin_tone"
        case "3": "medium_skin_tone"
        case "4": "medium_dark_skin_tone"
        case "5": "dark_skin_tone"
        default: nil
        }
    }

    /// Number of distinct short names (aliases and skin-tone names included).
    public var nameCount: Int { indexByName.count }

    /// The emoji for a short name (without colons). Exact match first, then the
    /// lowercased name (v11 servers lowercase reaction names; v10 does not).
    public func emoji(named name: String) -> SystemEmoji? {
        guard !name.isEmpty, name.utf8.count <= Self.maximumQueryLength else { return nil }
        if let index = indexByName[name] ?? indexByName[name.lowercased()] { return all[index] }
        return nil
    }

    /// The Unicode glyph for a short name, or `nil` (unknown or custom emoji).
    public func glyph(for name: String) -> String? { emoji(named: name)?.glyph }

    /// Emoji shown in a picker for `category` (no skin-tone variants), in order.
    public func pickerEmoji(in category: EmojiCategory) -> [SystemEmoji] {
        all.filter { $0.category == category && !$0.isSkinToneVariant }
    }

    /// Bounded short-name search. An exact name comes first, then names starting
    /// with the query, then names containing it; ties sort by name. One result per
    /// emoji. Skin-tone variants are only included when the query mentions a tone
    /// ("skin" or "tone") unless `includingSkinTones` says otherwise. Colons around
    /// the query are ignored; an empty query returns nothing.
    public func search(_ query: String, limit: Int, includingSkinTones: Bool? = nil) -> [EmojiMatch] {
        let limit = min(max(0, limit), Self.maximumSearchResults)
        var needle = Substring(query.lowercased())
        while needle.first == ":" { needle = needle.dropFirst() }
        while needle.last == ":" { needle = needle.dropLast() }
        guard limit > 0, !needle.isEmpty, needle.utf8.count <= Self.maximumQueryLength else { return [] }
        let needleBytes = Array(needle.utf8)
        let skins = includingSkinTones ?? (needle.contains("skin") || needle.contains("tone"))
        var hits: [(rank: Int, name: String, index: Int)] = []
        for (index, emoji) in all.enumerated() where skins || !emoji.isSkinToneVariant {
            var best: (rank: Int, name: String)?
            for name in emoji.names {
                guard let rank = Self.rank(of: needleBytes, in: name) else { continue }
                if best.map({ rank < $0.rank || (rank == $0.rank && name < $0.name) }) ?? true {
                    best = (rank, name)
                }
            }
            if let best { hits.append((best.rank, best.name, index)) }
        }
        hits.sort { $0.rank != $1.rank ? $0.rank < $1.rank : ($0.name != $1.name ? $0.name < $1.name : $0.index < $1.index) }
        return hits.prefix(limit).map { EmojiMatch(emoji: all[$0.index], matchedName: $0.name) }
    }

    /// 0 exact, 1 prefix, 2 substring, `nil` no match. Names are ASCII.
    private static func rank(of needle: [UInt8], in name: String) -> Int? {
        let bytes = name.utf8
        guard bytes.count >= needle.count else { return nil }
        if bytes.starts(with: needle) { return bytes.count == needle.count ? 0 : 1 }
        var start = bytes.startIndex
        var remaining = bytes.count
        while remaining > needle.count {
            start = bytes.index(after: start)
            remaining -= 1
            if bytes[start...].starts(with: needle) { return 2 }
        }
        return nil
    }
}
