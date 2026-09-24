import Foundation
public import MatterMacModels
import MattermostAPI

/// Information from the server's `hello` event.
public struct RealtimeHello: Sendable, Hashable {
    /// The server-assigned connection id (26 characters); `nil` if missing/invalid.
    public let connectionID: String?
    /// `"<version>.<build>.<config hash>.<licensed>"` (≤ 128 bytes, `[A-Za-z0-9._+-]`).
    public let serverVersion: String?
    /// `broadcast.user_id` of the hello (the authenticated user).
    public let userID: UserID?

    public init(connectionID: String?, serverVersion: String?, userID: UserID?) {
        self.connectionID = connectionID
        self.serverVersion = serverVersion
        self.userID = userID
    }
}

/// A reply to one client action (`{"status":"OK"|"FAIL","seq_reply":N,...}`).
struct ActionResponse: Sendable, Hashable {
    let seqReply: Int64?
    let isOK: Bool
    /// `error.status_code` of a FAIL reply (401 for `not_authenticated`).
    let statusCode: Int?
}

/// One classified inbound frame. Produced off the actor by `RealtimeFrameDecoder`.
enum InboundFrame: Sendable {
    case hello(RealtimeHello, seq: Int64?)
    case event(RealtimeEvent, seq: Int64?)
    /// A known event whose payload could not be decoded within bounds.
    case malformedEvent(seq: Int64?, durable: Bool)
    case response(ActionResponse)
    /// Text that is not JSON or is neither an event nor a response.
    case unreadable
    case binary
    /// Larger than the receive ceiling (only reachable when a transport delivers a
    /// frame above the limit instead of failing).
    case oversized
}

/// Classifies frames and decodes every handled event (SPEC §10). Frames with an
/// `event` key are events; otherwise frames with a `status` key are action
/// responses. JSON is always parsed (server formatting varies). Payload fields that
/// the server sends as JSON-encoded *strings* (post, reaction, channel,
/// channelMember, team, preferences, thread, mentions, teammate_ids) are decoded a
/// second time with the MattermostAPI wire DTOs, within the same frame budget.
struct RealtimeFrameDecoder: Sendable {
    let currentUserID: UserID
    let maximumFrameBytes: Int

    /// Bound on `multiple_channels_viewed.channel_times` entries.
    static let maximumViewedChannels = 5_000
    /// Bound on preferences in one `preferences_changed`/`_deleted` event.
    static let maximumPreferences = 1_000
    /// Bound on unknown event names delivered as `.unhandled`.
    static let maximumEventNameBytes = 64

    func decode(_ frame: WebSocketFrame) -> InboundFrame {
        switch frame {
        case .binary:
            return .binary
        case .text(let text):
            guard text.utf8.count <= maximumFrameBytes else { return .oversized }
            let decoder = WireJSON.decoder()
            decoder.userInfo[RealtimeDecodingContext.key] = RealtimeDecodingContext(currentUserID: currentUserID)
            guard let envelope = try? decoder.decode(EnvelopeWire.self, from: Data(text.utf8)) else {
                return .unreadable
            }
            return envelope.frame
        }
    }

