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
reactions, and deletions, plus pin/unpin, save/unsave, Mark as Unread and
server-generated link previews (`LiveInteractionTests`). Native SwiftUI/AppKit checks exercise login, draft
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
| Teams/channels | Own teams and memberships, channel metadata/membership/stats, DM creation, join/leave, channel search and view state; `GET /users?in_channel=` member pages; favorites through `favorite_channel` preferences (`PUT /users/{id}/preferences`, `POST …/preferences/delete`); mute and per-channel notification preferences through `PUT /channels/{id}/members/{user}/notify_props` (only the changed `desktop`, `mark_unread` and `ignore_channel_mentions` keys) | Available actions remain subject to server permissions; the details panel retains at most 600 members; broader permission UI is incomplete. |
| Sidebar | `GET /users/{id}/teams/{team}/channels/categories` (custom, Favorites, Channels, Direct Messages; manual/alphabetical/recent sorting; muted and collapsed state) re-read on every `sidebar_category_*` event; collapsing re-reads the category (`GET …/categories/{id}`) and writes it back (`PUT …/categories/{id}`); team rail with `GET /teams/{id}/image` icons (when `last_team_icon_update` > 0) and `GET /users/me/teams/unread` counts for teams whose channels are not loaded; ⌘1…⌘9 teams, ⌥↑/⌥↓ channels, ⌥⇧↑/⌥⇧↓ unread channels; local "Group Unread Channels Separately"; drafts pencil | Categories cannot be created, renamed, reordered or re-sorted, and channels cannot be moved between them in MatterMac (changes from other clients are shown). If the categories endpoint fails, sections are synthesized (Favorites, Channels, Direct Messages). Categories are kept for at most 8 teams. At most 40 direct messages are listed (plus unread and active); "More…" opens New Direct Message. v11 managed categories are shown like custom ones. A collapse written concurrently with another client's channel move can overwrite that move (the category is re-read immediately before writing). ⌥↑/⌥↓ take precedence over the composer's paragraph moves. |
| Browse/create | `GET /teams/{id}/channels`, `GET /teams/{id}/channels/deleted` (archived, when v10 `ExperimentalViewArchivedChannels` is on; always offered on v11), `POST /teams/{id}/channels/search`, `POST /channels/stats/member_count`, `POST /channels` (public/private, URL-name rules as the server's `IsValidChannelIdentifier` with the official client's two-character minimum), `POST /channels/group` (2–7 people plus you), `POST /channels/{id}/members` (`user_id`/`user_ids`, at most 50 at a time), `POST /users/search` (team-scoped, optionally `not_in_channel_id`) | Joining previews are not available: public channels must be joined to be read, archived channels you never joined cannot be opened. Search returns at most 100 channels (server limit); the sheet keeps at most 500. Permission refusals (create, add members) are reported, not hidden in advance. Channel archiving, conversion and category management are not implemented. |
| Posts/threads | Channel pages, unread anchors, post/thread retrieval, create/patch/delete, batched retrieval | Basic threads implemented; not full collapsed-thread workflow parity. |
| Message actions | Hover action bar (three fixed quick reactions, Add Reaction, Reply, More) on the hovered or selected message, the same items in the context menu and as VoiceOver custom actions, Control-Return for the selected message's menu; pin/unpin via `POST /posts/{id}/pin` / `unpin`; save/unsave as `flagged_post` preferences (`PUT /users/{id}/preferences`, `POST …/preferences/delete`); Mark as Unread via `POST /users/{id}/posts/{post}/set_unread` (`collapsed_threads_supported: true`) | Mark as Unread is offered in channel timelines only, not in the thread pane (no thread-level `set_unread`). After it, the channel is not marked read again until the user scrolls it, sends in it or opens another channel (decision 0022). At most 5,000 saved-post ids are tracked per session; there is no Saved or Pinned messages list yet. Pinning follows the server's edit time limit. |
| Links and previews | Permalinks (`/<team>/pl/<post>`), channel links (`/<team>/channels/<name>`) and DM links (`/<team>/messages/@user`) to the signed-in server open in the app, focused on the post; OpenGraph and direct-image previews from `metadata.embeds` (title, description, site name) under the message; thumbnails only through the server image proxy (`GET /image?url=`, redirects refused) when `HasImageProxy` is on | Links into channels the user is not a member of are reported, not joined. Links to other servers open in the browser. Without an image proxy previews are text-only; MatterMac never contacts the previewed site. `display_settings/link_previews = false` hides website previews. Permalink previews (embedded quoted posts) are not rendered. |
| Reactions/search | Add/remove reactions; team post search; system (Unicode) emoji rendering, `:` completion and a native reaction picker from a static table of Mattermost v11.11.1 `SystemEmojis` names; reaction chips name up to ten reactors in their tooltip and accessibility help ("You, bob and 3 others reacted with :+1:") | Custom emoji use inline images and reaction chips, colon completion, and a paged Custom picker section when enabled; animated emoji show their first frame; browsing retains 600 custom entries (search reaches others); reaction names over 64 characters are not offered; the picker's frequently used row and the hover bar's quick reactions are fixed lists; reactors whose profiles are not loaded yet are counted, not named; advanced search UI remains incomplete. |
| Users | Batched users/statuses, `POST /users/usernames`, autocomplete, profile images; profile cards (position, local time zone, custom status, email when the server exposes it); `PUT /users/{id}/status` and `PUT`/`DELETE /users/{id}/status/custom` for the signed-in user; names follow `TeammateNameDisplay` / `LockTeammateNameDisplay` and the `name_format` preference | Bounded results; not a full administrative directory. Custom status emoji are system emoji names only. |
| Notifications | Dock badge with unread mention count. Alerts follow the account's `notify_props` (`desktop`, `desktop_sound`, `mention_keys`, `first_name`, `channel`) from `/users/me` and `user_updated`, and each channel member's `desktop`, `mark_unread` (mute) and `ignore_channel_mentions`: the server's `mentions` list plus a client-side whole-word, case-insensitive keyword match. Opt-in Notification Center alerts (sender and conversation; up to 100 characters of text only with the separate, default-off preview opt-in), an in-app system sound and one Dock bounce for mentions/DMs while inactive. Suppressed during Do Not Disturb and for the conversation on screen; clicking opens it. Account level, sound, keywords, first-name and channel-wide triggers are editable in Settings (`PUT /users/{id}/patch` with the complete `notify_props` map) | Local switches (Notification Center, preview, sound choice, Dock bounce) are in memory only; nothing after quitting. With collapsed threads, channel replies notify only for mentions (`desktop_threads` and followed threads are not tracked). In-app sounds follow Mattermost Do Not Disturb, not macOS Focus. Notify-prop maps over 48 keys or 4 KB per value are not editable. Push and email settings are not shown. |
| Settings | Settings window (⌘,): local send key, text size and light/dark override (in memory); server `display_settings` `use_military_time`, `name_format` (disabled when `LockTeammateNameDisplay`) and `collapsed_reply_threads` (only for `default_on`/`default_off`) through `PUT /users/{id}/preferences`; signed-in servers with Sign Out | Server settings apply to the active account only. No compact message density and no Mattermost theme. An unset clock preference follows the Mac's format (the official client defaults to 12-hour). |
| Slash commands | `POST /commands/execute` in the current channel/thread; server command and argument completion at the start of the composer, with legacy command-name fallback; the synchronous reply is shown above the conversation; unknown commands keep the draft; text starting with a space is sent as a message | Interactive dialogs, ephemeral bot posts and `goto_location` navigation are not supported; a lost response is reported as an unknown outcome and the draft is kept. |
| Files/images | `/files`, file/info/thumbnail/preview retrieval, image requests; timeline thumbnails use `GET /files/{id}/preview` when `has_preview_image` is set (else `/thumbnail`), downsampled to at most 720 px; clicking an image (or Space on its row) opens an in-memory viewer of the same rendition downsampled to the screen (≤ 2048 px) with an explicit Save… | Explicit uploads/downloads and bounded in-memory previews; the viewer never fetches the original file and uses no Quick Look or temporary files, so it is limited to the server's preview resolution. Animated images show their first frame. Uploaded-but-unposted files can remain on the server. |
| Realtime | `/websocket`, authentication, event reconciliation and reconnect | Unknown send outcomes remain visible; no exactly-once delivery guarantee. |

