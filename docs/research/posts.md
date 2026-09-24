# MatterMac research: Posts, pagination, threads, send dedup, edit/delete, reactions

**Sources.** Raw Go and TypeScript source at tags `v11.11.1` and `v10.11.24`, saved in `/tmp/mm-research-posts/<tag>/`. Citations use the form `path@tag:line` (line numbers are approximate) or `func` names.

**Conventions.** Every timestamp is **Unix milliseconds** (`int64`) unless stated otherwise. Every ID is a 26-character lowercase alphanumeric string (`model.IsValidId`). Error bodies are `AppError` JSON: `{id, message, detailed_error, request_id?, status_code?}` (`server/public/model/utils.go@v11.11.1:232`). Permission failures are **403** with `id = "api.context.permissions.app_error"`. Invalid body or query params are **400** `api.context.invalid_body_param.app_error`. Invalid path params are **400** `api.context.invalid_url_param.app_error`.

---

## 1. Post JSON model

`server/public/model/post.go@v11.11.1:137` (`type Post`) and `@v10.11.24:89`. The JSON tags are identical in both versions (v11 only adds `xml` tags).

| JSON key | Go type | Always present? | Notes |
|---|---|---|---|
| `id` | string | yes | Must be **empty on create**. A non-empty id gets 400 `app.post.save.existing.app_error` (`SaveMultiple` in `post_store.go@v11:168`). |
| `create_at` | int64 ms | yes | Ignored on create unless the caller has `manage_system` (reset to 0 in `createPost@v11:130`). |
| `update_at` | int64 ms | yes | Bumped by edits, reactions, pin changes, deletes, and by any reply (the root's `update_at` is set to the reply's `create_at`, `SaveMultiple`). Also bumped when a reply is edited or deleted. |
| `edit_at` | int64 ms | yes | 0 means never edited. Set only when `message`, `file_ids` or attachments change (`UpdatePost@v11:915-940`). Pinning does not change it. |
| `delete_at` | int64 ms | yes | Greater than 0 means soft-deleted. |
| `is_pinned` | bool | yes | |
| `user_id` | string | yes | Overwritten with the session user on create. |
| `channel_id` | string | yes | |
| `root_id` | string | yes | `""` for a root post. Replies to replies are rejected. |
| `original_id` | string | yes | Normally `""`. Non-empty only on hidden **edit-history rows**: the old version is re-inserted as a deleted row with a new id and `original_id = <post id>` (`Update` in `post_store.go@v11:393-452`). |
| `message` | string | yes | Blanked to `""` for deleted posts in any prepared response (`PreparePostForClient@v11 post_metadata.go:189`). |
| `message_source` | string | **omitempty** | Original text when the image proxy rewrote `message`. Use it to fill the edit box. |
| `type` | string | yes | See the constants below. |
| `props` | object `{string: any}` | yes (usually `{}`) | Treat as JSON `Any`. |
| `hashtags` | string | yes | Space-separated. Always recomputed by the server, so client input is ignored. |
| `file_ids` | [string] | yes (may be `[]`; decode as optional) | Limited to 300 runes of JSON, which is effectively **≤10 ids**. The YAML's "5 files" is not enforced in this code. |
| `pending_post_id` | string | yes | **Not persisted in the database.** Non-empty only in the create response and in the `posted`/`post_edited` WebSocket echo. `""` in every fetched post. |
| `has_reactions` | bool | **omitempty** | Absent means false. |
| `remote_id` | string? | **omitempty (pointer)** | Can arrive as `""`. Shared channels only. |
| `reply_count` | int64 | yes | See the gotcha in §3 (non-CRT `page` query returns 0). |
| `last_reply_at` | int64 ms | yes | Non-zero only for collapsed-threads (CRT) queries. |
| `participants` | [User]? | yes, **can be `null`** | CRT responses only. Items are `{id}` stubs unless `collapsedThreadsExtended=true`. |
| `is_following` | bool? | **omitempty** | Root posts in CRT queries only. Forced `nil` in `post_edited` broadcasts. |
| `metadata` | PostMetadata? | **omitempty** | Present (`{}` or filled) on prepared REST/WebSocket posts. **Absent** on posts inside the user thread list and on the dedup-return path (§4). |

**Decoding advice:** decode every field except `id` as optional or defaulted.

**`PostPatch`** (`post.go@v11:211`): `{is_pinned?: bool, message?: string, props?: object, file_ids?: [string], has_reactions?: bool}`. Only non-null keys are applied.

### `metadata` (`server/public/model/post_metadata.go`)

All keys are omitempty.

- `embeds`: `[{type, url?, data?}]`, where `type` is one of `image | message_attachment | opengraph | link | permalink | boards` (`post_embed.go`).
  - For `permalink`, `data` is `PreviewPost {post_id, post, team_name, channel_display_name, channel_type, channel_id}` (`permalink.go`).