    /// Keeps `[A-Za-z0-9_.:-]`, replaces anything else with `_`, and bounds the length.
    static func boundedEventName(_ name: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(name.utf8.count, maximumEventNameBytes))
        for byte in name.utf8.prefix(maximumEventNameBytes) {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "."),
                 UInt8(ascii: ":"), UInt8(ascii: "-"):
                bytes.append(byte)
            default:
                bytes.append(UInt8(ascii: "_"))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct RealtimeDecodingContext: Sendable {
    static let key = CodingUserInfoKey(rawValue: "mattermac.realtime.context")!
    let currentUserID: UserID
}

/// Event names MatterMac handles (SPEC §10; research table in docs/research/websocket.md).
enum HandledEventName: String {
    case hello
    case posted
    case postEdited = "post_edited"
    case postDeleted = "post_deleted"
    case postUnread = "post_unread"
    case ephemeralMessage = "ephemeral_message"
    case reactionAdded = "reaction_added"
    case reactionRemoved = "reaction_removed"
    case typing
    case statusChange = "status_change"
    case multipleChannelsViewed = "multiple_channels_viewed"
    case channelCreated = "channel_created"
    case channelUpdated = "channel_updated"
    case channelDeleted = "channel_deleted"
    case channelRestored = "channel_restored"
    case channelConverted = "channel_converted"
    case channelMemberUpdated = "channel_member_updated"
    case directAdded = "direct_added"
    case groupAdded = "group_added"
    case userAdded = "user_added"
    case userRemoved = "user_removed"
    case addedToTeam = "added_to_team"
    case leaveTeam = "leave_team"
    case updateTeam = "update_team"
    case restoreTeam = "restore_team"
    case updateTeamScheme = "update_team_scheme"
    case deleteTeam = "delete_team"
    case userUpdated = "user_updated"
    case userRoleUpdated = "user_role_updated"
    case preferencesChanged = "preferences_changed"
    case preferenceChanged = "preference_changed"
    case preferencesDeleted = "preferences_deleted"
    case threadUpdated = "thread_updated"
    case threadReadChanged = "thread_read_changed"
    case threadFollowChanged = "thread_follow_changed"
    case emojiAdded = "emoji_added"
    case configChanged = "config_changed"
    case licenseChanged = "license_changed"

    /// Durable events change server state Core mirrors. A malformed durable event is
    /// never ignored: it becomes `.resynchronize(.malformedEvent)`. Typing and the
    /// (self-only) status change are replaceable signals and are dropped instead.
    var isDurable: Bool {
        switch self {
        case .typing, .statusChange: false
        default: true
        }
    }
}

// MARK: - Wire envelope

struct AnyKey: CodingKey {
    let stringValue: String
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

private struct EnvelopeWire: Decodable {
    let frame: InboundFrame

