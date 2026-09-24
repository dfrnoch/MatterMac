import Foundation
import MatterMacModels
import MattermostAPI

/// Client → server actions MatterMac sends (`{"seq":N,"action":…,"data":{…}}`).
/// `authentication_challenge` is deliberately absent: it prevents resume (a new
/// connection id is always issued), so the upgrade authenticates via the header.
/// `presence` is not sent so typing and reaction events stay unscoped.
enum OutboundAction: Sendable, Hashable {
    case ping
    case typing(channel: ChannelID, parent: PostID?)
    case activity(isActive: Bool)

    /// The server's per-message read limit (`SocketMaxMessageSizeKb` = 8192 bytes);
    /// larger client messages close the socket with 1009.
    static let serverReadLimit = 8_192

    var name: String {
        switch self {
        case .ping: "ping"
        case .typing: "user_typing"
        case .activity: "user_update_active_status"
        }
    }

    /// Encodes the action with client sequence `seq` (always ≥ 1). Returns `nil` if the
    /// encoding would reach the server read limit.
    func encoded(seq: Int64) -> String? {
        precondition(seq >= 1, "client action seq must be >= 1")
        let data: Data?
        switch self {
        case .ping:
            data = try? WireJSON.encoder().encode(Envelope<Empty>(seq: seq, action: name, data: nil))
        case .typing(let channel, let parent):
            data = try? WireJSON.encoder().encode(Envelope(
                seq: seq, action: name, data: TypingData(channel_id: channel.rawValue, parent_id: parent?.rawValue ?? "")))
        case .activity(let isActive):
            // `manual:false` always: `true` would force a manual away status.
            data = try? WireJSON.encoder().encode(Envelope(
                seq: seq, action: name, data: ActivityData(user_is_active: isActive, manual: false)))
        }
        guard let data, data.count < Self.serverReadLimit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Envelope<D: Encodable>: Encodable {
        let seq: Int64
        let action: String
        let data: D?

        enum CodingKeys: String, CodingKey { case seq, action, data }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(seq, forKey: .seq)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(data, forKey: .data)
        }
    }

    private struct Empty: Encodable {}

    private struct TypingData: Encodable {
        let channel_id: String
        let parent_id: String
    }

    private struct ActivityData: Encodable {
        let user_is_active: Bool
        let manual: Bool
    }
}
