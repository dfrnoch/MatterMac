import Foundation

/// Builders for Mattermost WebSocket frames in the exact wire shapes observed from
/// Mattermost v11.11.1 (captured locally, docs/research/websocket.md) and read
/// from server source: precomputed events use `": "` spacing, hook-processed events
/// (`posted`) and `hello` are compact, payloads such as `post`, `reaction`, `channel`,
/// `channelMember`, `team`, `preferences`, `thread`, `mentions`, and `teammate_ids`
/// are JSON-encoded *strings* inside `data`, and `user_updated.user` is an object.
/// All identifiers are synthetic.
public enum RealtimeFixtures {
    // MARK: Synthetic identities (26 lowercase alphanumerics like server ids)

    public static let aliceID = "qnoo9uxat3gubgs5iqfbo74zxe"
    public static let bobID = "z1o7kiapxfbwz8jnb3w9u9mkyy"
    public static let channelID = "p9bx16i46pycpf3ki5m43r8k1o"
    public static let teamID = "xzywwxr1b3ymdqdimz4kjyuhhw"
    public static let postID = "ihjw14ss6tnptbfeex675x7wgc"
    public static let connectionID = "jr9b8fk4mfgb7qupand7hxhmxw"
    public static let serverVersion =
        "11.11.1.35958890150.6f6b4b05e22025f1376daab0448a1d52d7370929b3c957688ea8caef0a91647b.false"

    /// Deterministic synthetic id for index `n` (26 characters).
    public static func id(_ prefix: String, _ n: Int) -> String {
        let base = (prefix + String(n)).lowercased().filter { $0.isLetter || $0.isNumber }
        return String((base + String(repeating: "x", count: 26)).prefix(26))
    }

    // MARK: Encoding helpers