    enum Keys: String, CodingKey { case event, status, seq, seq_reply, data, broadcast, error }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.event) {
            guard let name = try? c.decode(String.self, forKey: .event) else {
                frame = .unreadable
                return
            }
            let seq = try? c.decodeIfPresent(Int64.self, forKey: .seq)
            guard let kind = HandledEventName(rawValue: name) else {
                frame = .event(.unhandled(name: RealtimeFrameDecoder.boundedEventName(name)), seq: seq)
                return
            }
            let context = decoder.userInfo[RealtimeDecodingContext.key] as? RealtimeDecodingContext
            let broadcast = (try? c.decodeIfPresent(BroadcastWire.self, forKey: .broadcast)) ?? BroadcastWire()
            do {
                let data = c.contains(.data) && (try? c.decodeNil(forKey: .data)) != true
                    ? try c.nestedContainer(keyedBy: AnyKey.self, forKey: .data)
                    : nil
                if kind == .hello {
                    frame = .hello(Self.hello(data, broadcast), seq: seq)
                } else {
                    let event = try Self.event(kind, data, broadcast, currentUserID: context?.currentUserID)
                    frame = .event(event, seq: seq)
                }
            } catch {
                frame = .malformedEvent(seq: seq, durable: kind.isDurable)
            }
        } else if c.contains(.status) {
            let status = (try? c.decode(String.self, forKey: .status)) ?? ""
            let seqReply = try? c.decodeIfPresent(Int64.self, forKey: .seq_reply)
            var statusCode: Int?
            if let error = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .error) {
                statusCode = error.lenientInt64("status_code").map { Int(clamping: $0) }
            }
            frame = .response(ActionResponse(seqReply: seqReply, isOK: status == "OK", statusCode: statusCode))
        } else {
            frame = .unreadable
        }
    }

    private static func hello(_ data: KeyedDecodingContainer<AnyKey>?, _ broadcast: BroadcastWire) -> RealtimeHello {
        let connectionID = data?.lenientString("connection_id").flatMap { IdentifierValidation.isValid($0) ? $0 : nil }
        let version = data?.lenientString("server_version").map { raw in
            String(decoding: raw.utf8.prefix(128).filter { byte in
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "-"),
                     UInt8(ascii: "_"), UInt8(ascii: "+"):
                    true
                default:
                    false
                }
            }, as: UTF8.self)
        }
        return RealtimeHello(connectionID: connectionID, serverVersion: version, userID: broadcast.userID)
    }

    private static func event(_ kind: HandledEventName, _ data: KeyedDecodingContainer<AnyKey>?,
                              _ broadcast: BroadcastWire, currentUserID: UserID?) throws -> RealtimeEvent {
        switch kind {
        case .emojiAdded: return .emojiAdded
        case .configChanged: return .configChanged
        case .licenseChanged: return .licenseChanged
        case .hello: throw PayloadError.unexpected
        default: break
        }
        guard let data else { throw PayloadError.missingData }
        switch kind {
        case .posted:
            let post = try data.nestedJSON(PostWire.self, "post").post
            let mentions = try data.optionalNestedJSON([String].self, "mentions") ?? []
            let mentioned = currentUserID.map { me in mentions.prefix(10_000).contains(me.rawValue) } ?? false
            return .posted(PostedEvent(
                post: post,
                channelType: ChannelType(wire: data.lenientString("channel_type") ?? ""),
                teamID: try data.optionalID(TeamID.self, "team_id"),
                mentionsCurrentUser: mentioned,
                setOnline: data.lenientBool("set_online") ?? false))
        case .postEdited:
            return .postEdited(try data.nestedJSON(PostWire.self, "post").post)
        case .postDeleted:
            return .postDeleted(try data.nestedJSON(PostWire.self, "post").post)
        case .ephemeralMessage:
            return .ephemeralMessage(try data.nestedJSON(PostWire.self, "post").post)
        case .postUnread:
            guard let channelID = try broadcast.channelID ?? data.optionalID(ChannelID.self, "channel_id") else {
                throw PayloadError.missingIdentity
            }
            return .postUnread(PostUnreadEvent(
                channelID: channelID,
                teamID: try broadcast.teamID ?? data.optionalID(TeamID.self, "team_id"),
                postID: try data.optionalID(PostID.self, "post_id"),
                messageCount: data.lenientInt64("msg_count") ?? 0,
                messageCountRoot: data.lenientInt64("msg_count_root") ?? 0,
                mentionCount: data.lenientInt64("mention_count") ?? 0,
                mentionCountRoot: data.lenientInt64("mention_count_root") ?? 0,
                urgentMentionCount: data.lenientInt64("urgent_mention_count") ?? 0,
                lastViewedAt: MattermostTimestamp(milliseconds: data.lenientInt64("last_viewed_at") ?? 0)))
        case .reactionAdded:
            return .reactionAdded(try data.nestedJSON(ReactionWire.self, "reaction").reaction)
        case .reactionRemoved:
            return .reactionRemoved(try data.nestedJSON(ReactionWire.self, "reaction").reaction)
        case .typing:
            guard let channelID = broadcast.channelID else { throw PayloadError.missingIdentity }
            return .typing(userID: try data.requiredID(UserID.self, "user_id"), channelID: channelID,
                           parentID: try data.optionalID(PostID.self, "parent_id"))
        case .statusChange:
            let status = data.lenientString("status") ?? ""
            guard !status.isEmpty else { throw PayloadError.missingField }
            return .statusChanged(userID: try data.requiredID(UserID.self, "user_id"),
                                  status: PresenceStatus(wire: status))
        case .multipleChannelsViewed:
            let times = try data.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("channel_times"))
            guard times.allKeys.count <= RealtimeFrameDecoder.maximumViewedChannels else { throw PayloadError.tooLarge }
            var map: [ChannelID: MattermostTimestamp] = [:]
            map.reserveCapacity(times.allKeys.count)
            for key in times.allKeys {
                guard let id = ChannelID(rawValue: key.stringValue), let ms = times.lenientInt64(key.stringValue) else {
                    throw PayloadError.missingIdentity
                }
                map[id] = MattermostTimestamp(milliseconds: ms)
            }
            return .channelsViewed(map)
        case .channelCreated:
            return .channelCreated(channelID: try data.requiredID(ChannelID.self, "channel_id"),
                                   teamID: try data.optionalID(TeamID.self, "team_id"))
        case .channelUpdated:
            if data.contains(AnyKey("channel")) {
                return .channelUpdated(try data.nestedJSON(ChannelWire.self, "channel").channel)
            }
            return .channelChanged(try data.requiredID(ChannelID.self, "channel_id"))
        case .channelDeleted:
            return .channelDeleted(channelID: try data.requiredID(ChannelID.self, "channel_id"),
                                   deleteAt: MattermostTimestamp(milliseconds: data.lenientInt64("delete_at") ?? 0))
        case .channelRestored:
            return .channelRestored(try data.requiredID(ChannelID.self, "channel_id"))
        case .channelConverted:
            return .channelConverted(try data.requiredID(ChannelID.self, "channel_id"))
        case .channelMemberUpdated:
            return .channelMemberUpdated(try data.nestedJSON(ChannelMemberWire.self, "channelMember").membership)
        case .directAdded:
            guard let channelID = broadcast.channelID else { throw PayloadError.missingIdentity }
            return .directAdded(channelID: channelID)
        case .groupAdded:
            guard let channelID = broadcast.channelID else { throw PayloadError.missingIdentity }
            // Validated (bounded, identity-checked) even though Core only needs the id.
            if let teammates = try data.optionalNestedJSON([String].self, "teammate_ids") {
                guard teammates.count <= 256, teammates.allSatisfy(IdentifierValidation.isValid) else {
                    throw PayloadError.missingIdentity
                }
            }
            return .groupAdded(channelID: channelID)
        case .userAdded:
            // The channel id is only in the broadcast envelope.
            guard let channelID = broadcast.channelID else { throw PayloadError.missingIdentity }
            return .userAdded(userID: try data.requiredID(UserID.self, "user_id"), channelID: channelID,
                              teamID: try data.optionalID(TeamID.self, "team_id"))
        case .userRemoved:
            // Channel-scoped copy: user_id in data, channel in broadcast. Copy sent to
            // the removed user: channel_id in data, user in broadcast.
            guard let userID = try data.optionalID(UserID.self, "user_id") ?? broadcast.userID,
                  let channelID = try data.optionalID(ChannelID.self, "channel_id") ?? broadcast.channelID
            else { throw PayloadError.missingIdentity }
            return .userRemoved(userID: userID, channelID: channelID,
                                removerID: try data.optionalID(UserID.self, "remover_id"))
        case .addedToTeam:
            return .addedToTeam(teamID: try data.requiredID(TeamID.self, "team_id"),
                                userID: try data.requiredID(UserID.self, "user_id"))
        case .leaveTeam:
            return .leftTeam(teamID: try data.requiredID(TeamID.self, "team_id"),
                             userID: try data.requiredID(UserID.self, "user_id"))
        case .updateTeam, .restoreTeam, .updateTeamScheme:
            return .teamUpdated(try data.nestedJSON(TeamWire.self, "team").team)
        case .deleteTeam:
            return .teamDeleted(try data.nestedJSON(TeamWire.self, "team").team.id)
        case .userUpdated:
            // `user` is an object here, not a JSON string.
            return .userUpdated(try data.decode(UserWire.self, forKey: AnyKey("user")).user)
        case .userRoleUpdated:
            return .userRoleUpdated(userID: try data.requiredID(UserID.self, "user_id"))
        case .preferencesChanged:
            return .preferencesChanged(try preferences(data, key: "preferences"))
        case .preferencesDeleted:
            return .preferencesDeleted(try preferences(data, key: "preferences"))
        case .preferenceChanged:
            return .preferencesChanged([try data.nestedJSON(PreferenceWire.self, "preference").preference])
        case .threadUpdated:
            let thread = try data.nestedJSON(ThreadWire.self, "thread")
            return .threadUpdated(threadID: thread.id, channelID: thread.channelID)
        case .threadReadChanged:
            // Variants: `{}` (team marked read), `{timestamp}` (channel marked
            // read/unread; channel in the broadcast), or a single thread.
            return .threadReadChanged(threadID: try data.optionalID(PostID.self, "thread_id"),
                                      channelID: try data.optionalID(ChannelID.self, "channel_id")
                                          ?? broadcast.channelID)
        case .threadFollowChanged:
            guard let state = data.lenientBool("state") else { throw PayloadError.missingField }
            return .threadFollowChanged(threadID: try data.requiredID(PostID.self, "thread_id"), isFollowing: state)
        case .hello, .emojiAdded, .configChanged, .licenseChanged:
            throw PayloadError.unexpected
        }
    }

    private static func preferences(_ data: KeyedDecodingContainer<AnyKey>, key: String) throws -> [Preference] {
        let list = try data.nestedJSON(LossyArray<PreferenceWire>.self, key)
        guard list.skipped == 0, list.elements.count <= RealtimeFrameDecoder.maximumPreferences else {
            throw PayloadError.tooLarge
        }
        return list.elements.map(\.preference)
    }
}

