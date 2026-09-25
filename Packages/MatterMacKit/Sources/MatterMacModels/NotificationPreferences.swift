// Server-side notification preferences (user `notify_props` and channel member
// `notify_props`) and the client-side mention matcher. See docs/research/channels.md
// and docs/decisions/0024-server-notification-preferences-and-settings.md.

import Foundation

/// The account-wide desktop notification level (`notify_props.desktop`).
public enum DesktopNotificationLevel: String, CaseIterable, Hashable, Sendable {
    case all
    case mention
    /// Wire value "none" (named to avoid confusion with `Optional.none`).
    case nothing = "none"

    /// Unknown or missing values fall back to the server default, `mention`.
    public init(wire: String?) {
        self = wire.flatMap(Self.init(rawValue:)) ?? .mention
    }
}

/// A channel member's desktop level; `default` defers to the account level.
public enum ChannelDesktopLevel: String, CaseIterable, Hashable, Sendable, Codable {
    case `default`
    case all
    case mention
    /// Wire value "none" (named to avoid confusion with `Optional.none`).
    case nothing = "none"

    public init(wire: String?) {
        self = wire.flatMap(Self.init(rawValue:)) ?? .default
    }
}

/// `ignore_channel_mentions`: whether @channel, @here and @all count as mentions in
/// this channel. `default` follows the account's `channel` setting.
public enum IgnoreChannelMentions: String, CaseIterable, Hashable, Sendable, Codable {
    case `default`
    case on
    case off

    public init(wire: String?) {
        self = wire.flatMap(Self.init(rawValue:)) ?? .default
    }
}

/// The signed-in user's `notify_props`, retained verbatim so an explicit change can
/// send the complete map back (`PUT /users/{id}/patch` replaces the whole map).
/// Bounded at decode time; `isComplete` is `false` when anything was dropped, and
/// such a map must not be written back.
public struct UserNotifyProps: Hashable, Sendable, Codable {
    public static let maximumKeys = 48
    public static let maximumKeyBytes = 64
    public static let maximumValueBytes = 4_096
    /// Custom mention keywords accepted for editing (the official client has no
    /// lower limit; this keeps the matcher and the request bounded).
    public static let maximumMentionKeys = 64

    public private(set) var values: [String: String]
    public let isComplete: Bool

    public init(values: [String: String], isComplete: Bool = true) {
        self.values = values
        self.isComplete = isComplete
    }

    /// Bounded construction from an untrusted map.
    public static func bounded(_ raw: [String: String]) -> UserNotifyProps {
        var kept: [String: String] = [:]
        var complete = raw.count <= maximumKeys
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
            guard kept.count < maximumKeys else { complete = false; break }
            guard key.utf8.count <= maximumKeyBytes, value.utf8.count <= maximumValueBytes else {
                complete = false
                continue
            }
            kept[key] = value
        }
        return UserNotifyProps(values: kept, isComplete: complete)
    }

    public var desktop: DesktopNotificationLevel {
        get { DesktopNotificationLevel(wire: values["desktop"]) }
        set { values["desktop"] = newValue.rawValue }
    }

    /// `desktop_sound`; missing means on (server default).
    public var desktopSound: Bool {
        get { values["desktop_sound"] != "false" }
        set { values["desktop_sound"] = newValue ? "true" : "false" }
    }

    /// Custom keywords (`mention_keys`, comma-separated). The username is implicit.
    public var mentionKeys: [String] {
        get {
            (values["mention_keys"] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        set {
            var seen = Set<String>()
            let keys = newValue.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && !$0.contains(",") && seen.insert($0).inserted }
            values["mention_keys"] = keys.prefix(Self.maximumMentionKeys).joined(separator: ",")
        }
    }

    /// `first_name`: the first name triggers a mention (case-insensitive here).
    public var firstNameMentions: Bool {
        get { values["first_name"] == "true" }
        set { values["first_name"] = newValue ? "true" : "false" }
    }

    /// `channel`: @channel, @all and @here trigger mentions; missing means on.
    public var channelWideMentions: Bool {
        get { values["channel"] != "false" }
        set { values["channel"] = newValue ? "true" : "false" }
    }

    /// Server defaults for a user without stored props (`SetDefaultNotifications`).
    public static let serverDefault = UserNotifyProps(values: [
        "desktop": "mention", "desktop_sound": "true", "mention_keys": "", "first_name": "false", "channel": "true",
    ])
}

/// Client-side mention detection matching the official client's keyword rules:
/// `@username`, custom keywords, the first name when enabled, and @channel/@all/@here
/// when channel-wide mentions apply. Case-insensitive, whole words only.
public struct MentionMatcher: Sendable {
    /// Lowercased keys. Keys starting with "@" match only with the "@".
    public let keys: [String]

    public init(username: String, firstName: String, props: UserNotifyProps, channelWideMentions: Bool) {
        var keys: [String] = []
        if !username.isEmpty { keys.append("@" + username.lowercased()) }
        keys += props.mentionKeys.prefix(UserNotifyProps.maximumMentionKeys).map { $0.lowercased() }
        let first = firstName.trimmingCharacters(in: .whitespaces)
        if props.firstNameMentions, !first.isEmpty { keys.append(first.lowercased()) }
        if channelWideMentions { keys += ["@channel", "@all", "@here"] }
        var seen = Set<String>()
        self.keys = keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Scans at most `limit` characters of the message.
    public func matches(_ text: String, limit: Int = 16_384) -> Bool {
        guard !keys.isEmpty, !text.isEmpty else { return false }
        let haystack = Array(text.prefix(limit).lowercased())
        for key in keys {
            let needle = Array(key)
            guard !needle.isEmpty, needle.count <= haystack.count else { continue }
            var index = 0
            while index + needle.count <= haystack.count {
                if haystack[index] == needle[0], Array(haystack[index..<(index + needle.count)]) == needle,
                   Self.isBoundary(before: index, in: haystack),
                   Self.isBoundary(after: index + needle.count, in: haystack) {
                    return true
                }
                index += 1
            }
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isBoundary(before index: Int, in text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        return !isWordCharacter(previous) && previous != "@"
    }

    /// A trailing "." or "-" ends the word unless it continues a longer name
    /// (`@alice.smith` does not mention `@alice`).
    private static func isBoundary(after index: Int, in text: [Character]) -> Bool {
        guard index < text.count else { return true }
        let next = text[index]
        if isWordCharacter(next) { return false }
        if next == "." || next == "-", index + 1 < text.count, isWordCharacter(text[index + 1]) { return false }
        return true
    }
}
