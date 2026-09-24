# 0023 — Server sidebar categories, team rail and channel directory

Date: 2026-09-25. Status: implemented.

**Categories come from the server.** The sidebar now shows the categories returned by
`GET /users/{id}/teams/{team}/channels/categories` in the server's `order`, with the
server's channel order. Sorting is applied as the official client does:
`manual` (and `""` outside Direct Messages) keeps the server order, `alpha` sorts by
display name, `recent` (and `""` for Direct Messages) by last post. Channels the
server has not placed yet (joined since the last read) go where the server puts
orphans: Channels or Direct Messages. On every `sidebar_category_*` event Core re-reads
the team's categories (coalesced by 150 ms) rather than patching them from partial
payloads. The data-less variant emitted when favorites preferences are saved has no
team, so the shown team is re-read and other teams' cached categories are dropped.
If the endpoint fails, the previous synthesized Favorites/Channels/Direct Messages
sections are used. Categories are retained for at most 8 teams, and each team's
channel ids are capped at the session channel budget.

**Collapsing is an explicit server change.** `PUT …/categories/{id}` replaces the whole
category, including its channel list (the server deletes and re-inserts it). To avoid
writing back a stale list, Core re-reads the category immediately before the `PUT`
and changes only `collapsed`. Unknown `type`/`sorting` values and dropped channel
ids are preserved or refused: a category with an unreadable or truncated channel list
is never written. The change is shown optimistically and reverted, with an error, if
the server refuses. A collapsed category still shows unread channels and the
selected one. "Group Unread Channels Separately" is a local, in-memory choice (never
the `sidebar_settings/show_unread_section` preference, so it does not change the
user's other clients); the open channel stays in the group until the user leaves it.

**Team rail.** The team picker became a leading rail: servers (circles) above the
active server's teams (rounded squares) when more than one exists. Team icons are
fetched with `GET /teams/{id}/image?_={last_team_icon_update}` through the shared
bounded image pipeline; teams without an icon show initials. Unread and mention
indicators come from the loaded channel state, or from `GET /users/me/teams/unread`
for teams whose channels are not loaded (refreshed after a team load and, at most every
2 s, after posts in such teams). ⌘1…⌘9 select teams. Add Server… is in the sidebar
"+" menu, and also in the rail when several servers are signed in. The rail is hidden
for a single server with a single team.

**Keyboard.** ⌥↑/⌥↓ select the previous/next visible channel and ⌥⇧↑/⌥⇧↓ the
previous/next unread one, wrapping, as in the official desktop app. These menu
shortcuts take precedence over the composer's ⌥↑/⌥↓ paragraph moves. That is an
explicit tradeoff against SPEC §4 ("do not override standard editing shortcuts
casually"), made for parity with the application being replaced. New Direct Message
is ⇧⌘K (the official shortcut) and Browse Channels is ⇧⌘L; neither was in use.

**Directory sheets.** Browse Channels lists public channels (and archived ones when
the server allows it: v10 `ExperimentalViewArchivedChannels`; always on v11) with
purpose and member counts (`POST /channels/stats/member_count`, one request per page).
It joins public channels and opens joined ones. Channel previews without joining are
not offered. Create Channel validates the URL name like the server's
`IsValidChannelIdentifier`, with the official client's two-character minimum, and maps
server refusals (name taken, archived name, channel limit, permission) to specific
messages. New Message opens a DM for one person and `POST /channels/group` for 2–7.
Add Members uses `POST /channels/{id}/members` with `user_ids` (at most 50 at a time)
and reports missing permission. People search is `POST /users/search`, team-scoped and
excluding existing members. Every result list is bounded and lives only while its
sheet is open.

**Rejected.** Patching categories from event payloads (not all variants carry data,
and a missed event would leave the sidebar wrong until restart); persisting the
Unreads choice as a server preference (it would change the user's other clients);
counting unread badges for unloaded teams by loading every team's channels (unbounded
work on large accounts).
