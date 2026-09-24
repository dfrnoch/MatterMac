public import Foundation
public import MatterMacModels

public struct TeamWire: Decodable, Sendable {
    public let team: Team
    enum Keys: String, CodingKey { case id, name, display_name, type, allow_open_invite, delete_at }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        team = Team(
            id: try c.requiredID(TeamID.self, .id),
            name: String((c.lenientString(.name) ?? "").prefix(128)),
            displayName: String((c.lenientString(.display_name) ?? "").prefix(256)),
            isOpenInvite: c.lenientBool(.allow_open_invite) ?? false,
            deleteAt: c.timestamp(.delete_at))
    }
}

public struct TeamMemberWire: Decodable, Sendable {
    public let teamID: TeamID
    public let userID: UserID
    public let roles: [String]
    public let deleteAt: MattermostTimestamp
    enum Keys: String, CodingKey { case team_id, user_id, roles, delete_at }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        teamID = try c.requiredID(TeamID.self, .team_id)
        userID = try c.requiredID(UserID.self, .user_id)
        roles = (c.lenientString(.roles, maxBytes: 1_024) ?? "").split(separator: " ").prefix(32).map(String.init)
        deleteAt = c.timestamp(.delete_at)
    }
}

public struct ChannelWire: Decodable, Sendable {
    public let channel: Channel
    enum Keys: String, CodingKey {
        case id, team_id, type, name, display_name, header, purpose, last_post_at, last_root_post_at
        case total_msg_count, total_msg_count_root, delete_at, creator_id, group_constrained, shared
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        channel = Channel(
            id: try c.requiredID(ChannelID.self, .id),
            teamID: c.optionalID(TeamID.self, .team_id),
            type: ChannelType(wire: c.lenientString(.type, maxBytes: 8) ?? ""),
            name: String((c.lenientString(.name) ?? "").prefix(128)),
            displayName: String((c.lenientString(.display_name) ?? "").prefix(256)),
            header: String((c.lenientString(.header) ?? "").prefix(4_096)),
            purpose: String((c.lenientString(.purpose) ?? "").prefix(1_024)),
            lastPostAt: c.timestamp(.last_post_at),
            lastRootPostAt: c.timestamp(.last_root_post_at),
            totalMessageCount: c.lenientInt64(.total_msg_count) ?? 0,
            totalMessageCountRoot: c.lenientInt64(.total_msg_count_root) ?? 0,
            deleteAt: c.timestamp(.delete_at),
            creatorID: c.optionalID(UserID.self, .creator_id),
            isGroupConstrained: c.lenientBool(.group_constrained) ?? false,
            isShared: c.lenientBool(.shared) ?? false)
    }
}

public struct ChannelMemberWire: Decodable, Sendable {
    public let membership: ChannelMembership
    enum Keys: String, CodingKey {
        case channel_id, user_id, roles, last_viewed_at, msg_count, msg_count_root, mention_count
        case mention_count_root, urgent_mention_count, last_update_at, notify_props
    }
    struct NotifyProps: Decodable {
        let markUnread: String?
        let desktop: String?
        let ignoreChannelMentions: String?
        enum Keys: String, CodingKey { case mark_unread, desktop, ignore_channel_mentions }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            markUnread = c.lenientString(.mark_unread, maxBytes: 16)
            desktop = c.lenientString(.desktop, maxBytes: 16)
            ignoreChannelMentions = c.lenientString(.ignore_channel_mentions, maxBytes: 16)
        }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let notify = try? c.decodeIfPresent(NotifyProps.self, forKey: .notify_props)
        membership = ChannelMembership(
            channelID: try c.requiredID(ChannelID.self, .channel_id),
            userID: try c.requiredID(UserID.self, .user_id),
            roles: (c.lenientString(.roles, maxBytes: 1_024) ?? "").split(separator: " ").prefix(32).map(String.init),
            lastViewedAt: c.timestamp(.last_viewed_at),
            messageCount: c.lenientInt64(.msg_count) ?? 0,
            messageCountRoot: c.lenientInt64(.msg_count_root) ?? 0,
            mentionCount: c.lenientInt64(.mention_count) ?? 0,
            mentionCountRoot: c.lenientInt64(.mention_count_root) ?? 0,
            urgentMentionCount: c.lenientInt64(.urgent_mention_count) ?? 0,
            lastUpdateAt: c.timestamp(.last_update_at),
            markUnread: notify?.markUnread == "mention" ? .mention : .all,
            desktop: ChannelDesktopLevel(wire: notify?.desktop),
            ignoreChannelMentions: IgnoreChannelMentions(wire: notify?.ignoreChannelMentions))
    }
}

