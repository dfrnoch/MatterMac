import Foundation
import MatterMacModels

/// `ChannelUnreadAt`, the `POST /users/{id}/posts/{post}/set_unread` response:
/// `{team_id, user_id, channel_id, msg_count, msg_count_root, mention_count,
/// mention_count_root, urgent_mention_count, last_viewed_at}`.
public struct ChannelUnreadWire: Decodable, Sendable {
    public let state: ChannelUnreadState

    enum Keys: String, CodingKey {
        case channel_id, msg_count, msg_count_root, mention_count, mention_count_root, urgent_mention_count, last_viewed_at
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func count(_ key: Keys) -> Int64 { max(0, c.lenientInt64(key) ?? 0) }
        state = ChannelUnreadState(
            channelID: try c.requiredID(ChannelID.self, .channel_id),
            lastViewedAt: c.timestamp(.last_viewed_at),
            messageCount: count(.msg_count), messageCountRoot: count(.msg_count_root),
            mentionCount: count(.mention_count), mentionCountRoot: count(.mention_count_root),
            urgentMentionCount: count(.urgent_mention_count))
    }
}