- `emojis`: `[Emoji {id, create_at, update_at, delete_at, creator_id, name}]`. Custom emojis only, covering both the message and its reactions.
- `files`: `[FileInfo]`.
- `images`: `{url: {width, height, format, frame_count}}`.
- `reactions`: `[Reaction]`, filled only when `has_reactions` is true (`getEmojisAndReactionsForPost@v11 post_metadata.go:560`).
- `priority`: `{priority: string|null ("" | "important" | "urgent"), requested_ack: bool|null, persistent_notifications: bool|null}`.
  - May also carry stray `"PostId"` / `"ChannelId"` keys, because those Go fields are tagged `json:",omitempty"` (`post.go@v11:230`). Ignore unknown keys.
  - List endpoints add it only when `ServiceSettings.PostPriority` is on, and only for ids in `order` (`PreparePostListForClient@v11:56`). `GET /posts/{id}` always requests it.
- `acknowledgements`: `[{user_id, post_id, acknowledged_at (ms), channel_id, remote_id?}]`.
- **v11 only:** `redacted_file_count` (int), `translations` (`{lang: {text?, object?, type, state, source_lang?}}`), `expire_at` (ms, burn-on-read), `recipients` ([string]).

### Post type constants

`post.go@v11:28-70`. Every server-side `system_*` type is rejected on create (400, see §4).

- **Core types:**
  - `""` (default), `slack_attachment`, `system_generic`
  - `system_join_leave` (deprecated), `system_join_channel`, `system_guest_join_channel`, `system_leave_channel`
  - `system_join_team`, `system_leave_team`, `system_auto_responder`
  - `system_add_remove` (deprecated), `system_add_to_channel`, `system_add_guest_to_chan`, `system_remove_from_channel`
  - `system_move_channel`, `system_add_to_team`, `system_remove_from_team`
  - `system_header_change`, `system_displayname_change`, `system_convert_channel`, `system_purpose_change`
  - `system_channel_deleted`, `system_channel_restored`
  - `system_ephemeral` (never stored; arrives only through the `ephemeral_message` WebSocket event)
  - `system_change_chan_privacy`, `system_wrangler`, `system_gm_to_channel`
  - `add_bot_teams_channels`, `me`, `reminder`
  - `custom_*` is the prefix for plugin types (the server accepts any `custom_` type).
- **v11 only:** `system_autotranslation`, `system_team_abac_removal`, `system_team_abac_addition`, `burn_on_read`, `card` (feature flag `IntegratedBoards`), `system_shared_chan_state`.
  - v10 names `slack_attachment` `PostTypeSlackAttachment`. The value is the same.
- **Client-only (webapp, never on the wire):** `system_combined_user_activity`, `system_join_leave_channel`, `system_ephemeral_add_to_channel` (`webapp/.../mattermost-redux/src/constants/posts.ts@v11`).
- `custom_calls` is not a core constant (Calls plugin, **UNVERIFIED**).
- "Join/leave" set (`IsJoinLeaveMessage`, `post.go@v11:1125`): `join_leave`, `add_remove`, `join_channel`, `leave_channel`, `join_team`, `leave_team`, `add_to_channel`, `remove_from_channel`, `add_to_team`, `remove_from_team` (each with the `system_` prefix).

**Useful prop keys:** `from_webhook`, `from_bot`, `from_oauth_app`, `from_plugin`, `override_username`, `override_icon_url`, `override_icon_emoji`, `attachments`, `deleteBy` (set on soft delete), `previewed_post`, `channel_mentions`, `disable_group_highlight`, `mentionHighlightDisabled`, `addedUserId`. On DM/GM posts the webapp sends `props.current_team_id`.

---

## 2. PostList JSON

`post_list.go`, same in both versions. v11 adds only an internal field tagged `json:"-"`.

```
{ "order": [string], "posts": {id: Post}, "next_post_id": string, "prev_post_id": string,
  "has_next": bool (omitempty; thread endpoint only), "first_inaccessible_post_time": int64 ms (0 on self-hosted) }
```

**`order`**
- Channel endpoints: **newest first** (`CreateAt DESC`). Before/after queries run ascending and are then reversed (`prepareThreadedResponse` called with `reversed = !before`, `post_store.go@v11:1259, 1701`).
- Thread endpoint: `order[0]` is always the requested post. The rest follow `direction` (`down` = ascending, `up` = descending). With no direction the SQL has no `ORDER BY`, so order is **undefined**.

**`posts`** is a superset of `order`: it also carries root/parent posts of replies (non-CRT), and in the unread endpoint the whole thread of the first unread post.

**Cursor ids** (`AddCursorIdsForPostList@v11 app/post.go:1886`): `next_post_id` is the newer neighbour and `prev_post_id` the older neighbour. Both skip deleted posts, and in CRT they are root-only (`getPostIdAroundTime`). `""` means you reached that end.
- `since` query: both `""`.
- `after=X`, page 0: `prev_post_id = X`. `next_post_id = ""` if `len(order) < per_page`, otherwise it is looked up.
- `before=X`, page 0: `next_post_id = X`. `prev_post_id = ""` if `len(order) < per_page`, otherwise it is looked up.
- Plain page: both are looked up from the newest and oldest post in the list.