SSO success depends on the server's advertised route and desktop-token support,
not just the provider brand. Custom provider labels are preserved. A deployment
check does not establish support for every configuration of that identity provider.

## Unsupported and unfinished

Calls, screen sharing, arbitrary web plugins, Boards, Playbooks dashboards,
enterprise administration, and custom theme CSS are outside native v1 scope.
There are no durable offline drafts or notifications after the app quits.

Broader permission controls still need UI integration. VoiceOver and real IME coverage, minimum-OS execution, full
privacy/filesystem audits, and performance acceptance measurements are incomplete.
Existing SwiftUI sidebar reentrancy and AppIntents metadata-extraction warnings
are recorded in the progress log; neither is claimed resolved here.

## Native message formatting

Headings, emphasis, code (wrapped in rounded blocks), quotes with leading bars,
nested/numbered/task lists, rules, mention highlights and aligned pipe-table grids
are rendered with TextKit 1. Tables retain inline formatting/alignment, show at most
50 body rows and 10 columns, and abbreviate cells after 300 UTF-16 units; omitted
rows/columns are labeled and Copy Text retains the parsed table. Overall message
render/collapse limits still apply. This remains a safe Markdown subset, not full
GFM parity. Hashtags are colored but do not initiate search.

Bot attachment cards include pretext, accent bar, author, safe title link, text,
paired short fields, footer and an unsupported-interactive-action note. Attachment
image URLs are explicit external links; image-proxy thumbnails are not implemented
for these cards. Third-party URLs are never fetched automatically by this renderer.
