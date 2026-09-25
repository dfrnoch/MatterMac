import Foundation
public import MatterMacModels

/// `model.Emoji`: `{id, create_at, update_at, delete_at, creator_id, name}`. Deleted
/// emoji and invalid ids or names fail decoding (lists skip them).
public struct CustomEmojiWire: Decodable, Sendable {
    public let emoji: CustomEmoji

    enum Keys: String, CodingKey { case id, name, creator_id, delete_at }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = try c.decode(String.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        guard IdentifierValidation.isValid(id), name.utf8.count <= CustomEmoji.maximumNameLength,
              Reaction.isValidEmojiName(name), c.timestamp(.delete_at).isZero else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "invalid emoji")
        }
        emoji = CustomEmoji(id: id, name: name, creatorID: c.optionalID(UserID.self, .creator_id))
    }
}

/// One slash-command suggestion (`model.AutocompleteSuggestion`):
/// `{Complete, Suggestion, Hint, Description, IconData}`. `complete` is the full
/// command text without the leading `/` (for a text argument it can end in a space
/// and `suggestion` is empty: an informational hint only).
public struct CommandSuggestion: Hashable, Sendable {
    public let complete: String
    public let suggestion: String
    public let hint: String
    public let description: String

    public init(complete: String, suggestion: String, hint: String = "", description: String = "") {
        self.complete = complete
        self.suggestion = suggestion
        self.hint = hint
        self.description = description
    }

    /// Bounds for untrusted display text.
    public static let maximumCompleteBytes = 512
    public static let maximumTextBytes = 1_024
}

struct CommandSuggestionWire: Decodable, Sendable {
    let suggestion: CommandSuggestion

    enum Keys: String, CodingKey { case Complete, Suggestion, Hint, Description }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let complete = c.lenientString(.Complete, maxBytes: CommandSuggestion.maximumCompleteBytes) ?? ""
        guard !complete.isEmpty, !complete.contains(where: \.isNewline) else {
            throw DecodingError.dataCorruptedError(forKey: .Complete, in: c, debugDescription: "empty suggestion")
        }
        func text(_ key: Keys) -> String {
            let raw = c.lenientString(key, maxBytes: CommandSuggestion.maximumTextBytes) ?? ""
            return raw.contains(where: \.isNewline) ? raw.replacingOccurrences(of: "\n", with: " ") : raw
        }
        suggestion = CommandSuggestion(complete: complete, suggestion: text(.Suggestion), hint: text(.Hint),
                                       description: text(.Description))
    }
}

/// `GET /teams/{id}/commands/autocomplete` (`[model.Command]`, legacy): only the
/// autocomplete fields are read; tokens and URLs are never retained.
struct AutocompleteCommandWire: Decodable, Sendable {
    let suggestion: CommandSuggestion

    enum Keys: String, CodingKey { case trigger, auto_complete, auto_complete_hint, auto_complete_desc, delete_at }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let trigger = c.lenientString(.trigger, maxBytes: 128) ?? ""
        guard !trigger.isEmpty, !trigger.contains(where: { $0.isWhitespace || $0 == "/" }),
              c.lenientBool(.auto_complete) != false, c.timestamp(.delete_at).isZero else {
            throw DecodingError.dataCorruptedError(forKey: .trigger, in: c, debugDescription: "not autocompleted")
        }
        suggestion = CommandSuggestion(
            complete: trigger, suggestion: trigger,
            hint: c.lenientString(.auto_complete_hint, maxBytes: CommandSuggestion.maximumTextBytes) ?? "",
            description: c.lenientString(.auto_complete_desc, maxBytes: CommandSuggestion.maximumTextBytes) ?? "")
    }
}