---

## 3. `GET /api/v4/channels/{channel_id}/posts`

`getPostsForChannel`: `api4/post.go@v11:276`, `@v10:222`.

### Query parameters

- `page` (int, default 0; negative becomes 0).
- `per_page` (int, default 60, **silently capped at 200**; negative becomes 60; `web/params.go@v11:19-20, 234-241`).
- `since` (int64 ms; must parse or 400).
- `before` and `after` (post ids; must be valid ids or 400).
- `include_deleted` (bool; a non-admin gets 403 `read_deleted_posts`).
- `skipFetchThreads`, `collapsedThreads`, `collapsedThreadsExtended` (bool).
- **v11** parses bools with `strconv.ParseBool` (`1/t/T/TRUE/true/True`). **v10** requires exactly the string `"true"`.
- The YAML documents a `type` parameter, but **neither handler reads it** (doc only).

### Precedence

No error is raised for mixed parameters. The handler takes the first match:

1. `since > 0`: `GetPostsSince`. `page`, `per_page`, `before`, `after` and `include_deleted` are all ignored.
2. `after`: `GetPostsAfterPost` (note: `collapsedThreadsExtended` is **not** passed on this path in either version).
3. `before`: `GetPostsBeforePost`.
4. Otherwise `GetPostsPage`.

`page` and `per_page` act as an offset **relative to the anchor** (`offset = page * per_page`).

### `since` semantics

`GetPostsSince` in `post_store.go@v11:1437`:
- **Non-CRT:** a CTE takes `UpdateAt > since AND ChannelId = ? LIMIT 1000` with **no ORDER BY**, so past 1000 you get an arbitrary subset. It is UNIONed with the root posts of those rows.
  - Only rows with `update_at > since` go into `order` (sorted `CreateAt DESC`).
  - There is **no `DeleteAt` filter**: deleted posts come back (message blanked) and so do **edit-history rows** (with `original_id != ""`, `delete_at > 0`, and unknown ids).
  - The webapp only applies `delete_at > 0` to posts it already holds and ignores unknown ids (`reducers/entities/posts.ts@v11:528`). Do the same, and also drop any post whose `original_id != ""`.
- **CRT** (`getPostsSinceCollapsedThreads@v11:1406`): **root posts only** (`RootId=''`), `UpdateAt > since`, deleted posts included, `ORDER BY CreateAt DESC LIMIT 1000`, carrying thread fields.
  - Reply edits or deletes reach you only indirectly, through the root's bumped `update_at`. Refetch open threads.
- If `order.count ≥ 1000`, treat it as a possible gap and reload the newest page.
- No ETag is used on the `since` path.

### Page and before/after semantics

**Non-CRT page** (`GetPosts`, `getRootPosts`, `getParentsPosts`, `post_store.go@v11:1355, 1949, 1973`):
- `order` contains every post, roots and replies interleaved.
- `posts` also holds, for each reply in the page:
  - `skipFetchThreads=false`: the root **and all replies of that thread**.
  - `skipFetchThreads=true`: only the root post.
- **Gotcha:** with `skipFetchThreads=false` the page query does not compute `reply_count`, so it is **0**. `before`/`after` queries always compute it.

**CRT** (`collapsedThreads=true`, `getPostsCollapsedThreads@v11:1322`, `getPostsAround`):
- `order` and `posts` hold **root posts only**, non-deleted.
- Each root carries `reply_count` (from the Threads table), `last_reply_at`, `participants` (`{id}` stubs, or full users with `collapsedThreadsExtended`) and `is_following`.

**Deleted anchor** (`getPostsAround@v11:1701`): the condition is `CreateAt < (SELECT CreateAt FROM Posts WHERE Id = ?)` with no `DeleteAt` check on the anchor. A **soft-deleted `before`/`after` post still works** as a cursor. A permanently deleted anchor makes the subquery NULL, so you get an empty list and `""` cursors (**PLAUSIBLE**, inferred from the SQL).

### Headers

- The response sets `ETag`, and a matching `If-None-Match` gets **304**.
- The ETag is `"<CurrentVersion>.<max UpdateAt in channel>"`. It is **per channel, not per page or cursor** (`GetEtag@v11 post_store.go:951`), and it ignores per-user fields such as `is_following`.
- Do not send `If-None-Match` across different queries. Disable `URLCache` for the API: every GET carries `Expires: 0` plus the ETag, and URLSession may revalidate on its own.

### `GET /api/v4/users/{user_id}/channels/{channel_id}/posts/unread`

`getPostsForChannelAroundLastUnread@v11:395`, app function `@v11:1927`.

- **Parameters:** `limit_before` (default 60, max 200), `limit_after` (default 60, max 200; **0 gives 400** `api.context.invalid_url_param.app_error` with name `limit_after`), plus `skipFetchThreads`, `collapsedThreads`, `collapsedThreadsExtended` (exact string `"true"` in both versions). `user_id` may be `me`.
- **Algorithm:**
  1. Read the channel member's `last_viewed_at`.
  2. The first unread post is the oldest non-deleted post with `CreateAt > last_viewed_at` (root-only in CRT).
  3. The result is that post, plus `limit_before` older posts, plus `limit_after - 1` newer posts, sorted `CreateAt DESC`.
  4. `posts` also includes that post's thread (via `GetPostThread`).
