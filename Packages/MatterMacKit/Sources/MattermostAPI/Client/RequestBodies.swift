import Foundation
import MatterMacModels

// JSON request bodies, spelled exactly as the server expects (docs/research/*.md).
// Encoded with `WireJSON.encoder()`; optional fields are omitted when nil.

/// `POST /users/login`. The server decodes this into `map[string]string`: every
/// value must be a JSON string (a non-string silently becomes ""). `device_id` is
/// deliberately absent (it would force mobile-session semantics).
struct LoginBody: Encodable {
    let login_id: String
    let password: String
    let token: String?
}

/// `POST /posts`. `root_id` is omitted for root posts; `id`, `create_at`, `user_id`
/// and `is_pinned` are never sent.
struct CreatePostBody: Encodable {
    let channel_id: String
    let message: String
    let root_id: String?
    let file_ids: [String]
    let pending_post_id: String
}

/// `PUT /posts/{id}/patch`: only `message` is patched.
struct PatchPostBody: Encodable {
    let message: String
}

/// `POST /reactions`.
struct ReactionBody: Encodable {
    let user_id: String
    let post_id: String
    let emoji_name: String
}

/// `POST /channels/members/me/view`. Empty strings mean "none".
struct ViewChannelBody: Encodable {
    let channel_id: String
    let prev_channel_id: String
    let collapsed_threads_supported: Bool
}

/// `POST /channels/{id}/members` (self-join).
struct AddChannelMemberBody: Encodable {
    let user_id: String
}

/// `POST /teams/{team}/channels/search`.
struct ChannelSearchBody: Encodable {
    let term: String
}

/// `POST /teams/{team}/posts/search`. `include_deleted_channels` is always false.
struct PostSearchBody: Encodable {
    let terms: String
    let is_or_search: Bool
    let time_zone_offset: Int
    let page: Int
    let per_page: Int
    let include_deleted_channels: Bool
}

enum RequestBodyEncoding {
    /// Encoding these plain structs cannot fail; a failure would be a programming
    /// error, reported as `.malformedResponse` rather than crashing.
    static func encode<Body: Encodable>(_ body: Body) throws(APIError) -> Data {
        do {
            return try WireJSON.encoder().encode(body)
        } catch {
            throw .malformedResponse
        }
    }
}

struct StatusBody: Encodable {
    let user_id: String
    let status: String
}

struct PreferenceBody: Encodable {
    let user_id: String
    let category: String
    let name: String
    let value: String
}

struct ChannelNotifyPropsBody: Encodable {
    let channel_id: String
    let user_id: String
    let mark_unread: String
}

/// `POST /commands/execute`.
struct ExecuteCommandBody: Encodable {
    let channel_id: String
    let team_id: String
    let root_id: String
    let command: String
}

/// `PUT /users/{id}/status/custom`. `expires_at` is RFC 3339; omitted for no expiry.
struct CustomStatusBody: Encodable {
    let emoji: String
    let text: String
    let duration: String
    let expires_at: String?
}