private enum PayloadError: Error {
    case missingData, missingField, missingIdentity, tooLarge, unexpected
}

/// The broadcast envelope fields MatterMac uses. Empty strings mean "not scoped".
private struct BroadcastWire: Decodable {
    var channelID: ChannelID?
    var teamID: TeamID?
    var userID: UserID?

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        channelID = c.lenientString("channel_id").flatMap(ChannelID.init(rawValue:))
        teamID = c.lenientString("team_id").flatMap(TeamID.init(rawValue:))
        userID = c.lenientString("user_id").flatMap(UserID.init(rawValue:))
    }
}

/// `thread_updated.thread` (a `ThreadResponse`). Participants and the embedded post
/// body are not retained; only identity is extracted.
private struct ThreadWire: Decodable {
    let id: PostID
    let channelID: ChannelID?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredID(PostID.self, "id")
        if let post = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("post")) {
            channelID = try post.optionalID(ChannelID.self, "channel_id")
        } else {
            channelID = nil
        }
    }
}

extension KeyedDecodingContainer where K == AnyKey {
    func lenientString(_ key: String) -> String? {
        let k = AnyKey(key)
        if let value = try? decodeIfPresent(String.self, forKey: k) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: k) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: k) { return value ? "true" : "false" }
        return nil
    }

    func lenientInt64(_ key: String) -> Int64? {
        let k = AnyKey(key)
        if let value = try? decodeIfPresent(Int64.self, forKey: k) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: k), value.isFinite, abs(value) < 9.0e15 {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: k) { return Int64(value) }
        return nil
    }

    func lenientBool(_ key: String) -> Bool? {
        let k = AnyKey(key)
        if let value = try? decodeIfPresent(Bool.self, forKey: k) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: k) {
            switch value {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    /// Required identifier; missing or invalid throws (malformed identity).
    func requiredID<ID: MattermostIdentifier>(_ type: ID.Type, _ key: String) throws -> ID {
        guard let raw = try decodeIfPresent(String.self, forKey: AnyKey(key)), let id = ID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "invalid identifier"))
        }
        return id
    }

    /// Optional identifier: missing, null, or `""` → nil; a non-empty invalid value
    /// throws (malformed identity is not ignored).
    func optionalID<ID: MattermostIdentifier>(_ type: ID.Type, _ key: String) throws -> ID? {
        guard let raw = try decodeIfPresent(String.self, forKey: AnyKey(key)), !raw.isEmpty else { return nil }
        guard let id = ID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "invalid identifier"))
        }
        return id
    }

    /// Decodes a value the server sends as a JSON-encoded string.
    func nestedJSON<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        let string = try decode(String.self, forKey: AnyKey(key))
        return try WireJSON.decoder().decode(T.self, from: Data(string.utf8))
    }

    func optionalNestedJSON<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        guard let string = try decodeIfPresent(String.self, forKey: AnyKey(key)), !string.isEmpty else { return nil }
        return try WireJSON.decoder().decode(T.self, from: Data(string.utf8))
    }
}
