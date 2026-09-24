# MatterMac research: teams, channels, read state, users, search, files, preferences and emoji on Mattermost v11.11.1 and ESR v10.11.24

Everything below comes from raw source fetched at the tags `v11.11.1` and `v10.11.24`. I diffed each handler between the two tags using the scratch scripts in `/tmp/mm-research-channels/` (fx.sh / fd.sh). Where a claim says "SAME", the function bodies differ only in renames (`c` became `rctx`) or audit-event constants.

Line numbers cite v11 first, then v10 in brackets where they differ. Path shorthand:
- `api4/` = `server/channels/api4/`
- `app/` = `server/channels/app/`
- `model/` = `server/public/model/`
- `sqlstore/` = `server/channels/store/sqlstore/`
- `redux/` = `webapp/channels/src/packages/mattermost-redux/src/`

---

## 0. Rules that apply everywhere

- **Timestamps** are Unix **milliseconds** (int64), with three exceptions:
  - `Status.dnd_end_time` is in **seconds** (comment in `model/status.go` ~L32).
  - `CustomStatus.expires_at` is an RFC3339 string, because it is a Go `time.Time`.
  - The search field `time_zone_offset` is in **seconds** east of UTC.
- **IDs** are 26-char `[a-z0-9]`. `{user_id}` accepts `me`, which the webapp uses everywhere; the YAML says "This can also be 'me'".
- **Paging** (`server/channels/web/params.go` ~L216-241, SAME in v10):
  - `page` defaults to 0. A negative value is reset to 0, except on `GET /users/{id}/channel_members`, where `page=-1` switches to streaming (§2).
  - `per_page` defaults to **60**, max **200** (clamped silently). 0 is allowed.
- **Body size limit** (`web/handlers.go` ~L224-234):
  - JSON bodies are capped at `ServiceSettings.MaximumPayloadSizeBytes` + 512. The default is **300000** bytes.
  - File endpoints are capped at `FileSettings.MaxFileSize` + 512 **for the whole request**.
  - Over the limit you get 413 `api.context.request_body_too_large.app_error` (v10 `web/handlers.go` ~L387).
- **Error body** (`model/utils.go` ~L232): `{"id","message","detailed_error","request_id","status_code"}`. Common ids (`web/context.go`):
  - 403 `api.context.permissions.app_error`
  - 400 `api.context.invalid_body_param.app_error` / `api.context.invalid_url_param.app_error`
  - 401 `api.context.session_expired.app_error`
  - 503 `api.context.server_busy.app_error` (routes registered with `DisableWhenBusy`: all searches)
- **ETag** (`web/context.go` ~L230 `HandleEtag`): the server compares the request's `If-None-Match` to its etag and returns **304** plus an `ETag` header on a match. Endpoints that do this are flagged below.
- `ReturnStatusOK` responses are `{"status":"OK"}`.
- Archived channels have `delete_at > 0`. Deactivated users have `delete_at > 0`.

---

## 1. Teams (identical in v10 and v11 apart from the model fields noted)

| Endpoint | Details |
|---|---|
| `GET /api/v4/users/me/teams` | `api4/team.go getTeamsForUser` L731 [L544]. Returns `[Team]`. Only rows with `TeamMembers.DeleteAt=0 AND Teams.DeleteAt=0` (`sqlstore/team_store.go GetTeamsByUserId` ~L705). The `SanitizeTeam` pass (`app/team.go` ~L2303) blanks `email` unless you have `manage_team`, and blanks `invite_id` unless you have `invite_user`. Another user's id requires `sysconsole_read_user_management_users`. |
| `GET /api/v4/users/me/teams/members` | `getTeamMembersForUser` L880 [L693]. Returns `[TeamMember]`. **Includes deleted memberships** (`GetTeamMembersForUser(..., "", true)` → store `GetTeamsForUser` with `includeDeleted=true`, `sqlstore/team_store.go` ~L1181). **Filter `delete_at == 0` on the client.** Other users' rows get their role fields cleared and `delete_at=-1` (`SanitizeRoleData`). |
| `GET /api/v4/users/me/teams/unread?exclude_team=<id>&include_collapsed_threads=true` | `getTeamsUnreadForUser` L761 [L574]. Returns `[TeamUnread]`. Built from `app/team.go GetTeamsUnreadForUser` ~L1980 + `sqlstore/team_store.go GetChannelUnreadsForAllTeams` ~L1231. See details below. |
| `GET /api/v4/users/me/teams/{team_id}/unread` | `getTeamUnread` L1318. Returns a single `TeamUnread`. Requires `view_team`. |
| Team icon | `GET /api/v4/teams/{team_id}/image` (TrustRequester). Use `last_team_icon_update` as the cache key. |

**How `/users/me/teams/unread` counts** (`GetChannelUnreadsForAllTeams` and `GetTeamsUnreadForUser`):
- Per channel: `msg_count = total_msg_count - member.msg_count`. Muted channels (`mark_unread == "mention"`) add their mentions but not their message counts.
- `thread_*` fields are filled only when `include_collapsed_threads=true` **and** `CollapsedThreads != "disabled"`.
- The query uses `TeamId != exclude_team`. With no `exclude_team`, that becomes `TeamId != ''`, so DM/GM channels are excluded. If you do pass `exclude_team`, DMs/GMs come back aggregated under an entry with `team_id: ""`.

**Team model** (`model/team.go` L26):
- `id`, `create_at`, `update_at`, `delete_at` (int64 ms)
- `display_name`, `name` (URL slug), `description`, `email`
- `type`: `"O"` open or `"I"` invite
- `company_name`, `allowed_domains`, `invite_id`, `allow_open_invite` (bool)
- `last_team_icon_update` (int64, omitempty)
- `scheme_id` (string?), `group_constrained` (bool?), `policy_id` (string?), `cloud_limits_archived` (bool)
- **v11 only:** `policy_enforced` (bool), `policy_actions` (map[string]bool, omitempty), `policy_is_active` (bool), `recommended` (bool, omitempty)