public struct UserWire: Decodable, Sendable {
    public let user: User
    enum Keys: String, CodingKey {
        case id, username, first_name, last_name, nickname, position, is_bot, delete_at, last_picture_update
        case locale, roles, email, timezone, props, notify_props
    }
    enum TimeZoneKeys: String, CodingKey { case useAutomaticTimezone, automaticTimezone, manualTimezone }
    enum PropKeys: String, CodingKey { case customStatus }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let username = c.lenientString(.username, maxBytes: 128) ?? ""
        guard !username.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .username, in: c, debugDescription: "missing username")
        }
        user = User(
            id: try c.requiredID(UserID.self, .id),
            username: username,
            firstName: String((c.lenientString(.first_name) ?? "").prefix(128)),
            lastName: String((c.lenientString(.last_name) ?? "").prefix(128)),
            nickname: String((c.lenientString(.nickname) ?? "").prefix(128)),
            position: String((c.lenientString(.position) ?? "").prefix(256)),
            isBot: c.lenientBool(.is_bot) ?? false,
            deleteAt: c.timestamp(.delete_at),
            lastPictureUpdate: c.timestamp(.last_picture_update),
            locale: String((c.lenientString(.locale) ?? "").prefix(16)),
            roles: (c.lenientString(.roles, maxBytes: 1_024) ?? "").split(separator: " ").prefix(32).map(String.init),
            email: String((c.lenientString(.email, maxBytes: 320) ?? "").prefix(320)),
            timeZoneIdentifier: Self.timeZone(c),
            customStatus: Self.customStatus(c),
            notifyProps: Self.notifyProps(c))
    }

    /// Sanitized profiles (other users, some broadcasts) carry an empty map: `nil`.
    private static func notifyProps(_ c: KeyedDecodingContainer<Keys>) -> UserNotifyProps? {
        guard let props = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: .notify_props) else { return nil }
        var raw: [String: String] = [:]
        var complete = true
        for key in props.allKeys.prefix(UserNotifyProps.maximumKeys + 1) {
            guard let value = props.lenientString(key, maxBytes: UserNotifyProps.maximumValueBytes + 1) else {
                complete = false
                continue
            }
            raw[key.stringValue] = value
        }
        if props.allKeys.count > UserNotifyProps.maximumKeys + 1 { complete = false }
        guard !raw.isEmpty else { return nil }
        let bounded = UserNotifyProps.bounded(raw)
        return complete ? bounded : UserNotifyProps(values: bounded.values, isComplete: false)
    }

    private static func timeZone(_ c: KeyedDecodingContainer<Keys>) -> String? {
        guard let zone = try? c.nestedContainer(keyedBy: TimeZoneKeys.self, forKey: .timezone) else { return nil }
        let automatic = zone.lenientBool(.useAutomaticTimezone) ?? true
        let value = zone.lenientString(automatic ? .automaticTimezone : .manualTimezone, maxBytes: 64) ?? ""
        return value.isEmpty ? nil : value
    }

    /// `props.customStatus` is itself a JSON string (docs/research/channels.md §6).
    private static func customStatus(_ c: KeyedDecodingContainer<Keys>) -> CustomStatus? {
        guard let props = try? c.nestedContainer(keyedBy: PropKeys.self, forKey: .props),
              let raw = try? props.decodeIfPresent(String.self, forKey: .customStatus),
              !raw.isEmpty, raw.utf8.count <= 2_048,
              let wire = try? WireJSON.decoder().decode(CustomStatusWire.self, from: Data(raw.utf8))
        else { return nil }
        let status = CustomStatus(emoji: String(wire.emoji.prefix(80)), text: String(wire.text.prefix(128)),
                                  expiresAt: wire.duration.isEmpty ? nil : wire.expiresAt)
        return status.emoji.isEmpty && status.text.isEmpty ? nil : status
    }
}

struct CustomStatusWire: Decodable {
    let emoji: String
    let text: String
    let duration: String
    let expiresAt: Date?
    enum Keys: String, CodingKey { case emoji, text, duration, expires_at }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        emoji = c.lenientString(.emoji, maxBytes: 256) ?? ""
        text = c.lenientString(.text, maxBytes: 512) ?? ""
        duration = c.lenientString(.duration, maxBytes: 32) ?? ""
        // The zero Go time ("0001-01-01T00:00:00Z") means "no expiry".
        let raw = c.lenientString(.expires_at, maxBytes: 64) ?? ""
        let date = (try? Date(raw, strategy: .iso8601)) ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        expiresAt = date.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    }
}

public struct StatusWire: Decodable, Sendable {
    public let userID: UserID
    public let status: PresenceStatus
    public let isManual: Bool
    enum Keys: String, CodingKey { case user_id, status, manual }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        userID = try c.requiredID(UserID.self, .user_id)
        status = PresenceStatus(wire: c.lenientString(.status, maxBytes: 16) ?? "")
        isManual = c.lenientBool(.manual) ?? false
    }
}