- **Fallback:** if `last_viewed_at == 0` or there is no unread post, the server returns the newest page with `per_page = limit_before` (ETag applies on this path).
- Cursors are computed from the list.
- The webapp defaults are `limit_after = 30`, `limit_before = 30` (`client4.ts@v11:181-182`).

---

## 4. `POST /api/v4/posts` (create)

`createPost`: `api4/post.go@v11:116`, `@v10:96`. `CreatePostAsUserWithFlags` / `CreatePost`: `app/post.go@v11:42, 172`.

### Query parameters

- `set_online` (bool, default true; unparsable values fall back to true).
- **v11 only:** `silent=true`. For non-integration users it gives 403 `api.post.create_post.silent_notification.app_error`, so do not send it.

### Body (a Post JSON)

- **Accepted:** `channel_id` (required), `message`, `root_id`, `file_ids`, `props`, `pending_post_id`, `type` (non-`system_`), `metadata.priority`.
- **`metadata.priority`:**
  - Root posts only, else 400 `api.post.post_priority.priority_post_only_allowed_for_root_post.request_error`.
  - Disabled by config gives 403 `...priority_post_not_allowed_for_user.request_error`.
  - `requested_ack` or `persistent_notifications` without a Professional license gives 501 `license_error.feature_unavailable`.
  - Persistent notifications require priority `urgent`.
  - Always send `priority` as a string (`""`, `"important"` or `"urgent"`).
- **Ignored or overwritten:** `user_id`, `hashtags`, `delete_at`, `remote_id`, `metadata.embeds`, and `create_at` for non-admins.
- `is_pinned` is not reset by the server. Do not send it.
- **Must not send:** `id`.
- The webapp sends `{...post, pending_post_id, create_at: 0, update_at, reply_count}` (`actions/posts.ts@v11:180-260`).

### Response

- **201** with the prepared Post (metadata filled, `pending_post_id` echoed).
- The `posted` WebSocket event (`data.post` is a JSON **string**, which also carries `pending_post_id`) can arrive **before** the HTTP response. Reconcile in either order by `pending_post_id`.

### Validation and errors

| Condition | Status | Error id |
|---|---|---|
| Unknown channel | 400 | `api.context.invalid_param.app_error` (Name `post.channel_id`) |
| Archived channel | 400 | `api.post.create_post.can_not_post_to_deleted.error` |
| System type | 400 | v11: `api.context.invalid_body_param.app_error` (`post.type`), raised in `createPostChecks@v11:84`. v10: `api.context.invalid_param.app_error`, raised in the app layer. |
| No `create_post` permission (and no `create_post_public` for public channels) | 403 | `api.context.permissions.app_error` |
| `file_ids` without `upload_file` | 403 | `api.context.permissions.app_error` |
| Bad, missing or deleted root, or reply-to-reply | 400 | `api.post.create_post.root_id.app_error` |
| Root in another channel | 400 | `api.post.create_post.channel_root_id.app_error` (forced to 400) |
| Restricted DM (**v11 only**) | 400 | `api.post.create_post.can_not_post_in_restricted_dm.error` |
| Unknown type | 400 | `model.post.is_valid.type.app_error` |
| `file_ids` too long | 400 | `model.post.is_valid.file_ids.app_error` |
| Props too large (>800000 runes) | 400 | `model.post.is_valid.props.app_error` |

- File ids that fail to attach are **silently dropped** (logged only, `attachFilesToPost@v11:528`).
- The webapp deletes the local pending post on `api.post.create_post.root_id.app_error`, `api.post.create_post.town_square_read_only` and `plugin.message_will_be_posted.dismiss_post`. On any other error it marks the post failed.

### Maximum message length

- `model.PostMessageMaxRunesV2 = 65535/4 = 16383` (`post.go@v11:75-77`).
- The effective value is `max(dbColumnBytes/4, 16383)` (`determineMaxPostSize@v11 post_store.go:2721`).
- It is exposed as the string `MaxPostSize` in `GET /api/v4/config/client?format=old` (`ClientConfigWithComputed`, `platform/config.go@v11:347`, same in v10).
- Counting is `utf8.RuneCountInString`, which equals Swift `message.unicodeScalars.count`.
- Too long gives **400** `model.post.is_valid.message_length.app_error`. The `{Length, MaxLength}` params are only interpolated into `message`. The check runs before processing (`rejectOversizedMessage@v11:64`). The same check applies to PUT and PATCH.

### `pending_post_id` deduplication

`deduplicateCreatePost` (`app/post.go@v11:126`, `@v10:138`; logic identical in both versions).