    /// A JSON string literal (quoted, escaped).
    public static func quoted(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public struct Broadcast: Sendable {
        public var userID: String
        public var channelID: String
        public var teamID: String
        public var omitUsers: [String]?
        public var containsSanitizedData: Bool

        public init(userID: String = "", channelID: String = "", teamID: String = "", omitUsers: [String]? = nil,
                    containsSanitizedData: Bool = false) {
            self.userID = userID
            self.channelID = channelID
            self.teamID = teamID
            self.omitUsers = omitUsers
            self.containsSanitizedData = containsSanitizedData
        }

        public var json: String {
            let omit = omitUsers.map { users in "{" + users.map { "\(quoted($0)):true" }.joined(separator: ",") + "}" } ?? "null"
            var text = "{\"omit_users\":\(omit),\"user_id\":\(quoted(userID)),\"channel_id\":\(quoted(channelID)),"
                + "\"team_id\":\(quoted(teamID)),\"connection_id\":\"\",\"omit_connection_id\":\"\""
            if containsSanitizedData { text += ",\"contains_sanitized_data\":true" }
            return text + "}"
        }
    }

    public enum Spacing: Sendable {
        /// `{"event": "x", "data": {...}, "broadcast": {...}, "seq": 3}` (precomputed events).
        case precomputed
        /// `{"event":"x","data":{...},"broadcast":{...},"seq":3}` (hook-processed events).
        case compact
    }

    public static func envelope(event: String, data: String, broadcast: Broadcast, seq: Int64,
                                spacing: Spacing = .precomputed) -> String {
        switch spacing {
        case .precomputed:
            "{\"event\": \(quoted(event)), \"data\": \(data), \"broadcast\": \(broadcast.json), \"seq\": \(seq)}"
        case .compact:
            "{\"event\":\(quoted(event)),\"data\":\(data),\"broadcast\":\(broadcast.json),\"seq\":\(seq)}"
        }
    }

    // MARK: Connection frames

    /// `hello` as written directly by the server (compact, trailing newline).
    public static func hello(connectionID: String = connectionID, userID: String = aliceID, seq: Int64 = 0,
                             serverVersion: String = serverVersion) -> String {
        let data = "{\"connection_id\":\(quoted(connectionID)),\"server_hostname\":\"34eda0afb747\","
            + "\"server_version\":\(quoted(serverVersion))}"
        return envelope(event: "hello", data: data, broadcast: Broadcast(userID: userID), seq: seq, spacing: .compact)
            + "\n"
    }

    public static func pingReply(seq: Int64, version: String = "11.11.1") -> String {
        "{\"status\":\"OK\",\"seq_reply\":\(seq),\"data\":{\"node_id\":\"\",\"server_time\":1790268735218,"
            + "\"text\":\"pong\",\"version\":\(quoted(version))}}"
    }

    public static func okReply(seq: Int64) -> String {
        "{\"status\":\"OK\",\"seq_reply\":\(seq)}"
    }

    public static func failReply(seq: Int64, statusCode: Int = 401,
                                 id: String = "api.web_socket_router.not_authenticated.app_error") -> String {
        "{\"status\":\"FAIL\",\"seq_reply\":\(seq),\"error\":{\"id\":\(quoted(id)),"
            + "\"message\":\"redacted\",\"detailed_error\":\"\",\"status_code\":\(statusCode)}}"
    }

    // MARK: Entities (inner JSON)

    public static func postJSON(id: String = postID, channelID: String = channelID, userID: String = bobID,
                                message: String = "[fixture] hello", rootID: String = "", type: String = "",
                                createAt: Int64 = 1_790_268_735_233, updateAt: Int64? = nil, editAt: Int64 = 0,
                                deleteAt: Int64 = 0, pendingPostID: String = "", fileIDs: [String] = [],
                                props: String = "{}", metadata: String? = "{}") -> String {
        var text = "{\"id\":\(quoted(id)),\"create_at\":\(createAt),\"update_at\":\(updateAt ?? createAt),"
            + "\"edit_at\":\(editAt),\"delete_at\":\(deleteAt),\"is_pinned\":false,\"user_id\":\(quoted(userID)),"
            + "\"channel_id\":\(quoted(channelID)),\"root_id\":\(quoted(rootID)),\"original_id\":\"\","
            + "\"message\":\(quoted(message)),\"type\":\(quoted(type)),\"props\":\(props),\"hashtags\":\"\","
            + "\"file_ids\":[\(fileIDs.map(quoted).joined(separator: ","))],"
            + "\"pending_post_id\":\(quoted(pendingPostID)),\"remote_id\":\"\",\"reply_count\":0,"
            + "\"last_reply_at\":0,\"participants\":null"
        if let metadata { text += ",\"metadata\":\(metadata)" }
        return text + "}"
    }

    public static func reactionJSON(userID: String = bobID, postID: String = postID, emojiName: String = "+1",
                                    createAt: Int64 = 1_790_268_735_660, channelID: String = channelID) -> String {
        "{\"user_id\":\(quoted(userID)),\"post_id\":\(quoted(postID)),\"emoji_name\":\(quoted(emojiName)),"
            + "\"create_at\":\(createAt),\"update_at\":\(createAt),\"delete_at\":0,\"remote_id\":\"\","
            + "\"channel_id\":\(quoted(channelID))}"
    }

    public static func channelJSON(id: String = channelID, teamID: String = teamID, type: String = "O",
                                   name: String = "interop", displayName: String = "Interop",
                                   header: String = "", purpose: String = "", deleteAt: Int64 = 0) -> String {
        "{\"id\":\(quoted(id)),\"create_at\":1790265847057,\"update_at\":1790268735000,\"delete_at\":\(deleteAt),"
            + "\"team_id\":\(quoted(teamID)),\"type\":\(quoted(type)),\"display_name\":\(quoted(displayName)),"
            + "\"name\":\(quoted(name)),\"header\":\(quoted(header)),\"purpose\":\(quoted(purpose)),"
            + "\"last_post_at\":1790268735233,\"total_msg_count\":2,\"extra_update_at\":0,\"creator_id\":\"\","
            + "\"scheme_id\":null,\"props\":null,\"group_constrained\":null,\"shared\":null,"
            + "\"total_msg_count_root\":2,\"policy_id\":null,\"last_root_post_at\":1790268735233}"
    }

    public static func channelMemberJSON(channelID: String = channelID, userID: String = aliceID,
                                         lastViewedAt: Int64 = 1_790_268_735_232, markUnread: String = "all")
        -> String {
        "{\"channel_id\":\(quoted(channelID)),\"user_id\":\(quoted(userID)),\"roles\":\"channel_user\","
            + "\"last_viewed_at\":\(lastViewedAt),\"msg_count\":2,\"mention_count\":0,\"mention_count_root\":0,"
            + "\"urgent_mention_count\":0,\"msg_count_root\":2,\"notify_props\":{\"channel_auto_follow_threads\":"
            + "\"off\",\"desktop\":\"default\",\"email\":\"default\",\"ignore_channel_mentions\":\"default\","
            + "\"mark_unread\":\(quoted(markUnread)),\"push\":\"default\"},\"last_update_at\":1790268735968,"
            + "\"scheme_guest\":false,\"scheme_user\":true,\"scheme_admin\":false,\"explicit_roles\":\"\","
            + "\"autotranslation_disabled\":false}"
    }

    public static func teamJSON(id: String = teamID, name: String = "qa", displayName: String = "QA",
                                deleteAt: Int64 = 0) -> String {
        "{\"id\":\(quoted(id)),\"create_at\":1790265847000,\"update_at\":1790268735000,\"delete_at\":\(deleteAt),"
            + "\"display_name\":\(quoted(displayName)),\"name\":\(quoted(name)),\"description\":\"\",\"email\":\"\","
            + "\"type\":\"O\",\"company_name\":\"\",\"allowed_domains\":\"\",\"invite_id\":\"\","
            + "\"allow_open_invite\":true,\"scheme_id\":null,\"group_constrained\":null,\"policy_id\":null,"
            + "\"cloud_limits_archived\":false}"
    }

    /// `user_updated.user` object (sanitized form as delivered to other users).
    public static func userObject(id: String = aliceID, username: String = "alice", position: String = "",
                                  roles: String = "system_user") -> String {
        "{\"id\":\(quoted(id)),\"create_at\":1790265847057,\"update_at\":1790268735951,\"delete_at\":0,"
            + "\"username\":\(quoted(username)),\"auth_service\":\"\",\"email\":\"\",\"nickname\":\"\","
            + "\"first_name\":\"\",\"last_name\":\"\",\"position\":\(quoted(position)),\"roles\":\(quoted(roles)),"
            + "\"notify_props\":{\"desktop\":\"mention\"},\"last_password_update\":0,\"locale\":\"en\","
            + "\"timezone\":{\"automaticTimezone\":\"\",\"manualTimezone\":\"\",\"useAutomaticTimezone\":\"true\"},"
            + "\"remote_id\":\"\",\"disable_welcome_email\":false}"
    }

    public static func preferenceJSON(userID: String = aliceID, category: String = "display_settings",
                                      name: String = "use_military_time", value: String = "false") -> String {
        "{\"user_id\":\(quoted(userID)),\"category\":\(quoted(category)),\"name\":\(quoted(name)),"
            + "\"value\":\(quoted(value))}"
    }

    public static func threadJSON(id: String = postID, channelID: String = channelID) -> String {
        "{\"id\":\(quoted(id)),\"reply_count\":1,\"last_reply_at\":1790268736000,\"last_viewed_at\":0,"
            + "\"participants\":[{\"id\":\(quoted(bobID)),\"username\":\"bob\"}],\"post\":"
            + postJSON(id: id, channelID: channelID) + ",\"unread_replies\":1,\"unread_mentions\":0,"
            + "\"is_urgent\":false,\"delete_at\":0}"
    }

    // MARK: Events

    public static func posted(post: String = postJSON(), channelID: String = channelID, teamID: String = teamID,
                              channelType: String = "O", mentions: [String]? = nil, setOnline: Bool = true,
                              seq: Int64) -> String {
        var data = "{\"channel_display_name\":\"Interop\",\"channel_name\":\"interop\","
            + "\"channel_type\":\(quoted(channelType)),"
        if let mentions { data += "\"mentions\":\(quoted("[" + mentions.map(quoted).joined(separator: ",") + "]")),"}
        data += "\"post\":\(quoted(post)),\"sender_name\":\"@bob\",\"set_online\":\(setOnline),"
            + "\"team_id\":\(quoted(teamID))}"
        return envelope(event: "posted", data: data, broadcast: Broadcast(channelID: channelID), seq: seq,
                        spacing: .compact)
    }

    public static func postEdited(post: String = postJSON(editAt: 1_790_268_735_617), channelID: String = channelID,
                                  seq: Int64) -> String {
        envelope(event: "post_edited", data: "{\"post\":\(quoted(post))}", broadcast: Broadcast(channelID: channelID),
                 seq: seq)
    }

    /// The snapshot is taken before deletion, so `delete_at` is 0.
    public static func postDeleted(post: String = postJSON(metadata: nil), channelID: String = channelID,
                                   seq: Int64) -> String {
        envelope(event: "post_deleted", data: "{\"post\":\(quoted(post))}",
                 broadcast: Broadcast(channelID: channelID, containsSanitizedData: true), seq: seq)
    }

    public static func ephemeralMessage(post: String = postJSON(userID: aliceID, type: "system_ephemeral"),
                                        userID: String = aliceID, channelID: String = channelID,
                                        seq: Int64) -> String {
        envelope(event: "ephemeral_message", data: "{\"post\":\(quoted(post))}",
                 broadcast: Broadcast(userID: userID, channelID: channelID), seq: seq)
    }

    public static func postUnread(channelID: String = channelID, teamID: String = teamID, userID: String = aliceID,
                                  postID: String = postID, seq: Int64) -> String {
        envelope(event: "post_unread",
                 data: "{\"last_viewed_at\":1790268735232,\"mention_count\":1,\"mention_count_root\":1,"
                     + "\"msg_count\":2,\"msg_count_root\":2,\"post_id\":\(quoted(postID)),\"urgent_mention_count\":0}",
                 broadcast: Broadcast(userID: userID, channelID: channelID, teamID: teamID), seq: seq)
    }

    public static func reactionAdded(reaction: String = reactionJSON(), channelID: String = channelID,
                                     seq: Int64) -> String {
        envelope(event: "reaction_added", data: "{\"reaction\":\(quoted(reaction))}",
                 broadcast: Broadcast(channelID: channelID), seq: seq)
    }

    public static func reactionRemoved(reaction: String = reactionJSON(createAt: 0, channelID: ""),
                                       channelID: String = channelID, seq: Int64) -> String {
        envelope(event: "reaction_removed", data: "{\"reaction\":\(quoted(reaction))}",
                 broadcast: Broadcast(channelID: channelID), seq: seq)
    }

    public static func typing(userID: String = bobID, channelID: String = channelID, parentID: String = "",
                              seq: Int64) -> String {
        envelope(event: "typing", data: "{\"parent_id\":\(quoted(parentID)),\"user_id\":\(quoted(userID))}",
                 broadcast: Broadcast(channelID: channelID, omitUsers: [userID]), seq: seq)
    }

    public static func statusChange(userID: String = aliceID, status: String = "online", seq: Int64) -> String {
        envelope(event: "status_change", data: "{\"status\":\(quoted(status)),\"user_id\":\(quoted(userID))}",
                 broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func channelsViewed(_ times: [String: Int64], userID: String = aliceID, seq: Int64) -> String {
        let entries = times.sorted { $0.key < $1.key }.map { "\(quoted($0.key)):\($0.value)" }.joined(separator: ",")
        return envelope(event: "multiple_channels_viewed", data: "{\"channel_times\":{\(entries)}}",
                        broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func channelCreated(channelID: String = channelID, teamID: String = teamID,
                                      userID: String = aliceID, seq: Int64) -> String {
        envelope(event: "channel_created",
                 data: "{\"channel_id\":\(quoted(channelID)),\"team_id\":\(quoted(teamID))}",
                 broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func channelUpdated(channel: String = channelJSON(), channelID: String = channelID,
                                      seq: Int64) -> String {
        envelope(event: "channel_updated", data: "{\"channel\":\(quoted(channel))}",
                 broadcast: Broadcast(channelID: channelID), seq: seq)
    }

    /// Shared-channel variant: team-scoped, id only.
    public static func channelUpdatedIDOnly(channelID: String = channelID, teamID: String = teamID,
                                            seq: Int64) -> String {
        envelope(event: "channel_updated", data: "{\"channel_id\":\(quoted(channelID))}",
                 broadcast: Broadcast(teamID: teamID), seq: seq)
    }

    public static func channelDeleted(channelID: String = channelID, teamID: String = teamID,
                                      deleteAt: Int64 = 1_790_268_800_000, seq: Int64) -> String {
        envelope(event: "channel_deleted",
                 data: "{\"channel_id\":\(quoted(channelID)),\"delete_at\":\(deleteAt)}",
                 broadcast: Broadcast(teamID: teamID), seq: seq)
    }

    public static func channelRestored(channelID: String = channelID, teamID: String = teamID,
                                       seq: Int64) -> String {
        envelope(event: "channel_restored", data: "{\"channel_id\":\(quoted(channelID))}",
                 broadcast: Broadcast(teamID: teamID), seq: seq)
    }

    public static func channelConverted(channelID: String = channelID, teamID: String = teamID,
                                        seq: Int64) -> String {
        envelope(event: "channel_converted",
                 data: "{\"channel_id\":\(quoted(channelID)),\"channel_type\":\"P\"}",
                 broadcast: Broadcast(teamID: teamID), seq: seq)
    }

    public static func channelMemberUpdated(member: String = channelMemberJSON(), userID: String = aliceID,
                                            seq: Int64) -> String {
        envelope(event: "channel_member_updated", data: "{\"channelMember\":\(quoted(member))}",
                 broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func directAdded(channelID: String = channelID, creatorID: String = bobID,
                                   teammateID: String = aliceID, seq: Int64) -> String {
        envelope(event: "direct_added",
                 data: "{\"creator_id\":\(quoted(creatorID)),\"teammate_id\":\(quoted(teammateID))}",
                 broadcast: Broadcast(channelID: channelID), seq: seq)
    }

    public static func groupAdded(channelID: String = channelID, userID: String = aliceID,
                                  teammateIDs: [String] = [aliceID, bobID], seq: Int64) -> String {
        let ids = "[" + teammateIDs.map(quoted).joined(separator: ",") + "]"
        return envelope(event: "group_added", data: "{\"teammate_ids\":\(quoted(ids))}",
                        broadcast: Broadcast(userID: userID, channelID: channelID), seq: seq)
    }

    /// `user_added`: the channel id is only in the broadcast.
    public static func userAdded(userID: String = bobID, channelID: String = channelID, teamID: String = teamID,
                                 seq: Int64) -> String {
        envelope(event: "user_added", data: "{\"team_id\":\(quoted(teamID)),\"user_id\":\(quoted(userID))}",
                 broadcast: Broadcast(channelID: channelID, omitUsers: [userID]), seq: seq)
    }

    /// Channel-scoped copy (other members): user in data, channel in broadcast.
    public static func userRemovedFromChannel(userID: String = bobID, channelID: String = channelID,
                                              removerID: String = aliceID, seq: Int64) -> String {
        envelope(event: "user_removed",
                 data: "{\"remover_id\":\(quoted(removerID)),\"user_id\":\(quoted(userID))}",
                 broadcast: Broadcast(channelID: channelID), seq: seq)
    }

    /// Copy sent to the removed user: channel in data, user in broadcast.
    public static func userRemovedSelf(userID: String = aliceID, channelID: String = channelID,
                                       removerID: String = bobID, seq: Int64) -> String {
        envelope(event: "user_removed",
                 data: "{\"channel_id\":\(quoted(channelID)),\"remover_id\":\(quoted(removerID))}",
                 broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func addedToTeam(teamID: String = teamID, userID: String = aliceID, seq: Int64) -> String {
        envelope(event: "added_to_team", data: "{\"team_id\":\(quoted(teamID)),\"user_id\":\(quoted(userID))}",
                 broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func leaveTeam(teamID: String = teamID, userID: String = bobID, seq: Int64) -> String {
        envelope(event: "leave_team", data: "{\"team_id\":\(quoted(teamID)),\"user_id\":\(quoted(userID))}",
                 broadcast: Broadcast(teamID: teamID, omitUsers: [userID]), seq: seq)
    }

    public static func teamEvent(_ name: String = "update_team", team: String = teamJSON(), teamID: String = teamID,
                                 seq: Int64) -> String {
        envelope(event: name, data: "{\"team\":\(quoted(team))}", broadcast: Broadcast(teamID: teamID), seq: seq)
    }

    public static func userUpdated(user: String = userObject(), omitUserID: String = aliceID, seq: Int64) -> String {
        envelope(event: "user_updated", data: "{\"user\":\(user)}",
                 broadcast: Broadcast(omitUsers: [omitUserID], containsSanitizedData: true), seq: seq)
    }

    public static func userRoleUpdated(userID: String = aliceID, roles: String = "system_user", seq: Int64) -> String {
        envelope(event: "user_role_updated", data: "{\"roles\":\(quoted(roles)),\"user_id\":\(quoted(userID))}",
                 broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func preferences(_ name: String = "preferences_changed", preferences: [String] = [preferenceJSON()],
                                   userID: String = aliceID, seq: Int64) -> String {
        let list = "[" + preferences.joined(separator: ",") + "]"
        return envelope(event: name, data: "{\"preferences\":\(quoted(list))}", broadcast: Broadcast(userID: userID),
                        seq: seq)
    }

    public static func preferenceChanged(preference: String = preferenceJSON(), userID: String = aliceID,
                                         seq: Int64) -> String {
        envelope(event: "preference_changed", data: "{\"preference\":\(quoted(preference))}",
                 broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func threadUpdated(thread: String = threadJSON(), userID: String = aliceID, teamID: String = teamID,
                                     seq: Int64) -> String {
        envelope(event: "thread_updated",
                 data: "{\"previous_unread_mentions\":0,\"previous_unread_replies\":0,\"thread\":\(quoted(thread))}",
                 broadcast: Broadcast(userID: userID, teamID: teamID), seq: seq)
    }

    /// Single-thread variant.
    public static func threadReadChanged(threadID: String = postID, channelID: String = channelID,
                                         userID: String = aliceID, teamID: String = teamID, seq: Int64) -> String {
        envelope(event: "thread_read_changed",
                 data: "{\"channel_id\":\(quoted(channelID)),\"previous_unread_mentions\":0,"
                     + "\"previous_unread_replies\":1,\"thread_id\":\(quoted(threadID)),\"timestamp\":1790268736000,"
                     + "\"unread_mentions\":0,\"unread_replies\":0}",
                 broadcast: Broadcast(userID: userID, teamID: teamID), seq: seq)
    }

    /// Channel variant (observed after `set_unread`): `{timestamp}` with the channel in
    /// the broadcast.
    public static func threadReadChangedChannel(channelID: String = channelID, userID: String = aliceID,
                                                seq: Int64) -> String {
        envelope(event: "thread_read_changed", data: "{\"timestamp\":1790268735917}",
                 broadcast: Broadcast(userID: userID, channelID: channelID), seq: seq)
    }

    public static func threadFollowChanged(threadID: String = postID, following: Bool = true,
                                           userID: String = aliceID, teamID: String = teamID,
                                           seq: Int64) -> String {
        envelope(event: "thread_follow_changed",
                 data: "{\"reply_count\":1,\"state\":\(following),\"thread_id\":\(quoted(threadID))}",
                 broadcast: Broadcast(userID: userID, teamID: teamID), seq: seq)
    }

    public static func emojiAdded(seq: Int64) -> String {
        let emoji = "{\"id\":\"emojiemojiemojiemojiemoji\",\"creator_id\":\(quoted(bobID)),\"name\":\"party\"}"
        return envelope(event: "emoji_added", data: "{\"emoji\":\(quoted(emoji))}", broadcast: Broadcast(), seq: seq)
    }

    public static func configChanged(seq: Int64) -> String {
        envelope(event: "config_changed", data: "{\"config\":{\"Version\":\"11.11.1\",\"SiteName\":\"Mattermost\"}}",
                 broadcast: Broadcast(), seq: seq)
    }

    public static func licenseChanged(seq: Int64) -> String {
        envelope(event: "license_changed", data: "{\"license\":{}}", broadcast: Broadcast(), seq: seq)
    }

    /// An event MatterMac does not handle (observed: sent after preference saves).
    public static func sidebarCategoryUpdated(userID: String = aliceID, seq: Int64) -> String {
        envelope(event: "sidebar_category_updated", data: "{}", broadcast: Broadcast(userID: userID), seq: seq)
    }

    public static func unknown(_ name: String, seq: Int64) -> String {
        envelope(event: name, data: "{\"anything\":[1,2,3]}", broadcast: Broadcast(), seq: seq)
    }
}