/// A server preference row. Values are strings; only small categories are retained.
public struct Preference: Hashable, Sendable {
    public let category: String
    public let name: String
    public let value: String

    public init(category: String, name: String, value: String) {
        self.category = category
        self.name = name
        self.value = value
    }
}

public struct PreferenceWire: Decodable, Sendable {
    public let preference: Preference
    enum Keys: String, CodingKey { case category, name, value }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        preference = Preference(
            category: String((c.lenientString(.category, maxBytes: 64) ?? "").prefix(32)),
            name: String((c.lenientString(.name, maxBytes: 64) ?? "").prefix(64)),
            // Theme values can be large JSON; we never need them (local appearance only).
            value: String((c.lenientString(.value, maxBytes: 4_096) ?? "").prefix(1_024)))
    }
}

public struct ChannelStatsWire: Decodable, Sendable {
    public let channelID: ChannelID
    public let memberCount: Int
    public let pinnedPostCount: Int
    enum Keys: String, CodingKey { case channel_id, member_count, pinnedpost_count }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        channelID = try c.requiredID(ChannelID.self, .channel_id)
        memberCount = Int(clamping: c.lenientInt64(.member_count) ?? 0)
        pinnedPostCount = Int(clamping: c.lenientInt64(.pinnedpost_count) ?? 0)
    }
}

/// `POST /channels/members/{user}/view` response.
public struct ChannelViewResponseWire: Decodable, Sendable {
    public let lastViewedAt: [ChannelID: MattermostTimestamp]
    enum Keys: String, CodingKey { case status, last_viewed_at_times }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        var map: [ChannelID: MattermostTimestamp] = [:]
        if let raw = try? c.decodeIfPresent([String: Int64].self, forKey: .last_viewed_at_times) {
            for (key, value) in raw.prefix(64) {
                if let id = ChannelID(rawValue: key) { map[id] = MattermostTimestamp(milliseconds: value) }
            }
        }
        lastViewedAt = map
    }
}

public struct FileUploadResponseWire: Decodable, Sendable {
    public let fileInfos: [FileInfo]
    public let clientIDs: [String]
    enum Keys: String, CodingKey { case file_infos, client_ids }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        fileInfos = try c.decode([FileInfoWire].self, forKey: .file_infos).map(\.info)
        clientIDs = ((try? c.decodeIfPresent([String].self, forKey: .client_ids)) ?? []).prefix(16).map { String($0.prefix(64)) }
    }
}

/// Mattermost `AppError` body. Only the machine-readable `id`, `status_code`, and
/// `request_id` are kept: `message` and `detailed_error` can echo user content and are
/// never retained, logged, or displayed.
public struct ServerErrorInfo: Hashable, Sendable, CustomStringConvertible {
    public let id: String
    public let statusCode: Int
    public let requestID: String?

    public init(id: String, statusCode: Int, requestID: String?) {
        self.id = id
        self.statusCode = statusCode
        self.requestID = requestID
    }

    public var description: String { "ServerError(\(statusCode), \(id))" }

    /// Parses an error body; returns an info with an empty id if the body is not an
    /// AppError. Error ids are restricted to `[a-z0-9._-]` and 160 bytes.
    public static func parse(_ data: Data, status: Int) -> ServerErrorInfo {
        struct Body: Decodable {
            let id: String?
            let request_id: String?
            let status_code: Int?
        }
        guard data.count <= 64 * 1_024, let body = try? JSONDecoder().decode(Body.self, from: data) else {
            return ServerErrorInfo(id: "", statusCode: status, requestID: nil)
        }
        func clean(_ raw: String?, max: Int) -> String? {
            guard let raw, raw.utf8.count <= max,
                  raw.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e || $0 == 0x5f || $0 == 0x2d || ($0 >= 0x41 && $0 <= 0x5a) })
            else { return nil }
            return raw
        }
        return ServerErrorInfo(id: clean(body.id, max: 160) ?? "", statusCode: body.status_code ?? status,
                               requestID: clean(body.request_id, max: 64))
    }
}

/// Unauthenticated `GET /api/v4/system/ping`.
public struct PingWire: Decodable, Sendable {
    public let status: String
    enum Keys: String, CodingKey { case status }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        status = c.lenientString(.status, maxBytes: 16) ?? ""
    }
}

/// `GET /api/v4/config/client?format=old`. The unauthenticated (limited) form lacks
/// most limits; the authenticated form adds them. All values are strings.
public struct ClientConfigWire: Decodable, Sendable {
    public let capabilities: ServerCapabilities
    public let typingIntervalMilliseconds: Int?
    public let enableUserTypingMessages: Bool?
    public let websocketURL: String?
    /// `TeammateNameDisplay` (`username`, `nickname_full_name`, `full_name`).
    public let teammateNameDisplay: String?
    public let lockTeammateNameDisplay: Bool?