**Server rules:**
- **Format:** not validated anywhere. There is no length check and no database column.
- **Key scope:** the cache key is the raw `pending_post_id` string, **global** (not per user or channel).
- **Cache:** `seen_pending_post_ids`, 25,000 entries, TTL `pendingPostIDsCacheTTL = 30s` (`app/post.go@v11:29-33`, `server.go@v11:428`).
- **Algorithm:**
  1. Empty id: no dedup.
  2. Key not in cache: store `key → ""` (in flight) and proceed.
  3. Value is `""` (first request still saving): **500** `api.post.deduplicate_create_post.pending`. Retry after a short delay with the same id.
  4. Value is a post id: load it with `GetPostIfAuthorized`.
     - If that returns 403, the id is ignored and a **new** post is created.
     - Any other error: 500 `api.post.deduplicate_create_post.failed_to_get`.
     - Otherwise the response is **201 with the existing post**. That post is loaded straight from the database: **`pending_post_id` is `""`, no `metadata`**, and no new WebSocket event is sent. Match it to your request, not by the echoed id.
  5. On success the cache maps to the real id for 30s. On failure the entry is **removed**, so an immediate retry creates the post.

**When dedup does not apply:**
- Empty id.
- The TTL has expired.
- LRU eviction.
- The first attempt failed.
- The existing post is unreadable for the requester.
- The default `CacheSettings.CacheType = "lru"` is **per node**, so there is no dedup across HA nodes. With `redis` it is shared (**UNVERIFIED** in cluster).

**Webapp format:** `` `${currentUserId}:${Date.now()}` `` (`actions/posts.ts@v11:191`, `@v10:189`). Use `"<user_id>:<ms>"` and bump the ms value on a collision. That keeps it globally unique.

---

## 5. Edit and delete

**Time limit.** `postEditTimeLimitExpired` (`api4/post.go@v11:1057`): expired when `now > post.create_at + PostEditTimeLimit*1000`.
- `ServiceSettings.PostEditTimeLimit` is in **seconds**. The default is `-1`, meaning unlimited (`config.go@v11:900`, `@v10:820`).
- It is exposed as client config `PostEditTimeLimit` (a string).
- Expired gives **400** `api.post.update_post.permissions_time_limit.app_error`.
- The limit applies to PUT, PATCH, pin and unpin (unpin is exempt when it is a no-op).

### `PUT /api/v4/posts/{post_id}/patch` (use this one)

`patchPost@v11:1191`, `postPatchChecks@v11:1260`.

- **Body:** a PostPatch.
  - **`props` replaces the whole map.** v11 re-adds `from_bot`, `from_webhook`, `from_oauth_app`, `from_plugin` and `silent_notification` (`PreserveIdentityPropsFrom`). v10 does not.
  - `file_ids` changes need `upload_file` for new ids and `edit_file_attachment` whenever the set changes (both versions).
- **Permissions:** the author needs `edit_post`. Anyone else needs `edit_others_posts` (channel-scoped). Both also need the create-post check.
- **Response:** **200** with the prepared Post. A WebSocket `post_edited` event is sent (`data.post` is a JSON string).
- **Errors:**
  - Deleted post: 400 `api.post.update_post.permissions_details.app_error`.
  - System post: 400 `api.post.update_post.system_message.app_error`.
  - Archived channel: 400 `api.post.patch_post.can_not_update_post_in_deleted.error`.
  - Post not found: 403 `edit_post` (the handler masks it).

### `PUT /api/v4/posts/{post_id}` (full update, avoid)

`updatePost@v11:1065`.

- Body `id` must equal the path id, else 400 (`id`).
- A **missing `message` becomes `""`**, and missing `is_pinned` / `has_reactions` become **false**.
- A `null` `file_ids` or `props` keeps the original.
- Permissions: `edit_post` on the channel always, plus `edit_others_posts` when not the author.

### Edit history

- Each edit re-inserts the old version (see `original_id` in §1).
- `GET /api/v4/posts/{post_id}/edit_history` returns `[Post]` ordered `EditAt DESC`. Author only, else 403. 404 when there are none.

### `DELETE /api/v4/posts/{post_id}` (soft delete)

`deletePost@v11:750`, `DeletePost@v11 app:1977`, `Delete@v11 post_store.go:972`.

- **Permissions:** the author needs `delete_post`. Anyone else needs `delete_others_posts`. v11 also has a card-type exception.
- **Response:** **200** `{"status":"OK"}`.
- `?permanent=true` requires `manage_system` and `EnableAPIPostDeletion`, else 501.
- **Effects:** `DeleteAt = UpdateAt = now` and `props.deleteBy = <deleter id>` on the post **and on all rows with `RootId` = that id** (deleting a root deletes the whole thread). The Threads row is updated and the root's `update_at` is bumped.
- **Errors:**
  - Not found or already deleted: 404 `app.post.get.app_error`.
  - Archived channel: 400 `api.post.delete_post.can_not_delete_post_in_deleted.error`.
  - v11 only, restricted DM: 400 `api.post.delete_post.can_not_delete_from_restricted_dm.error`.