**TeamMember** (`model/team_member.go` L20): `team_id`, `user_id`, `roles` (space-separated), `delete_at`, `scheme_guest`, `scheme_user`, `scheme_admin`, `explicit_roles`.

**TeamUnread** (L47): `team_id`, `msg_count`, `mention_count`, `mention_count_root`, `msg_count_root`, `thread_count`, `thread_mention_count`, `thread_urgent_mention_count`. All int64.

---

## 2. Channels for navigation

**Per-team channels:** `GET /api/v4/users/me/teams/{team_id}/channels?include_deleted=<bool>&last_delete_at=<ms>`
- `api4/channel.go getChannelsForTeamForUser` L1384 [L1042]. SAME.
- Requires `view_team`.
- Returns `[Channel]` for the user's memberships where `TeamId = team_id OR TeamId = ''`, so **DMs/GMs are included**. Ordered by `display_name` (`sqlstore/channel_store.go GetChannels` ~L1208).
- `include_deleted=false`: archived channels are excluded.
- `include_deleted=true` with `last_delete_at=0`: all channels.
- `include_deleted=true` with `last_delete_at>0`: active channels plus those with `delete_at >= last_delete_at`.
- A negative `last_delete_at` gives 400.
- ETag supported.
- **Zero channels returns 404 `app.channel.get_channels.not_found.app_error`.** Treat that as an empty list.

**All teams:** `GET /api/v4/users/me/channels?include_deleted&last_delete_at`
- Exists in both tags (min server 6.1); `getChannelsForUser` L1435 [L1093], SAME.
- **No `page` or `per_page`.** The server streams one JSON array, fetching 100 rows at a time internally ordered by id. The output is still a valid JSON array; elements are separated by `\n,`.
- Also excludes channels belonging to deleted teams unless `include_deleted` is set (`GetChannelsByUser` ~L1264).
- **Edge case:** if the user has zero channels, `[` has already been written with status 200 and the error JSON is appended after it, so the body will not parse. Treat a parse failure as an empty list.
- Used by the webapp as `getAllTeamsChannels` (`client4.ts` ~L1918).

**Channel members for one team:** `GET /api/v4/users/me/teams/{team_id}/channels/members`
- `getChannelMembersForTeamForUser` L1978 [L1642]. SAME.
- Returns `[ChannelMember]` for that team plus DMs/GMs (`Teams.Id = team_id OR '' OR NULL`).
- Includes archived channels (no DeleteAt filter).
- Requires `view_team`. Another user's id requires `manage_system`.

**Channel members for all teams:** `GET /api/v4/users/me/channel_members?page=&per_page=`
- Exists in both tags (min 6.2); `api4/user.go getChannelMembersForUser` L3737 [L3253]. SAME.
- `page >= 0`: returns a JSON array of `ChannelMemberWithTeamData` (ChannelMember plus `team_display_name`, `team_name`, `team_update_at`), ordered by channel_id, offset paging.
- `page=-1`: **NDJSON stream** (`Content-Type: application/x-ndjson`). One JSON object per line covering all memberships; `per_page` is ignored.
- This is what the webapp does: `redux/actions/channels.ts fetchAllMyChannelMembers` ~L511 calls `getAllChannelsMembers(currentUserId, -1)`, and `client4.ts doFetchWithResponse` ~L4882 splits on `\n`.
- Zero rows in page mode gives 404 `app.channel.get_member.missing.app_error`.

**v11 caveat, non-message channel types** (`model/channel.go` L27-34): the enum adds `"S"` (space), `"BO"` / `"BP"` (boards).
- v11 filters channel lists (`GetChannels`, `GetChannelsByUser`, `GetChannelUnread`) to O/P/D/G only (`messageChannelTypes`, `sqlstore/channel_store.go` L39).
- Member lists (`GetMembersForUser`, the cursor/pagination variants) exclude only `"S"`. **Board-channel memberships can therefore appear with no matching channel.** Decode `type` as an open enum and ignore members whose channel you don't have.
- v10 has only O/P/D/G.

**Channel model** (`model/channel.go` L85 [v10 L80]):
- `id`, `create_at`, `update_at`, `delete_at`
- `team_id`: **`""` for D and G**
- `type`: `"O"` / `"P"` / `"D"` / `"G"` (v11 also `S` / `BO` / `BP`)
- `display_name`: **`""` for DMs**, per `sqlstore CreateDirectChannel` ~L688
- `name`, `header`, `purpose`
- `last_post_at`, `total_msg_count`, `extra_update_at`
- `creator_id`, `scheme_id` (string?), `props` (map; includes `channel_mentions` via `FillInChannelsProps`)
- `group_constrained` (bool?), `shared` (bool?)
- `total_msg_count_root`, `policy_id` (string?), `last_root_post_at`
- `banner_info` `{enabled?, text?, background_color?}`
- `policy_enforced` (bool), `default_category_name` (string)
- **v11 only:** `autotranslation` (bool), `policy_actions` (map, omitempty), `policy_is_active` (bool), `managed_category_name` (string), `discoverable` (bool)

