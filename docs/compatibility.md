# Compatibility

This is an implementation and evidence summary, not a feature-parity promise.
Server permissions, configuration, reverse proxies, and identity providers can
change which paths are available.

## Verified environments

The recorded local development environment uses Xcode 27.0, Apple Swift 6.4, and
macOS 27 on Apple silicon. Release builds contain arm64 and x86_64 slices. The
macOS 14 deployment target and Intel slice have not been execution-tested on that
OS or hardware. Local builds are ad-hoc signed, not Developer ID signed or notarized.

| Mattermost deployment | Evidence |
| --- | --- |
| 11.11.1 at origin root | Live REST/WebSocket peer and native conversation/attachment checks. |
| 11.11.1 at `/company/chat` | Same checks with URL-subpath preservation. |
| 10.11.24 at origin root | Same checks on the 10.11 release line. |

Live REST/WebSocket checks exercise bidirectional channel and DM messages, edits,
reactions, and deletions. Native SwiftUI/AppKit checks exercise login, draft
navigation, sending, edits, replies, DMs, selected-file/pasted-image upload,
download, and thumbnail display. Both peers are native clients; communication
with an official web or desktop client remains an unverified release gate.
Exact commands and dated outcomes are in [progress.md](progress.md).

## Authentication and endpoint coverage

All REST paths below are relative to the configured server's `/api/v4` prefix,
including any reverse-proxy subpath. This groups implemented routes; it does not
claim that every endpoint has a live test on every server configuration.

| Area | Implemented routes or behavior | Limits |
| --- | --- | --- |
| Discovery | `GET /system/ping`, `GET /config/client?format=old` | Missing capabilities stay unknown; no TLS bypass. |
| Password/PAT | `POST /users/login`, `GET /users/me`, `POST /users/logout` | Login methods and MFA depend on server policy; PATs are not remotely revoked by local sign-out. |
| Browser SSO | Server-advertised OpenID, SAML, Google, Microsoft or GitLab route; `POST /users/login/desktop_token`; identity verification | Uses system authentication presentation and a scoped callback. A local browser fixture passes; broad IdP interoperability is not verified. |
| Saved sign-ins | Keychain bearer credentials, `/users/me` revalidation | Expired or mismatched identities are removed; temporary connection failures retain the saved entry for retry. |
| Teams/channels | Own teams and memberships, channel metadata/membership/stats, DM creation, join/leave, channel search and view state; `GET /users?in_channel=` member pages; favorites through `favorite_channel` preferences (`PUT /users/{id}/preferences`, `POST …/preferences/delete`); mute and per-channel notification preferences through `PUT /channels/{id}/members/{user}/notify_props` (only the changed `desktop`, `mark_unread` and `ignore_channel_mentions` keys) | Available actions remain subject to server permissions; the details panel retains at most 600 members; broader permission UI is incomplete. Sidebar categories other than Favorites are not shown. |
| Posts/threads | Channel pages, unread anchors, post/thread retrieval, create/patch/delete, batched retrieval | Basic threads implemented; not full collapsed-thread workflow parity. |
| Reactions/search | Add/remove reactions; team post search; system (Unicode) emoji rendering, `:` completion and a native reaction picker from a static table of Mattermost v11.11.1 `SystemEmojis` names | Custom emoji are not rendered, completed or offered in the picker (they stay `:name:` text); reaction names over 64 characters are not offered; the picker's frequently used row is a fixed list; advanced search UI remains incomplete. |
| Users | Batched users/statuses, `POST /users/usernames`, autocomplete, profile images; profile cards (position, local time zone, custom status, email when the server exposes it); `PUT /users/{id}/status` and `PUT`/`DELETE /users/{id}/status/custom` for the signed-in user; names follow `TeammateNameDisplay` / `LockTeammateNameDisplay` and the `name_format` preference | Bounded results; not a full administrative directory. Custom status emoji are system emoji names only. |
| Notifications | Dock badge with unread mention count. Alerts follow the account's `notify_props` (`desktop`, `desktop_sound`, `mention_keys`, `first_name`, `channel`) from `/users/me` and `user_updated`, and each channel member's `desktop`, `mark_unread` (mute) and `ignore_channel_mentions`: the server's `mentions` list plus a client-side whole-word, case-insensitive keyword match. Opt-in Notification Center alerts (sender and conversation; up to 100 characters of text only with the separate, default-off preview opt-in), an in-app system sound and one Dock bounce for mentions/DMs while inactive. Suppressed during Do Not Disturb and for the conversation on screen; clicking opens it. Account level, sound, keywords, first-name and channel-wide triggers are editable in Settings (`PUT /users/{id}/patch` with the complete `notify_props` map) | Local switches (Notification Center, preview, sound choice, Dock bounce) are in memory only; nothing after quitting. With collapsed threads, channel replies notify only for mentions (`desktop_threads` and followed threads are not tracked). In-app sounds follow Mattermost Do Not Disturb, not macOS Focus. Notify-prop maps over 48 keys or 4 KB per value are not editable. Push and email settings are not shown. |
| Settings | Settings window (⌘,): local send key, text size and light/dark override (in memory); server `display_settings` `use_military_time`, `name_format` (disabled when `LockTeammateNameDisplay`) and `collapsed_reply_threads` (only for `default_on`/`default_off`) through `PUT /users/{id}/preferences`; signed-in servers with Sign Out | Server settings apply to the active account only. No compact message density and no Mattermost theme. An unset clock preference follows the Mac's format (the official client defaults to 12-hour). |
| Slash commands | `POST /commands/execute` in the current channel/thread; the synchronous reply is shown above the conversation; unknown commands keep the draft; text starting with a space is sent as a message | Interactive dialogs, ephemeral bot posts and `goto_location` navigation are not supported; a lost response is reported as an unknown outcome and the draft is kept. |
| Files/images | `/files`, file/info/thumbnail/preview retrieval, image requests; timeline thumbnails use `GET /files/{id}/preview` when `has_preview_image` is set (else `/thumbnail`), downsampled to at most 720 px; clicking an image (or Space on its row) opens an in-memory viewer of the same rendition downsampled to the screen (≤ 2048 px) with an explicit Save… | Explicit uploads/downloads and bounded in-memory previews; the viewer never fetches the original file and uses no Quick Look or temporary files, so it is limited to the server's preview resolution. Animated images show their first frame. Uploaded-but-unposted files can remain on the server. |
| Realtime | `/websocket`, authentication, event reconciliation and reconnect | Unknown send outcomes remain visible; no exactly-once delivery guarantee. |

SSO success depends on the server's advertised route and desktop-token support,
not just the provider brand. Custom provider labels are preserved. A deployment
check does not establish support for every configuration of that identity provider.

## Unsupported and unfinished

Calls, screen sharing, arbitrary web plugins, Boards, Playbooks dashboards,
enterprise administration, and custom theme CSS are outside native v1 scope.
There are no durable offline drafts or notifications after the app quits.

Custom emoji and broader permission controls still need UI integration. VoiceOver and real IME coverage, minimum-OS execution, full
privacy/filesystem audits, and performance acceptance measurements are incomplete.
Existing SwiftUI sidebar reentrancy and AppIntents metadata-extraction warnings
are recorded in the progress log; neither is claimed resolved here.