- **WebSocket:** exactly one `post_deleted` event, `data.post` as a JSON string.
  - The payload is the **pre-delete snapshot**, so its `delete_at` is **0**. Treat the event itself as the deletion.
  - For a root, also drop its replies locally.
  - No per-reply events are sent.

### Default roles

`role.go@v11:946-1101`:
- `channel_user`: `create_post`, `edit_post`, `delete_post`, `add_reaction`, `remove_reaction`, `upload_file`, `use_channel_mentions`.
- `team_admin`: adds `delete_others_posts`.
- `edit_others_posts` is not granted to channel or team roles by default (**UNVERIFIED**: I did not trace the system-role grant).

---

## 6. Threads

### `GET /api/v4/posts/{post_id}/thread`

`getPostThread@v11:817`, `@v10:760`. Same parameters in both versions. The store layer is `Get` / `getPostWithCollapsedThreads` (`post_store.go@v11:746, 620`).

**Parameters** (note the camelCase):
- `perPage` (int; default 0 = everything; **>200 gives 400**; do not send negative values).
- `fromPost` (id; requires `fromCreateAt`, else 400).
- `fromCreateAt` (ms).
- `fromUpdateAt` (ms; cannot be combined with `fromCreateAt`, 400).
- `direction` (`up` | `down`; any other value gives 400).
- `updatesOnly` (`"true"`; requires `fromUpdateAt`; cannot be combined with `direction=up`).
- `skipFetchThreads`, `collapsedThreads`, `collapsedThreadsExtended` (exact string `"true"`).

**Pagination:**
- `down` means `CreateAt > fromCreateAt OR (CreateAt = fromCreateAt AND Id > fromPost)`, sorted `CreateAt ASC, Id ASC`. `up` is the mirror image.
- With `updatesOnly` the sort is by `UpdateAt`.
- **Always send `direction=down`** together with `fromUpdateAt`:
  - The CRT store path applies `fromUpdateAt` only when `direction=down`.
  - The non-CRT path without a direction means **before** (`<`).
  - The YAML's note "cannot set with direction=down" contradicts the code.
- **`has_next`:** the server fetches `perPage + 1` rows and sets `has_next`. It is present whenever replies were fetched: non-CRT with `skipFetchThreads=false`, and always in CRT.

**What you get:**
- Requested post missing or deleted: 404 `app.post.get.app_error`.
- **Non-CRT:** the requested post (with `reply_count`), then the root plus replies. A reply id works (it resolves to its root).
- **CRT:** the post with thread fields plus rows where `RootId = post_id`. **Pass the root id**: a reply id returns only itself.
- Deleted replies are excluded.
- `ETag` / `If-None-Match` are supported.

**Webapp loop:** `direction=down`, `perPage=60`. Append `order[1...]`. While `has_next`, repeat with `fromCreateAt = last.create_at` and `fromPost = last.id` (`getPaginatedPostThread`, `actions/posts.ts@v11:610`).

### CRT user thread API

`api4/user.go@v11:111-118` (handlers `:3934-4240`), `@v10:103-110` (`:3450-3750`). Identical in both versions. `{user_id}` may be `me`.

**`GET /api/v4/users/{user_id}/teams/{team_id}/threads`**
- **Parameters:**
  - `per_page` (default 60, max 200; 0 means 30).
  - `before` or `after` (thread or root-post id cursor; both together give 400 `api.getThreadsForUser.bad_params`).
  - `since` (uint ms; matches `membership.last_update_at >= since OR last_reply_at >= since`).
  - `deleted`, `unread`, `extended`, `excludeDirect`.
  - `totalsOnly` / `threadsOnly` (both together give 400 `api.getThreadsForUser.bad_only_params`).
  - `page` is ignored.
- **Returns** only **followed** threads in channels you belong to, for that team plus DM/GM threads (unless `excludeDirect`).
- **Order:** `last_reply_at DESC`. With `after` it is **ASC**.
- **Response:** `{total, total_unread_threads, total_unread_mentions, total_unread_urgent_mentions, threads: [ThreadResponse]}`. With `unread=true`, `total` equals `total_unread_threads`.
- **`ThreadResponse`** (`model/thread.go`): `{id, reply_count, last_reply_at, last_viewed_at, participants: [User], post: Post (root, no metadata, may be null), unread_replies, unread_mentions, is_urgent, delete_at}`.

**Other thread endpoints:**
- `GET .../threads/{thread_id}?extended=`: one ThreadResponse. No membership gives 404 `app.user.get_thread_membership_for_user.not_found`.
- `PUT .../threads/{thread_id}/read/{timestamp}`: timestamp in **ms**, `[0-9]+`, 0 gives 400. Returns a ThreadResponse and sends WebSocket `thread_read_changed` with `{thread_id, timestamp, unread_mentions, unread_replies, previous_unread_mentions, previous_unread_replies, channel_id}`.
- `POST .../threads/{thread_id}/set_unread/{post_id}`: also force-follows. Marks the thread read up to `post.create_at - 1`.
- `PUT .../threads/{thread_id}/following` follows and `DELETE` of the same path unfollows. Both return `{"status":"OK"}` and send WebSocket `thread_follow_changed` with `{thread_id, state, reply_count}`.
- `PUT .../threads/read`: marks all threads in the team read. Sends `thread_read_changed` without a `thread_id`.
- New-reply updates arrive as `thread_updated` with `{thread (JSON string of ThreadResponse), previous_unread_mentions, previous_unread_replies}`.