    enum Keys: String, CodingKey {
        case Version, BuildNumber, SiteName, EnableSignInWithEmail, EnableSignInWithUsername, EnableLdap
        case GitLabButtonText, OpenIdButtonText, SamlLoginButtonText
        case LdapLoginFieldName, EnableSignUpWithGitLab, EnableSignUpWithGoogle, EnableSignUpWithOffice365
        case EnableSignUpWithOpenId, EnableSaml, PasswordMinimumLength, CollapsedThreads, MaxFileSize, MaxPostSize
        case EnableFileAttachments, EnableCustomEmoji, EnableUserAccessTokens, PostEditTimeLimit
        case UniqueEmojiReactionLimitPerPost, ExperimentalTownSquareIsReadOnly
        case TimeBetweenUserTypingUpdatesMilliseconds, EnableUserTypingMessages, WebsocketURL
        case TeammateNameDisplay, LockTeammateNameDisplay
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func bool(_ key: Keys) -> Bool? { c.lenientBool(key) }
        func int(_ key: Keys) -> Int? { c.lenientInt64(key).map { Int(clamping: $0) } }
        var providerLabels: [SSOProvider: String] = [:]
        for (provider, key) in [(SSOProvider.gitlab, Keys.GitLabButtonText), (.openID, .OpenIdButtonText), (.saml, .SamlLoginButtonText)] {
            if let label = c.lenientString(key, maxBytes: ResourceBudget.standard.authenticationProviderLabelBytes),
               !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                providerLabels[provider] = label
            }
        }
        let login = LoginOptions(
            email: bool(.EnableSignInWithEmail) ?? false,
            username: bool(.EnableSignInWithUsername) ?? false,
            ldap: bool(.EnableLdap) ?? false,
            ldapFieldName: String((c.lenientString(.LdapLoginFieldName) ?? "").prefix(64)),
            gitlab: bool(.EnableSignUpWithGitLab) ?? false,
            google: bool(.EnableSignUpWithGoogle) ?? false,
            office365: bool(.EnableSignUpWithOffice365) ?? false,
            openID: bool(.EnableSignUpWithOpenId) ?? false,
            saml: bool(.EnableSaml) ?? false,
            passwordMinimumLength: int(.PasswordMinimumLength), ssoProviderLabels: providerLabels)
        capabilities = ServerCapabilities(
            version: c.lenientString(.Version, maxBytes: 64).flatMap(ServerVersion.init(parsing:)),
            buildNumber: String((c.lenientString(.BuildNumber) ?? "").prefix(64)),
            siteName: String((c.lenientString(.SiteName) ?? "").prefix(128)),
            login: login,
            collapsedThreads: CollapsedThreadsMode(config: c.lenientString(.CollapsedThreads, maxBytes: 32)),
            maximumFileSize: c.lenientInt64(.MaxFileSize),
            maximumPostCharacters: int(.MaxPostSize),
            fileAttachmentsEnabled: bool(.EnableFileAttachments),
            customEmojiEnabled: bool(.EnableCustomEmoji),
            personalAccessTokensEnabled: bool(.EnableUserAccessTokens),
            postEditTimeLimitSeconds: int(.PostEditTimeLimit),
            uniqueReactionLimitPerPost: int(.UniqueEmojiReactionLimitPerPost),
            experimentalTownSquareReadOnly: bool(.ExperimentalTownSquareIsReadOnly))
        typingIntervalMilliseconds = int(.TimeBetweenUserTypingUpdatesMilliseconds)
        enableUserTypingMessages = bool(.EnableUserTypingMessages)
        websocketURL = c.lenientString(.WebsocketURL, maxBytes: 2_048).flatMap { $0.isEmpty ? nil : $0 }
        teammateNameDisplay = c.lenientString(.TeammateNameDisplay, maxBytes: 32).flatMap { $0.isEmpty ? nil : $0 }
        lockTeammateNameDisplay = bool(.LockTeammateNameDisplay)
    }
}

public struct CommandResponseWire: Decodable, Sendable {
    public let result: CommandResult
    enum Keys: String, CodingKey { case response_type, text, goto_location }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = c.lenientString(.response_type, maxBytes: 32) ?? ""
        let goto = c.lenientString(.goto_location, maxBytes: 2_048) ?? ""
        result = CommandResult(isEphemeral: type != "in_channel",
                               text: String((c.lenientString(.text, maxBytes: 16_384) ?? "").prefix(4_000)),
                               gotoLocation: goto.isEmpty ? nil : goto)
    }
}
