import Foundation
import MatterMacModels

/// `GET /users/me/preferences`, reduced while decoding to the categories MatterMac
/// reads, with a row cap. Other categories (e.g. thousands of `flagged_post` rows,
/// large `theme` JSON) are skipped without being retained.
struct PreferenceListWire: Decodable {
    static let keptCategories: Set<String> = [
        "display_settings", "direct_channel_show", "group_channel_show", "favorite_channel", "sidebar_settings",
    ]
    static let maximumRows = 2_000

    let preferences: [Preference]
    let truncated: Bool

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var kept: [Preference] = []
        var truncated = false
        while !container.isAtEnd {
            guard let wire = try? container.decode(PreferenceWire.self) else {
                _ = try? container.decode(SkipValue.self)
                continue
            }
            guard Self.keptCategories.contains(wire.preference.category) else { continue }
            if kept.count >= Self.maximumRows {
                truncated = true
                continue
            }
            kept.append(wire.preference)
        }
        self.preferences = kept
        self.truncated = truncated
    }
}

/// `GET /users/autocomplete` → `{"users":[…], "out_of_channel":[…]?, "agents":[…]? (v11)}`.
struct UserAutocompleteWire: Decodable {
    let users: [User]
    let outOfChannel: [User]

    enum Keys: String, CodingKey { case users, out_of_channel }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        users = ((try? c.decodeIfPresent(LossyArray<UserWire>.self, forKey: .users)) ?? LossyArray(elements: [])).elements.map(\.user)
        outOfChannel = ((try? c.decodeIfPresent(LossyArray<UserWire>.self, forKey: .out_of_channel))
            ?? LossyArray(elements: [])).elements.map(\.user)
    }
}

/// Consumes any JSON value without retaining it.
struct SkipValue: Decodable {
    init(from decoder: any Decoder) throws {}
}