### CRT configuration

- `ServiceSettings.CollapsedThreads` takes `disabled | default_on | default_off | always_on`. The default is **`always_on`** in both versions (`config.go@v11:110-113, 1013`).
- It is exposed as client config `CollapsedThreads`. Non-`disabled` values require `ThreadAutoFollow = true`.
- The user preference is category `display_settings`, name `collapsed_reply_threads`, value `"on"` or `"off"`.
- **Effective rule** (`IsCRTEnabledForUser`, `app/channel.go@v11:3183`):
  - `disabled` means off.
  - `always_on` means on.
  - Otherwise the preference decides when set; if it is not set, `default_on` means on.

---

## 7. Reactions

`api4/reaction.go`, `app/reaction.go`, `model/reaction.go`, `sqlstore/reaction_store.go@v11`.

**Model:** `{user_id, post_id, emoji_name, create_at, update_at, delete_at, remote_id: string|null (no omitempty), channel_id}`. Times are ms.

### `POST /api/v4/reactions`

- **Body:** `{user_id, post_id, emoji_name}`. `create_at` is optional and honored if non-zero.
- **Response:** **200** with a Reaction. The code never calls `WriteHeader`; the YAML's "201" is wrong.
- The operation is idempotent: the database does an upsert.
- **Checks:**
  - Ids valid, name non-empty and ≤ 64 bytes, else 400 `api.reaction.save_reaction.invalid.app_error`.
  - `user_id == session user`, else **403** `api.reaction.save_reaction.user_id.app_error`.
  - `add_reaction` on the post's channel.
  - Name regex `^[a-zA-Z0-9\-\+_]+$`, else 400 `model.reaction.is_valid.emoji_name.app_error`.
- **Emoji lookup:** the name must be a system emoji (`SystemEmojis` in `model/emoji_data.go`, about 4,464 names, e.g. `+1`, `thumbsup`, `+1_medium_skin_tone`). Otherwise it must be an existing custom emoji:
  - Custom emoji disabled: 403 `api.emoji.disabled.app_error`.
  - Unknown name: 404 `app.emoji.get_by_name.no_result`.
- **Limit:** once the post has `UniqueEmojiReactionLimitPerPost` distinct emojis (and this emoji is new), you get 400 `app.reaction.save.save.too_many_reactions`. Default 50, capped at 500 (`config.go@v11:140-142`). Exposed as client config `UniqueEmojiReactionLimitPerPost`.
- Archived channel: 403 `api.reaction.save.archived_channel.app_error`.
- Post deleted: 404 `app.post.get.app_error`.

### `DELETE /api/v4/users/{user_id}/posts/{post_id}/reactions/{emoji_name}`

- The path regex is `[A-Za-z0-9_\-+]+`. Keep `+` literal in the path.
- Permissions: `remove_reaction` (channel), plus system-scope `remove_others_reactions` when the user is not you.
- **Response:** 200 `{"status":"OK"}`. Removing a reaction that does not exist still returns OK and emits the event.

### Reads and events

- `GET /api/v4/posts/{post_id}/reactions` returns `[Reaction]` (non-deleted, ordered by `create_at`). Needs read access to the post. When there are none the body may be `null` (a nil Go slice, **PLAUSIBLE**), so decode optionally.
- Add and remove bump the post's `update_at` and `has_reactions`, so the post shows up in `since` fetches with fresh `metadata.reactions`.
- WebSocket `reaction_added` / `reaction_removed` carry `data.reaction` as a JSON string.

### Version differences

- **v11** lowercases `emoji_name` on both save and delete. **v10** does not: mixed case fails the system lookup. Always send lowercase.
- **v10 only:** `POST /api/v4/posts/ids/reactions` takes a JSON array of post ids and returns `{post_id: [Reaction]}` (empty arrays filled in). It is **removed in v11**.
- v11 adds restricted-DM checks (400 `api.reaction.save.restricted_dm.error` / `api.reaction.delete.restricted_dm.error`) and burn-on-read restrictions.

---

## 8. Pinned and saved (flagged) posts

**Pinned**
- `POST /api/v4/posts/{post_id}/pin` and `/unpin` return 200 `{"status":"OK"}`.
- They need only **read** access to the channel, plus the edit time limit unless the call is a no-op.
- They go through `PatchPost`, so the post's `update_at` is bumped and a `post_edited` event is sent. `edit_at` is unchanged.
- `GET /api/v4/channels/{channel_id}/pinned` returns a PostList with an ETag (`api4/channel.go@v11:1099`).