**ChannelMember** (`model/channel_member.go` L54):
- `channel_id`, `user_id`, `roles` (e.g. `"channel_user channel_admin"`)
- `last_viewed_at`, `msg_count`, `mention_count`, `mention_count_root`, `urgent_mention_count`, `msg_count_root`
- `notify_props` (map[string]string: `desktop`, `email`, `push`, `mark_unread` `"all"`/`"mention"`, `ignore_channel_mentions`, `channel_auto_follow_threads`, plus freeform keys such as `desktop_threads`)
- `last_update_at`, `scheme_guest`, `scheme_user`, `scheme_admin`, `explicit_roles`
- **v11 only:** `autotranslation_disabled` (bool)
- `SanitizeForCurrentUser` (~L95): other users' `last_viewed_at` and `last_update_at` are sent as **-1**.
- **Muted** means `notify_props.mark_unread == "mention"`.

**How the webapp computes unread** (`redux/utils/channel_utils.ts calculateUnreadCount` ~L371, identical in v10):
- CRT on: `messages = channel.total_msg_count_root - member.msg_count_root`, `mentions = member.mention_count_root`.
- CRT off: `messages = channel.total_msg_count - member.msg_count`, `mentions = member.mention_count`.
- `hasUrgent = member.urgent_mention_count > 0`.
- `showUnread = mentions > 0 || (!muted && messages > 0)`.

**Is CRT on?** Server logic is `app/channel.go IsCRTEnabledForUser` ~L3183. Config key `CollapsedThreads` (client config key of the same name):
- `"disabled"` → off.
- `"always_on"` → on.
- `"default_on"` / `"default_off"` → the default, overridden by preference `display_settings`/`collapsed_reply_threads` = `"on"` / `"off"`.

---

## 3. Read and unread state

**Mark a channel viewed:** `POST /api/v4/channels/members/{user_id|me}/view`
- Exists unchanged in both (`viewChannel` L2011 [L1675]). v11 only adds a 400 `api.channel.board_channel.app_error` if an id belongs to a board channel.
- Body (`model/channel_view.go`): `{"channel_id": "<id or ''>", "prev_channel_id": "<id or ''>", "collapsed_threads_supported": true}`. The webapp sends `{channel_id, collapsed_threads_supported: true}`.
- Invalid non-empty ids give 400 (`channel_view.channel_id` / `channel_view.prev_channel_id`).
- Response 200: `{"status":"OK","last_viewed_at_times":{"<channel_id>": <ms>}}`.

What the server actually does (`app/channel.go ViewChannel` ~L3737 → `MarkChannelsAsViewed` ~L3678):
1. `SetActiveChannel(channel_id)` always runs; an empty id clears the active channel.
2. Both ids are passed to `GetChannelsWithUnreadsAndWithMentions` (`sqlstore/channel_store.go` ~L2232).
3. **Only channels that currently have unreads or mentions are updated.**
4. The update (`UpdateLastViewedAt`) sets:
   - `last_viewed_at = greatest(last_viewed_at, channel.last_post_at)` — last post time, **not the current time**
   - `msg_count = greatest(msg_count, total_msg_count)`, and the same for `_root`
   - all mention counts to 0
5. The returned map value per requested channel is `max(last_post_at, last_viewed_at_before_update)`.
6. If `ServiceSettings.ThreadAutoFollow && (!collapsed_threads_supported || !CRT)`, all threads in those channels are also marked read. **Send `true` only if MatterMac has a thread UI.**
7. Publishes WebSocket event `multiple_channels_viewed` `{channel_times}` if `EnableChannelViewedMessages` is on, and clears push notifications.

**Batch mark-read:** `POST /api/v4/channels/members/{user_id}/mark_read`
- Body `["channel_id", ...]` (non-empty, else 400). Same response shape.
- `collapsedThreadsSupported` is hard-coded true.
- `readMultipleChannels` L2066. SAME.

**v11 only**, behind feature flag `EnableShiftEscapeToMarkAllRead`; otherwise 501 `api.mark_all_as_read.disabled.app_error`:
- `PUT /api/v4/users/{user_id}/teams/{team_id}/read`
- `PUT /api/v4/channels/members/{user_id}/direct/read`
- Both return the same response shape (`readAllInTeam` L2099, `readAllMessages` L701).

**Mark unread from a post:** `POST /api/v4/users/{user_id}/posts/{post_id}/set_unread`
- Body `{"collapsed_threads_supported": bool}`; missing means false. Same in v10.
- `api4/post.go setPostUnread` L1300 [L1237].
- Requires read permission on the post (else 403 `read_channel_content`).
- Response 200 `ChannelUnreadAt` (`model/channel_member.go` L41): `{team_id, user_id, channel_id, msg_count, mention_count, mention_count_root, urgent_mention_count, msg_count_root, last_viewed_at}`.
- The server sets `last_viewed_at = post.create_at - 1` and `msg_count = total - unread` (`sqlstore UpdateLastViewedAtPost` ~L3006), then emits WebSocket `post_unread`.
- CRT-unsupported path (`markChannelAsUnreadFromPostCRTUnsupported` ~L3260): on a reply, it auto-follows the thread and marks the channel unread.
- Thread-level unread is a separate endpoint: `POST /users/{uid}/teams/{tid}/threads/{thread_id}/set_unread/{post_id}`.

**Unread counts for one channel:** `GET /api/v4/users/{user_id}/channels/{channel_id}/unread`
- `getChannelUnread` L979 [L667]. SAME.
- Requires `read_channel`.
- Returns `ChannelUnread` `{team_id, channel_id, msg_count, mention_count, mention_count_root, urgent_mention_count, msg_count_root}`. Here **`msg_count` is already the unread count** (total − member). It is forced to 0 if the channel is muted (`app GetChannelUnread` ~L2700).
- Not a member, or channel archived: 404 `app.channel.get_unread.app_error`.

---

## 4. DMs and GMs