**Saved**
- Saved posts are stored as preferences:
  - Save: `PUT /api/v4/users/{user_id}/preferences` with `[{user_id, category: "flagged_post", name: <post_id>, value: "true"}]`.
  - Unsave: `POST /api/v4/users/{user_id}/preferences/delete` with the same body.
  - (`flagPost`/`unflagPost` in `actions/posts.ts@v11:596, 1209`.)
- List: `GET /api/v4/users/{user_id}/posts/flagged?team_id=|channel_id=&page=&per_page=` returns a PostList sorted `create_at DESC`, filtered by read permission (`getFlaggedPostsForUser@v11:480`).

---

## 9. Reconciliation, "around", permalinks

**`GET /api/v4/posts/{post_id}`** (`getPost@v11:580`)
- Returns 200 with the prepared Post (priority included) and an `ETag` (`If-None-Match` gives 304).
- Deleted or missing: 404 `app.post.get.app_error`.
- `include_deleted=true` requires `manage_system`.
- On a Cloud plan limit: 403 `app.post.cloud.get.app_error` plus the header `First-Inaccessible-Post-Time: 1`.

**`POST /api/v4/posts/ids`** (`getPostsByIds@v11:636`)
- The body is a JSON array of ids (deduplicated server-side). Empty gives 400 `post_ids`. More than 1000 gives 400 `api.post.posts_by_ids.invalid_body.request_error`.
- Returns a **`[Post]` array, not a PostList**, sorted `create_at DESC`. It **includes deleted posts** (message blanked, `delete_at > 0`), which makes it good for reconciliation.
- Posts in channels you cannot read are silently omitted. If none are found at all: 404 `app.post.get.app_error`.
- Header `First-Inaccessible-Post-Time: <ms>`.

**No "around" endpoint.** There is no `GET /posts/{id}/around` route in either version. The webapp composes it in parallel (`getPostsAround`, `actions/posts.ts@v11:857`):
- `getPostsAfter(id, per_page=30)`, `getPostThread(id)` and `getPostsBefore(id, per_page=30)`.
- The combined order is `[...after.order, id, ...before.order]`, with `next_post_id` from `after` and `prev_post_id` from `before`.

**Post info.** `GET /api/v4/posts/{post_id}/info` returns `{channel_id, channel_type, channel_display_name, has_joined_channel, team_id, team_type, team_display_name, has_joined_team}`. Use it for permalinks into channels you have not joined.

**Permalink format:** `<SiteURL>/<team_name>/pl/<post_id>`.
- Server: `makePostLink` (`app/post.go@v11:3094`). The server detects permalinks with `^[0-9a-z_-]{1,64}/pl/[a-z0-9]{26}$` on the path after SiteURL (`post_metadata.go@v11:846`).
- For DMs/GMs, use the current team's name (webapp behaviour).

---

## 10. v10.11.24 vs v11.11.1 summary

| Area | v10.11.24 | v11.11.1 |
|---|---|---|
| Post types | base set | adds `system_autotranslation`, `system_team_abac_*`, `burn_on_read`, `card`, `system_shared_chan_state` |
| Metadata | embeds/emojis/files/images/reactions/priority/acknowledgements | adds `redacted_file_count`, `translations`, `expire_at`, `recipients` |
| Create | no `silent`. System-type error `api.context.invalid_param.app_error` | `silent` param, API-level system-type error (`invalid_body_param`), restricted-DM, card and burn-on-read checks |
| Channel posts bools | only exact `"true"` | `strconv.ParseBool` |
| Archived channel posts | 403 `api.user.view_archived_channels.get_posts_for_channel.app_error` if `ExperimentalViewArchivedChannels=false` | config forced true, so no check |
| Edit | no identity-prop preservation | preserves `from_*` / `silent_notification`, `mm_blocks_actions` rules, burn-on-read not editable |
| Delete | no restricted-DM check. User WebSocket payload is `json.Marshal` | restricted-DM check. User payload is `ToJSON` (action integrations stripped) |
| Reactions | case-sensitive name, has `POST /posts/ids/reactions` | lowercased, bulk endpoint removed, restricted-DM and burn-on-read checks |
| New routes | – | `POST /posts/rewrite`, `GET /posts/{id}/reveal`, `DELETE /posts/{id}/burn` |
| Same in both | dedup/TTL 30s, pagination SQL semantics, thread parameters, CRT user-thread API, limits (200/1000/16383), config defaults | |

---

## 11. Unverified or uncertain

- Whether dedup works across HA nodes with Redis (`CacheType=redis`). With LRU it is per node.
- `GET /posts/{id}/reactions` returning `null` when empty. This is a sqlx nil-slice inference, not observed.
- Behaviour when the before/after anchor is permanently deleted. Inferred from the SQL: empty result.
- The system-admin grant of `edit_others_posts` (role table not traced).
- The `custom_calls` type name, which belongs to the Calls plugin, not core.
- The `retain_content` parameter that the v11 webapp sends to `GET /posts/{id}`. The v11 `getPost` handler does not read it.
- The YAML `type` filter on channel posts is not implemented in either handler.