**Create or get a DM:** `POST /api/v4/channels/direct`
- Body `["<my_id>","<other_id>"]`. Exactly 2 distinct valid ids after de-duplication, or `["<my_id>"]` for a self-DM.
- `createDirectChannel` L625 [L466]. SAME.
- Requires `create_direct_channel`. Your own id must be in the list unless you have `manage_system`.
- `UserCanSeeOtherUser` failing gives 403 `view_members`.
- Returns **201** plus `Channel`, **even if the DM already existed**.
- Errors: 400 `api.context.invalid_body_param.app_error` (`user_ids` / `user_id`).

**Create or get a GM:** `POST /api/v4/channels/group`
- Body `[user_ids]`; your own id is added automatically.
- `createGroupChannel` L758 [L561]. Requires `create_group_channel`. Returns 201 plus `Channel`.
- Total must be 3–8 users (`ChannelGroupMinUsers` / `MaxUsers`), else 400 `api.channel.create_group.bad_size.app_error`. An unknown user gives 400 `api.channel.create_group.bad_user.app_error` (`app/channel.go createGroupChannel` ~L572).
- `name` = sha1 hex of the sorted ids concatenated (`GetGroupNameFromUserIds`, `model/channel.go` ~L607).
- `display_name` = sorted usernames joined with `", "`, **including yourself**, truncated to 64 bytes. The webapp recomputes it without the current user.

**Finding the DM partner** (`model/channel.go GetDMNameFromIds` ~L583 and `GetBothUsersForDM`; webapp `getUserIdFromChannelName` in `channel_utils.ts` ~L107):
- `name = "<idA>__<idB>"` with `idA < idB` (string comparison).
- Split on `"__"` and take the id that isn't yours.
- A self-DM is `"<me>__<me>"`.

**GM members:** `POST /api/v4/users/group_channels`
- Body `[gm_channel_ids]`. Returns `{"<channel_id>": [User,...]}` excluding the caller, sorted by username.
- Silently truncated to **50** channels (`sqlstore/user_store.go` `MaxGroupChannelsForProfiles` L29; `getUsersByGroupChannelIds` L828).

**Hiding DMs/GMs in the sidebar** (`redux/selectors/entities/channel_categories.ts` ~L96-241):
- Preferences are `direct_channel_show`, **name = teammate user_id**, and `group_channel_show`, **name = channel_id**, with value `"false"` meaning hidden. Note that the server comment in `model/preference.go` says "Name = channel ID"; the webapp uses the teammate id for DMs.
- Unread DMs and the current channel are always shown.
- Auto-close limit: `sidebar_settings`/`limit_visible_dms_gms`, default **40**, valid 1–40.

---

## 5. Join, leave, members, stats, browsing

**Join or add members:** `POST /api/v4/channels/{channel_id}/members`
- Body `{"user_id":"..."}` or `{"user_ids":[...]}` (≤1000), plus optional `"post_root_id"` (must belong to this channel).
- `addChannelMember` L2333 [L1855].
- Returns **201**:
  - a single `ChannelMember` if `user_id` was sent and exactly one member resulted;
  - otherwise `[ChannelMember]`.
- D/G channels: 400 `api.channel.add_user_to_channel.type.app_error`.
- Public channels:
  - Self-join requires `join_public_channels` on the team.
  - If you are already a member, the existing member is returned with 201.
  - Adding others requires `manage_public_channel_members`.
- Private channels require `manage_private_channel_members`.
  - **v11 only:** self-add to a discoverable private channel gives 403 `api.channel.discoverable_join_request.discoverable_requires_approval.app_error`. There is a new join-request flow in `api4/channel_join_request.go`.
- Group-constrained channels: 400 `api.channel.add_members.user_denied`.

**Leave or remove:** `DELETE /api/v4/channels/{channel_id}/members/{user_id|me}`
- `removeChannelMember` L2757 [L2081].
- Returns 200 `{"status":"OK"}`.
- Only O/P channels, else 400 `api.channel.remove_channel_member.type.app_error`.
- Leaving `town-square` as a non-guest: 400 `api.channel.remove.default.app_error` (`app removeUserFromChannel` ~L3012).
- Removing someone else from a group-constrained channel: 400 `api.channel.remove_member.group_constrained.app_error`.
- Removing others requires the `manage_*_channel_members` permission.

**Member list:** `GET /api/v4/channels/{channel_id}/members?page&per_page`
- Returns `[ChannelMember]`, with other users' timestamps set to -1.
- Requires `read_channel` (`getChannelMembers` L1865). SAME.
- `GET /channels/{id}/members/{user_id|me}` returns a single member.
- `POST /channels/{id}/members/ids` with body `[ids]` returns selected members.

**Stats:** `GET /api/v4/channels/{channel_id}/stats?exclude_files_count=true`
- Returns `{"channel_id","member_count","guest_count","pinnedpost_count","files_count"}`. **Note the key is `pinnedpost_count`.** `files_count` is -1 when excluded.
- Requires `read_channel` (`getChannelStats` L1006, `model/channel_stats.go`). SAME.

**Browse public channels:** `GET /api/v4/teams/{team_id}/channels?page&per_page`
- Public, non-archived, ordered by display_name. Requires `list_team_channels` (`getPublicChannelsForTeam` L1221). SAME.
- Archived channels: `GET /teams/{team_id}/channels/deleted?page&per_page` (L1274). SAME.

**Search public channels:** `POST /api/v4/teams/{team_id}/channels/search`
- Body `{"term":"..."}`; other `ChannelSearch` fields are ignored here.
- Returns up to **100** public channels ordered by display_name (`sqlstore SearchInTeam` ~L3628).
- Without `list_team_channels`, you must be a team member and it searches only your own public channels.
- Archived channels in results:
  - **v11: always included** (`app SearchChannels` `includeDeleted := true`).
  - **v10: included only if `TeamSettings.ExperimentalViewArchivedChannels`** (default true).
- **v10 only:** `POST /teams/{team_id}/channels/search_archived` (removed in v11).
- `GET /teams/{team_id}/channels/autocomplete?name=` is available in both for a quick switcher.

---

## 6. Users, profile images, status

**By id:** `POST /api/v4/users/ids?since=<ms>`
- Body `[ids]`; de-duplicated; empty gives 400.
- Returns `[User]` ordered by username.
- **`since` filters to `update_at > since`**, so unchanged users are omitted (`sqlstore/user_store.go GetProfileByIds` ~L1172).
- View restrictions apply (`getUsersByIds` L1182). SAME.

**By username:** `POST /api/v4/users/usernames` with body `[usernames]` returns `[User]` (L1231). SAME.

**List:** `GET /api/v4/users?in_channel=<id>&page&per_page[&sort=status|admin][&active=true|&inactive=true]` (`getUsers` L850)
- Branches are checked in this order: `without_team` > `not_in_channel` (needs `in_team`) > `not_in_team` > `in_team` > `in_channel` > `in_group` > `not_in_group` > all.
- **Don't combine `in_team` with `in_channel`; `in_team` wins.**
- `in_channel` requires `read_channel`. It is ordered by username and includes deactivated users unless `active=true`.
- ETag on the `in_team` and `not_in_team` branches.
- **v10 only:** `in_channel` on an archived channel with `ExperimentalViewArchivedChannels=false` gives 403 `api.user.view_archived_channels.get_users_in_channel.app_error`.

**Autocomplete:** `GET /api/v4/users/autocomplete?in_team=&in_channel=&name=&limit=` (`autocompleteUsers` L1385)
- Default limit **100**, max **1000**. The webapp sends 25.
- `in_channel` **requires `in_team`**, else **500** `api.user.autocomplete_users.missing_team_id.app_error`.
- Response `{"users":[User], "out_of_channel":[User] (omitempty, only with in_channel), "agents":[User] (omitempty, **v11 only**)}`.
- Never matches on email. Full names are matched only if `PrivacySettings.ShowFullName` is on or you are an admin.

**Search:** `POST /api/v4/users/search` (`searchUsers` L1277). SAME.
- Body `UserSearch` (`model/user_search.go`):
  - `term` (required, else 400)
  - `team_id`, `not_in_team_id`, `in_channel_id`, `not_in_channel_id` (requires `team_id`)
  - `in_group_id`, `not_in_group_id`, `group_constrained`, `allow_inactive`, `without_team`
  - `limit` (0 → 100; must be 1–1000)
  - `role`, `roles[]`, `channel_roles[]`, `team_roles[]`
- Returns `[User]`.

**User model fields for display** (`model/user.go` L92 [L77]; the JSON tags are identical in both):
- `id`, `create_at`, `update_at`, `delete_at`
- `username`, `email`, `nickname`, `first_name`, `last_name`, `position`
- `roles` (space-separated; `system_guest` means a guest)
- `props` (map[string]string), `notify_props`
- `last_picture_update` (omitempty), `locale`
- `timezone`: map `{useAutomaticTimezone:"true"|"false", automaticTimezone, manualTimezone}`
- `is_bot`, `bot_description`, `bot_last_icon_update`, `last_activity_at`, `remote_id`, `auth_service`
- Sanitizing (`Sanitize` ~L747, `GetSanitizeOptions`):
  - `email` is `""` unless `PrivacySettings.ShowEmailAddress` is on or you are an admin.
  - `first_name` / `last_name` are `""` unless `ShowFullName` is on.
- Display-name modes (`display_settings/name_format`, overriding config `TeammateNameDisplay` unless `LockTeammateNameDisplay` is on and licensed; `redux/selectors/entities/preferences.ts` ~L98):
  - `"username"`
  - `"nickname_full_name"`: nickname, else full name, else username
  - `"full_name"`: full name, else username

**Profile image:** `GET /api/v4/users/{id}/image?_=<last_picture_update>`
- The `_` parameter is only a cache-buster, matching the webapp's `client4.ts` ~L1066.
- `getProfileImage` L563. `Content-Type: image/png`.
- `ETag` = `last_picture_update` as a string. Send `If-None-Match` to get 304.
- `Cache-Control: max-age=86400, private`, or 300 seconds if the stored image read failed and a default was generated.
- `/image/default` always returns the generated default (L527).
- Both require `UserCanSeeOtherUser`, else 403.

**Statuses:** `POST /api/v4/users/status/ids`
- Body `[ids]`, **each exactly 26 chars**, else 400 (`api4/status.go getUserStatusesByIds` L57 [L51]).
- No permission check.
- Returns `[Status]`. Unknown users or users with no row come back as `{"user_id","status":"offline"}` (`app/platform/status.go` ~L185).
- If `ServiceSettings.EnableUserStatuses=false`, returns `[]`.
- `GET /users/{id}/status` returns one status, or 404 `api.status.user_not_found.app_error`.
- Status model (`model/status.go`):
  - `user_id`
  - `status`: `online` / `away` / `dnd` / `offline` / **`ooo`** (out of office)
  - `manual` (bool), `last_activity_at` (ms)
  - `dnd_end_time` (**seconds**)
- v10 difference: `active_channel` (omitempty) may be present because v10 marshals the struct directly; v11 strips it (`StatusListToJSON`).

**Custom status** (`model/custom_status.go`; SAME in both):
- Stored as `user.props["customStatus"]`, a **JSON string**: `{"emoji":"...","text":"...","duration":"thirty_minutes|one_hour|four_hours|today|this_week|date_and_time|''","expires_at":"<RFC3339>"}`.
- An empty string means cleared.
- The zero time `"0001-01-01T00:00:00Z"` means no expiry. The client should hide the status when `expires_at < now`.

---

## 7. Search

- `POST /api/v4/teams/{team_id}/posts/search` (requires `view_team`) and `POST /api/v4/posts/search` (all teams, no team filter) **both exist at both tags** (`api4/post.go` L39-40 [L38-39]; `searchPosts` L975 [L918]).
- `/posts/search` is documented in the YAML only at v11, but it is registered in v10 as well.
- The server does not check `EnableCrossTeamSearch` in `api4/post.go` or `app/post.go`. It is only exposed in client config.

**Body** (`model/post.go SearchParameter` ~L257): `{"terms": string (required, else 400 terms), "is_or_search": bool, "time_zone_offset": int seconds, "page": int, "per_page": int (default 60), "include_deleted_channels": bool}`.
- The webapp sends `per_page: 20`, `include_deleted_channels: true`, and `time_zone_offset = utcOffsetMinutes * 60` (`webapp/channels/src/actions/views/rhs.ts` ~L232).
- Other errors: 400 `api.post.search_posts.invalid_body.app_error`; 501 `store.sql_post.search.disabled` if `EnablePostSearch=false`.
- `include_deleted_channels`: v11 passes it through; v10 ANDs it with `ExperimentalViewArchivedChannels`.

**Response** (`model/post_search_results.go`): the PostList fields `{order:[ids], posts:{id:Post}, next_post_id, prev_post_id, has_next?, first_inaccessible_post_time}` plus `"matches": {post_id:[terms]}`. Header `Cache-Control: no-cache, no-store, must-revalidate`.

**Database-backed search (no Elasticsearch/Bleve)** (`sqlstore/post_store.go SearchPostsForUser` ~L2909):
- `page > 0` returns an **empty list**.
- At most **100** results, ordered by create_at descending.
- System messages are excluded.
- `matches` is null.

**Query grammar** (`model/search_params.go`; identical in both):
- Flags (case-insensitive): `from:`, `in:`, `channel:`, `before:`, `after:`, `on:`, `ext:`. A space after the colon is allowed (`from: bob`).
- A `-` prefix excludes (`-from:x`, `-word`).
- Dates are `YYYY-MM-DD`. `after:` and `before:` are exclusive (day +1 / −1); `on:` covers the whole day. All dates are interpreted in `time_zone_offset`.
- `"quoted phrases"` are supported, as is a trailing `*` wildcard. Leading and trailing punctuation is stripped.
- Hashtags match `^#\pL[\pL\d\-_.]*[\pL\d]$` and are searched against the hashtags field. Repeated leading `##` collapses to `#`.
- `from:` takes a username (`@` optional).
- `in:` takes a channel **name** (`~` optional), `@username` for a DM, or `@a,b` for a GM (`app/post.go parseAndFetchChannelIdByNameFromInFilter` ~L2056). Channel names are resolved against the given team, so cross-team `in:` by name may fail to resolve.
- A search of just `*` returns nothing.

**File search:** `POST /teams/{team_id}/files/search` and `POST /files/search` take the same body and return a FileInfoList `{order, file_infos:{id:FileInfo}, next_file_info_id, prev_file_info_id, first_inaccessible_file_time}`. The shape is assumed from the model.

---

## 8. Files

**Upload:** `POST /api/v4/files`
- `api4/file.go uploadFileStream` L77. The handler is SAME; v11 adds ABAC and restricted-DM checks.
- Returns **201** `{"file_infos":[FileInfo], "client_ids":[string]}` (`model/file.go`).
- Preconditions:
  - `EnableFileAttachments=false` → 403 `api.file.attachments.disabled.app_error`.
  - `Content-Length: 0` → 400 `api.file.upload_file.read_request.app_error`.
  - Missing `upload_file` permission → 403.
  - **v11 only:** ABAC denial → 403 `api.file.upload_file.abac_denied.app_error`; restricted DM → 400 `api.file.upload_file.restricted_dm.error`.
- **Raw body variant** (`uploadFileSimple` L133): used when Content-Type is not `multipart/form-data`.
  - Query `?channel_id=<id>&filename=<name>[&client_id=<id>]`; `filename` missing gives 400 invalid_url_param.
  - Body = the file bytes.
  - `Content-Length > MaxFileSize` → early 413.
- **Multipart variant** (`uploadFileMultipart` L210):
  - Put text part `channel_id` (or query `channel_id`) **first**, then optional `client_ids` parts, then file parts. The webapp does exactly this, one file per request: `webapp/channels/src/actions/file_actions.ts` ~L62 appends `channel_id`, `client_ids`, `files`.
  - Any part with a filename counts as a file.
  - Text parts other than `channel_id` / `client_ids` → 400. Text parts are capped at 10 KB.
  - `client_ids` must be sent for either none or all of the files; a mismatched count gives 400 `api.file.upload_file.incorrect_number_of_client_ids.app_error`.
  - A different `channel_id` in the body than in the query → 400 `api.file.upload_file.multiple_channel_ids.app_error`.
  - If a file part arrives before `channel_id`, the server falls back to legacy buffered parsing (`uploadFileMultipartLegacy` L420), which **only reads the form field `files`**.
- **Size limit:**
  - Per file: `FileSettings.MaxFileSize` (default 100 MiB = 104857600, `model/config.go` ~L1919). Exposed to clients as config string `MaxFileSize` (`server/config/client.go` L91 [L86], full config).
  - Over the limit: 413 `api.file.upload_file.too_large_detailed.app_error` (`app/file.go UploadFileX` ~L820/842).
  - **The whole request is also capped at MaxFileSize + 512 bytes**, so upload files one per request.
- **Image processing:**
  - Images over `MaxImageResolution` pixels → 400 `api.file.upload_file.large_image_detailed.app_error`.
  - Thumbnail 120×100, preview width 1920, mini_preview 16×16 JPEG q90 (`app/file.go` L44-49).
- **Max files per post:** the server has no count constant, only `PostFileidsMaxRunes = 300` for the JSON array, which works out to **10** 26-char ids (`model/post.go` L72/585; error `model.post.is_valid.file_ids.app_error`). The webapp's `MAX_UPLOAD_FILES` is 10.
- **Related client-config flags:** `EnableFileAttachments`, `EnablePublicLink`, `EnableMobileFileUpload` / `EnableMobileFileDownload`.

**Downloads** (all require read access to the channel, or being the uploader; v11 also enforces ABAC `api.file.get_file.abac_denied.app_error` 403 and plugin rejection 403 with header `X-Reject-Reason`):

| Endpoint | Details |
|---|---|
| `GET /api/v4/files/{file_id}[?download=1]` | `getFile` L519 [L466]. **HEAD is supported only in v11.** Deleted or missing → 404 `api.file.get_file_info.app_error`. Served via Go `http.ServeContent`: Range requests, `If-Modified-Since`, and `Last-Modified` = update_at. |
| `/thumbnail` | L641. Missing → 400 `api.file.get_file_thumbnail.no_thumbnail.app_error`. |
| `/preview` | L772. Missing → 400 `api.file.get_file_preview.no_preview.app_error`. **Thumbnail and preview are always labeled `image/jpeg` but contain PNG bytes when the source was PNG** (`postprocessImage` ~L978). |
| `/info` | L841. Returns `FileInfo`, `Cache-Control: max-age=2592000, private`. |
| `/link` | L709. Returns `{"link":"<siteURL>/files/<id>/public?h=<hash>"}`. Needs `EnablePublicLink` (else 403 `api.file.get_public_link.disabled.app_error`). Unattached file → 400 `api.file.get_public_link.no_post.app_error`. |
| Cloud-limit files | Header `First-Inaccessible-File-Time: 1`. |

**Headers on download** (`server/platform/shared/web/files.go setHeaders`; identical in both):
- `Content-Disposition: inline;filename="<pct-escaped>"; filename*=UTF-8''<pct-escaped>` for image/jpeg|png|bmp|gif|tiff|webp, video/avi|mpeg|mp4, audio/mpeg|wav.
- **`attachment` for everything else, or whenever `download=1`.**
- JS and HTML content types are rewritten to `text/plain`.
- `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Cache-Control: private, max-age=86400` (unless already set).
- `Content-Length` = size, or `X-Uncompressed-Content-Length` when `WebserverMode=gzip`.

**FileInfo** (`model/file_info.go` L58 [~L44]; JSON tags identical):
- `id`, `user_id` (creator), `post_id` (omitempty), `channel_id`
- `create_at`, `update_at`, `delete_at`
- `name`, `extension`, `size` (int64 bytes), `mime_type`
- `width`, `height` (omitempty)
- `has_preview_image` (omitempty; false for GIF and SVG)
- `mini_preview`: **base64 string of a 16×16 JPEG, or null**
- `remote_id` (string?), `archived` (bool)

**Resumable upload sessions** exist in both tags (`api4/upload.go`):
1. `POST /api/v4/uploads` with body `{"channel_id","filename","file_size"}` → 201 `UploadSession` `{id, type:"attachment", create_at, user_id, channel_id, filename, file_size, file_offset, remote_id, req_file_id}`.
   - `file_size > MaxFileSize` → 413 `api.upload.create.upload_too_large.app_error`.
   - Attachments disabled → **501** (not 403 as on `/files`).
2. `POST /api/v4/uploads/{upload_id}` with the raw chunk body. `Content-Length` must be ≤ `file_size - file_offset`, else 400 `api.upload.upload_data.invalid_content_length`. A multipart body is also accepted; the first part is used.
   - Returns **204** while incomplete, **200** plus `FileInfo` when complete.
3. `GET /api/v4/uploads/{upload_id}` returns the session so you can resume from `file_offset`.

---

## 9. Preferences and sidebar categories

**Preferences** (`api4/preference.go`; routes identical in both):
- `GET /api/v4/users/me/preferences` → `[{"user_id","category","name","value"}]`, all values strings.
- `GET /users/me/preferences/{category}` and `GET /users/me/preferences/{category}/name/{name}`.
- `PUT /users/me/preferences` with body `[Preference]` (1–100 items, else 400) → `{"status":"OK"}`.
- `POST /users/me/preferences/delete` with the same body shape.
- Limits (`model/preference.go IsValid`):
  - category ≤ 32 chars, name ≤ 32 chars, value ≤ 20000 runes
  - `flagged_post` names are validated as readable posts
  - `limit_visible_dms_gms` must be 1–40

Categories and names that matter (server constants in `model/preference.go` L15-120; webapp values in `wc_utils_constants.tsx` ~L89-116):
- `display_settings`:
  - `use_military_time` `"true"`/`"false"` (default false)
  - `collapsed_reply_threads` `"on"`/`"off"`
  - `name_format` `username|nickname_full_name|full_name`
  - `channel_display_mode` `full|centered` (default full)
  - `message_display` `clean|compact` (default clean)
  - `collapse_previews`, `colorize_usernames`, `collapse_consecutive_messages`
- `direct_channel_show` (name = teammate user id), `group_channel_show` (name = channel id): `"true"`/`"false"`.
- `favorite_channel` (name = channel id).
- `sidebar_settings`: `show_unread_section`, `limit_visible_dms_gms`, `channel_sidebar_organization`.
- `flagged_post` (name = post id).
- `theme` (name = team id or ""; value is a JSON map).
- `custom_status`/`recent_custom_statuses`.
- `advanced_settings`: `send_on_ctrl_enter`, `join_leave`, `formatting`, `sync_drafts`, …
- `channel_open_time` / `channel_approximate_view_time` (name = channel id; used by DM auto-close).
- `notifications`/`email_interval`.

**Sidebar categories:** `GET /api/v4/users/me/teams/{team_id}/channels/categories`
- `api4/channel_category.go getCategoriesForTeamForUser` L14. SAME.
- Requires `view_team`.
- Default categories are created automatically if none exist (`app/channel_category.go` ~L27).
- Response `OrderedSidebarCategories` (`model/channel_sidebar.go`):

```json
{"categories":[{"id","user_id","team_id","sort_order":int64,"sorting":""|"manual"|"recent"|"alpha","type":"favorites"|"channels"|"direct_messages"|"custom"|"managed"(v11 only),"display_name","muted":bool,"collapsed":bool,"channel_ids":[...]}],
 "order":["category_id",...]}
```

- Default category ids look like `{favorites|channels|direct_messages}_{userId}_{teamId}`. Custom categories have normal 26-char ids.
- Other routes:
  - `GET …/categories/order` → `[ids]`
  - `PUT …/categories` with body `[SidebarCategoryWithChannels]`
  - `PUT` / `GET` / `DELETE …/categories/{category_id}`
  - `PUT …/categories/order`
- **v11 only**, behind feature flag `ManagedChannelCategories`: `GET /teams/{team_id}/channels/managed_categories`.

---

## 10. Custom emoji (`api4/emoji.go`; identical in both)

- All emoji endpoints return 501 `api.emoji.disabled.app_error` if `ServiceSettings.EnableCustomEmoji` is false. That flag is in the limited client config.
- `GET /api/v4/emoji?page&per_page&sort=name` (L116): `sort` must be `""` or `"name"`, else 400. **Without `sort=name` the query has no ORDER BY**, so pages are not stable (`sqlstore/emoji_store.go GetList` ~L74). Always send `sort=name`. Returns `[Emoji]`.
- Emoji model: `{id, create_at, update_at, delete_at, creator_id, name}`, name ≤ 64 chars matching `[a-zA-Z0-9_+-]`.
- `GET /api/v4/emoji/{emoji_id}/image` (L284): `Content-Type: image/<png|gif|jpeg>` based on the decoded bytes, `Cache-Control: max-age=2592000, private`. 404 `app.emoji.get.no_result` or `api.emoji.get_image.read.app_error`.
- `GET /api/v4/emoji/name/{name}` (L229) returns an `Emoji`.
- `POST /emoji/names` with body `[names]` (≤ **200**, else 400 `api.emoji.get_multiple_by_name_too_many.request_error`).
- `GET /emoji/autocomplete?name=` returns up to 100.
- System (Unicode) emoji are not served by this API; ship them client-side.

---

## 11. What differs between v10.11.24 and v11.11.1

| Area | v10.11.24 | v11.11.1 |
|---|---|---|
| Channel types | O/P/D/G | adds S/BO/BP; list endpoints filter to O/P/D/G but member lists exclude only S |
| Channel fields | — | adds `autotranslation`, `policy_actions`, `policy_is_active`, `managed_category_name`, `discoverable` |
| ChannelMember fields | — | adds `autotranslation_disabled` |
| Team fields | — | adds `policy_enforced`, `policy_actions`, `policy_is_active`, `recommended` |
| Channel search | archived included only if `ExperimentalViewArchivedChannels`; has `POST …/channels/search_archived` | archived always included; `search_archived` removed |
| Post search `include_deleted_channels` | ANDed with `ExperimentalViewArchivedChannels` | passed through |
| `GET /users?in_channel=` on an archived channel | 403 when the view-archived setting is off | no check |
| `/users/autocomplete` response | — | adds `agents` |
| Status JSON | may include `active_channel` | strips it |
| Files | GET only | HEAD on `/files/{id}`, `/thumbnail`, `/preview`; ABAC and plugin download checks; restricted-DM upload check |
| New v11-only routes | — | `PUT /users/{uid}/teams/{tid}/read`, `PUT /channels/members/{uid}/direct/read` (both feature-flagged), `PUT /channels/{id}/members` (bulk set, NDJSON response), `/members/{uid}/autotranslation`, `/teams/{tid}/channels/recommended`, managed categories, channel join requests, discoverable private channels |
| Unchanged | | view, mark_read, set_unread, channel unread, `/users/me/channels`, `/users/me/channel_members` (including `page=-1` NDJSON), DM/GM create, team endpoints, preferences, categories, emoji, upload sessions, profile images, status by ids |

---

## 12. Not verified

- How the search layer behaves when Elasticsearch or Bleve is enabled: pagination, the `matches` map, and the result limit. I only read the database store path.
- The exact shape of the file-search response. I assumed `FileInfoList`; I did not read `app SearchFilesInTeamForUser`.
- Which cache-buster the webapp uses for bot avatars (`bot_last_icon_update` vs `last_picture_update`).
- Whether the server keeps the `favorite_channel` preference in sync with the `favorites` sidebar category.
- Whether the server clears expired custom statuses itself.
- Whether `EnableCrossTeamSearch` is enforced anywhere outside `api4/post.go` and `app/post.go`.
- Ordering of `GET /channels/{id}/members`, and exactly which `ChannelSearch` fields `POST /channels/search` honors for non-admin callers (`system_console=false`).
- The WebSocket payloads other than the events named above (`multiple_channels_viewed`, `post_unread`, `thread_read_changed`).