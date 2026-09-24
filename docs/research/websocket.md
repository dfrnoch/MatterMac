# MatterMac WebSocket reference for Mattermost v11.11.1 and ESR v10.11.24

I read the source at both tags from sparse clones in `/tmp/mm-research-ws/repo-v11.11.1` and `/tmp/mm-research-ws/repo-v10.11.24`, plus raw copies in `/tmp/mm-research-ws/{v11.11.1,v10.11.24}/`. The following files are **byte-identical at both tags**: `api4/websocket.go`, `platform/websocket_router.go`, `model/websocket_request.go`, `wsapi/{api,status,user,websocket_handler}.go`. `websocket.ts` differs only cosmetically. Everything else that differs is covered in §9.

Line numbers below are for v11.11.1 unless a line gives a v10 number.

---

## 1. Endpoint and query parameters

**Route**
- `GET {SiteURL}/api/v4/websocket`. A trailing `/` is also accepted.
- Registered with `api.BaseRoutes.APIRoot.Handle("/{websocket:websocket(?:\\/)?}", api.APIHandlerTrustRequester(connectWebSocket)).Methods(GET)` in `server/channels/api4/websocket.go` L52-55.
- Handler flags (`web/handlers.go` L568-583): `RequireSession:false`, `TrustRequester:true`, `RequireMfa:false`. So the endpoint has no CSRF or X-Requested-With requirement.
- How the webapp builds the URL (`webapp/channels/src/actions/websocket_actions.ts` L196-246):
  - Use client config `WebsocketURL` if it is set.
  - Otherwise take SiteURL, switch the scheme to ws/wss, add `:WebsocketPort` / `:WebsocketSecurePort` if no port is present, then append `/api/v4/websocket`.
  - A SiteURL subpath is kept.

**Upgrader** (`api4/websocket.go` L58-62)
- `ReadBufferSize = WriteBufferSize = model.SocketMaxMessageSizeKb`, which is **8192 bytes** (`model/websocket_client.go` L21).
- `CheckOrigin = App.OriginChecker()`. No subprotocols, no compression.

**Query parameters** (constants at `api4/websocket.go` L18-26)

| Param | Parsing | Semantics |
|---|---|---|
| `connection_id` | `r.URL.Query().Get` (L99) | If empty, **or the upgrade request itself is unauthenticated**, the server assigns a fresh `model.NewId()` (L100-104). Otherwise it calls `PopulateWebConnConfig` (L106). |
| `sequence_number` | `strconv.ParseInt(v,10,0)` in `PopulateWebConnConfig` (`platform/web_conn.go` L164-197) | **Required whenever `connection_id` is non-empty.** Missing value, non-integer, or a `connection_id` that fails `model.IsValidId` (26 characters) all lead to an error, then `ws.Close()` right after the 101 (raw TCP close, no close frame). Meaning: the **next event seq the client expects**, i.e. last received `seq + 1` (see §4). |
| `posted_ack` | `== "true"` (L81) | Enables `should_ack:true` in `posted` data (`app/web_broadcast_hooks.go` L99-146). Metrics only; the client is then expected to send the `posted_notify_ack` action. The webapp passes `true` (`websocket_actions.ts` L245). **MatterMac should omit it.** |
| `disconnect_err_code` | exact name, underscore after "err" (L22, L86-89) | Accepted only for codes 1000-1016, 4000 (`clientPingTimeoutErrCode`) or 4001 (`clientSequenceMismatchErrCode`). Metrics only. |
| `access_token` | via the generic token parser | See §2. |

The official client's URL: `${url}?connection_id=${connectionId}&sequence_number=${serverSequence}` + `&posted_ack=true` + `&disconnect_err_code=…` (`webapp/platform/client/src/websocket.ts` L208-216). On first connect it sends `connection_id=&sequence_number=0`.

---

## 2. Authentication

**Token parsing at the HTTP upgrade**

`app.ParseAuthTokenFromRequest` (`app/authentication.go` v11 L493-534, v10 L408-449, identical). Precedence order:
1. **Cookie `MMAUTHTOKEN`** (wins over the header).
2. `Authorization: Bearer <tok>`. Prefix compared case-insensitively to `"BEARER"`; the token is `authHeader[7:]`.
3. `Authorization: Token <tok>` (lowercased prefix `token`, OAuth).
4. Query `?access_token=`.
5. Cloud and remote-cluster headers.

**Handling in `web/handlers.go` L277-309**
- Valid token: the session is attached.
- **Invalid or expired token: no error**, because `RequireSession` is false. The upgrade proceeds **unauthenticated**.
- `?access_token=` with a non-OAuth session: **HTTP 401** `api.context.token_provided.app_error`, no upgrade.
- If the rate limiter is enabled, a per-user limit can refuse the upgrade.

**Origin check** (`app/server.go` v11 L1279, v10 L1144)
- No `Origin` header: allowed.
- `Origin: null`: rejected.
- Otherwise the Origin host and scheme must equal SiteURL's, or be in `AllowCorsFrom`.
- A failure produces a gorilla-written **HTTP 403** (gorilla v1.5.3 `server.go` L153). Other bad handshakes produce 400, or 405 for non-GET.

**Recommendation:** use `Authorization: Bearer <token>` on the upgrade request and **disable cookie handling on that request**. A stale `MMAUTHTOKEN` cookie silently overrides a valid header.

**`authentication_challenge`** (`platform/websocket_router.go` L39-80)

Request:
```json
{"seq":1,"action":"authentication_challenge","data":{"token":"<session or PAT token>"}}
```

- If the connection already has a session token (because the header or cookie auth succeeded), it **returns silently with no response**. Do not wait for a reply if you used header auth.
- If `data.token` is missing or not a string: `conn.WebSocket.Close()`, a raw TCP close.
- If `GetSession(token)` fails: warning logged and raw close.
- On success:
  1. `SetSession`, `SetSessionToken`, `UserId` set.
  2. `HubRegister`. This enqueues `hello` because `reuseCount==0`.
  3. Asynchronously `SetStatusOnline(user,false)` and `UpdateLastActivityAtIfNeeded`.
  4. Replies `{"status":"OK","seq_reply":1}`.
- Order on the wire: **`hello` (seq 0) first, then the OK response.**
- **Resume is impossible with challenge auth.** At upgrade time `Session().UserId==""`, so a new `connection_id` is always generated (`api4/websocket.go` L100). Resume needs header or cookie auth.

**While unauthenticated**
- The connection is **not registered in the hub**. Every response sent via `hub.SendMessage` is dropped: the `directMsg` handler checks `connIndex.Has(conn)` (`web_hub.go` L700-703).
- It receives nothing. Actions other than the challenge are rejected with `api.web_socket_router.not_authenticated.app_error` (401), but that error cannot be delivered either.
- `presence` is processed before the auth check (router L82-107); its reply is also dropped.
- A **binary frame before auth** causes an immediate close (`web_conn.go` L470-474).
- **Auth deadline:** `authTicker` with `authCheckInterval = 5s` (`web_conn.go` L40, L631-637). At the first tick, if no session token is set, `writePump` returns and the socket closes with no close frame (client sees 1006). Authenticated connections stop the ticker.

**Mid-session failure**
- `IsBasicAuthenticated` (L782-808) re-fetches the session once `sessionExpiresAt < now` or the cache is invalidated. If the fetch fails, the token is cleared.
- From then on `ShouldSendEvent` is false: **events silently stop and the socket is not closed.**
- The `ping` action then returns FAIL with id `api.web_socket_router.not_authenticated.app_error` and `status_code:401`. Use that to detect revocation.
- **v11 only:** `IsAuthenticated = IsBasicAuthenticated && IsMFAAuthenticated` (L811-827). `Suite.MFARequired`: if MFA is licensed, enabled and enforced, and the email/LDAP user lacks active MFA, no events are delivered. v10 has only the session check.

---

## 3. Envelopes and counters

**Client to server** (`model/websocket_request.go` L18-28)
```json
{"seq": <int64 > 0>, "action": "<string>", "data": <object | null | omitted>}
```
- Decoded with `json.Decoder` for text frames, or msgpack for binary frames (post-auth only) (`web_conn.go` L476-488).
- **Any decode error closes the socket.** Examples: `data` sent as an array or string, or `seq` sent as a string.
- `seq <= 0` returns error `api.web_socket_router.bad_seq.app_error` (400), whose `seq_reply` is **omitted** (`omitempty` of 0).
- Empty action returns `api.web_socket_router.no_action.app_error` (400).
- Unknown action returns `api.web_socket_router.bad_action.app_error` (**500**) (router L27-37, L115-120).
- Actions prefixed `custom_` go to plugins only; the server core sends no response (`web_conn.go` L492).

**Action response** (`model/websocket_message.go` L445-462; the envelope is not an event: no `event`, no `seq`)
```json
{"status":"OK","seq_reply":N,"data":{...}}
{"status":"FAIL","seq_reply":N,"error":{"id":"…","message":"…","detailed_error":"","status_code":400}}
```
- `seq_reply` and `data` are omitempty; `error` is an AppError, whose `request_id` and `status_code` are omitempty.
- `detailed_error` is wiped (router L143, handler L46/L68).
- Actions with nil data reply `{"status":"OK","seq_reply":N}`.

**Server event** (`webSocketEventJSON` L234-239; precomputed form L403-413)
```json
{"event": "posted", "data": {...}, "broadcast": {...}, "seq": 12}
```
- Precomputed events have spaces after the colons. Directly encoded events (hello) have a trailing `\n`. Parse generically.
- Broadcast JSON (L148-172): `omit_users` (object `{userId:true}` or `null`), `user_id`, `channel_id`, `team_id`, `connection_id`, `omit_connection_id` (always present, possibly `""`). Plus omitempty `contains_sanitized_data`, `contains_sensitive_data`, and v11-only `required_permissions` (string array).
- Hooks (`broadcast_hooks`, `broadcast_hook_args`) are stripped before sending (`web_hub.go` L721).

**Classifying incoming frames**
- Has `event`: it is an event.
- Else has `status`: it is a response.
- The webapp uses `if (msg.seq_reply)` (`websocket.ts` L352), which misclassifies a response whose `seq_reply` was omitted. Always send `seq >= 1`.

**Counters**
- Client `seq` and server `seq` are **independent**.
- **Server seq is per WebConn (per `connection_id`):**
  - It starts at **0 with `hello`**.
  - It is incremented only for events actually encoded in `writePump` (L583-587). Responses do not consume seq.
  - In v11, rejected events (`IsRejected`, L577-579) are skipped before numbering.
  - Events dropped by `ShouldSendEvent` never get a seq.
  - It is preserved across a successful resume and reset to 0 on a failed resume.
  - Edge case: an encode error still increments `wc.Sequence` (L585-592), creating a gap. The client then reconnects and resyncs.
- The webapp resets its action seq to 1 on every close (`responseSequence = 1`) and starts at 1.
- **Recommendation: keep MatterMac's action seq monotonic across reconnects.** On resume the old send queue, including **unsent responses to old requests**, is reattached (`PopulateWebConnConfig` L189). An old `seq_reply:1` could otherwise be mistaken for the new `seq:1`.

---

## 4. `hello`, resume, and the dead queue

**`hello`** (`createHelloMessage`, `web_conn.go` L829-851)
- Broadcast `user_id = <me>`. Data:
  - `server_version`: string `"<CurrentVersion>.<BuildNumber>.<ClientConfigHash>.<ee bool>"`, where `ee = LicenseManager()!=nil`, e.g. `"11.11.1.<build>.<hash>.true"`.
  - `connection_id`: string (26 characters).
  - `server_hostname`: string. **Omitted** if `os.Hostname()` fails.
- `seq: 0`.

**When `hello` is sent**
1. **Hub register with `reuseCount==0`** and a basic-authenticated session (`web_hub.go` L599-605; v10 L588 uses `IsAuthenticated()`). Covers fresh connections, unknown connection IDs (server restart, reaped connection), and challenge auth.
2. **In `writePump` when the resume is lossy** (L535-552): clear the dead queue, `SetConnectionID(model.NewId())`, `Sequence = 0`, write `hello` directly, then continue with queued events (seq 1, 2, …).

**Resume path**
1. `PopulateWebConnConfig` calls `CheckWebConn(userId, connId, seq)` (`web_hub.go` L280-365). Single node, or `seq==0`: `hub.CheckConn`. HA: cluster `GetWSQueues`.
2. `CheckConn` → `RemoveInactiveByConnectionID` (L1017-1029) **matches only connections with `Active==false`**. If the server has not yet noticed the old socket died (half-open TCP, unregister not processed yet), the lookup fails and you get a new ID and `hello`.
3. Not found: new `connection_id`, `seq=0`, `reuseCount=0`, `hello`.
4. Found: reuse the old active queue (`chan`, size **256**), dead queue, dead-queue pointer, and `reuseCount+1`; `Sequence = client sequence_number`; no hub `hello`.
5. `writePump` decision (L526-558), only when `wc.Sequence != 0`:
   - **`isInDeadQueue(seq)`**: an event with exactly that seq was previously written. Replay from it to the end with the original seq numbers (`drainDeadQueue` L739-771). Metric `"success"`.
   - **Else if not `_hasMsgLoss`**: the last dead-queue element's seq equals `seq-1`, so the client is fully caught up. **Nothing is sent, no `hello`.** Metric `"lossless"`.
   - **Else** (seq older than the ring, or ahead of the server): new `connection_id` and `hello` (seq 0). Metric `"failure"`.
   - Then the retained active-queue backlog (events queued while disconnected, plus unsent responses) flows with continuing seqs.
6. Edge case: sending a non-empty `connection_id` with `sequence_number=0` skips all of the above and restarts numbering at 0 without a `hello`, corrupting the ring. **Never send a non-empty `connection_id` with `sequence_number=0`.**

**Constants** (`web_conn.go` L33-44; `web_hub.go` L23-26; identical at both tags)

| Constant | Value |
|---|---|
| `deadQueueSize` | 128 (events actually written to the socket) |
| `sendQueueSize` | 256 |
| `sendSlowWarn` | 128 (50%); at or above this, `typing`, `status_change`, `multiple_channels_viewed` are dropped |
| `sendFullWarn` | 243 (log only) |
| `broadcastQueueSize` | 4096 |
| `inactiveConnReaperInterval` | 5 min |
| `webConnMemberCacheTime` | 30 min |

**Resume window**
- An inactive connection is deleted on the 5-minute reaper tick if `now − lastUserActivityAt > 5 min` (L1033-1040). The effective window is therefore about 0 to 10 minutes depending on how recently the user was active.
- If more than 256 events queue up while disconnected, `closeAndRemoveConn` removes the connection (L730-740), and resume is impossible.

**Official client detection** (`websocket.ts` v11 L350-424, v10 L349-423)
- On a `hello` event, when missed-message listeners exist: if the stored `connectionId !== ''` and differs from `msg.data.connection_id`, call the missed-message listeners and set `serverSequence=0`. Always store `connectionId` and `serverHostname`.
- Then for every event: if `msg.seq !== serverSequence`, synthesise close **4001**, set `connectFailCount=0`, close, and run `onclose` immediately, which reconnects with the same `connection_id` and `sequence_number` so the server replays. Else `serverSequence = msg.seq + 1`.
- `onopen` (L272-338): if a token was given, send `authentication_challenge`. If `connectFailCount>0`, call **reconnect listeners** (on every reopen, before `hello` arrives); else call first-connect listeners.
- Webapp listeners (`websocket_actions.ts` L240-243, L267-360):
  - `reconnect()` does a **full REST resync on every reconnect, even a successful resume**: teams/channels, channel members, categories, `syncPostsInChannel(current, lastPost.create_at)`, team unreads, thread sync since `newest last_reply_at`, then re-sends `presence` channel and team.
  - The missed-message listener `restart()` runs `reconnect()` again plus `getClientConfig()`.

**Deterministic resume detection for MatterMac (derived from the code)**
- Send the `ping` action immediately on open.
- **If `hello` arrives before the ping response**, it is a new connection. If the old ID was non-empty and differs, do a full resync.
- **If the ping response arrives with no `hello` first**, the resume succeeded. Any replayed events came first: the dead-queue drain precedes the send loop, and in the fresh case `hello` is enqueued at register time, before `readPump` starts.

**Reconnect backoff** (`websocket.ts` L27-36, L245-268)
- Base 3000 ms plus random jitter of 0-2000 ms.
- Once more than 7 consecutive failures have occurred: `3000 × n²` ms, capped at 300000 ms.
- The webapp also reconnects on the browser `online` event and pings on `offline`.

---

## 5. Liveness

**Server** (`web_conn.go` L37-40, L444-461, L616-626)

| Constant | Value | Effect |
|---|---|---|
| `writeWaitTime` | 30 s | Per-write deadline |
| `pongWaitTime` | 100 s | Read deadline, reset **only by a pong** (`SetPongHandler`). Received data frames or client pings do **not** extend it. |
| `pingInterval` | 60 s | Server sends **WebSocket protocol Ping frames** (empty payload) every 60 s |
| `authCheckInterval` | 5 s | See §2 |

- Each pong also triggers `SetStatusAwayIfNeeded(user,false)` (see §7).
- If no pong arrives within 100 s of the last one (the first deadline is connect + 100 s), `NextReader` times out and the socket closes with a raw TCP close.
- Client-sent protocol pings get an automatic pong from gorilla's default ping handler (gorilla v1.5.3 `conn.go` L1158-1170), but they do not extend the server's deadline.

**`ping` action** (`wsapi/system.go` L16-24, identical at both tags; requires auth)
- Request: `{"seq":N,"action":"ping"}`. The webapp sends no `data`.
- Response: `{"status":"OK","seq_reply":N,"data":{"text":"pong","version":"11.11.1"|"10.11.24","server_time":<Unix ms int64>,"node_id":""}}`. `node_id` is always `""`.
- The handler first re-validates the session with `GetSession(conn.GetSessionToken())` (`websocket_handler.go` L35-50).

**Official client** (`websocket.ts` L24-36, L289-335, L585-598)
- `clientPingInterval: 30000`. It pings immediately on open.
- On each 30 s tick: if the previous ping is still unanswered, stop the interval, synthesise close **4000**, and reconnect. Otherwise send a new ping.
- Detection latency after a loss is at most about 60 s.

**Go SDK client** (`model/websocket_client.go` L354-392): expects a server Ping at least every 60 + 5 s (`PingTimeoutBufferSeconds`).

**Inbound size limit**
- `SetReadLimit(model.SocketMaxMessageSizeKb)`: **8192 bytes per client message** (L444).
- Exceeding it: gorilla sends close **1009** and the connection drops (`conn.go` L924-925).
- Practical consequence: `get_statuses_by_ids` holds roughly 270 IDs at most per message.

**Server close behaviours**
- Close frame with an empty payload (client sees 1005): send queue closed after overflow.
- 1009: oversize client message.
- Raw TCP close, no close frame: auth timeout, bad challenge, decode error, `PopulateWebConnConfig` error, pong timeout, hub stop or shutdown, binary frame before auth.

---

## 6. Events

**Full constant list, `model/websocket_message.go` v11.11.1 L16-125:**
typing, posted, post_edited, post_deleted, post_unread, channel_converted, channel_created, channel_deleted, channel_restored, channel_updated, channel_member_updated, channel_scheme_updated, direct_added, group_added, new_user, added_to_team, leave_team, update_team, delete_team, restore_team, update_team_scheme, user_added, user_updated, user_role_updated, memberrole_updated, user_removed, preference_changed, preferences_changed, preferences_deleted, ephemeral_message, status_change, hello, authentication_challenge, reaction_added, reaction_removed, response, emoji_added, multiple_channels_viewed, plugin_statuses_changed, plugin_enabled, plugin_disabled, role_updated, license_changed, config_changed, open_dialog, guests_deactivated, user_activation_status_change, received_group, received_group_associated_to_team, received_group_not_associated_to_team, received_group_associated_to_channel, received_group_not_associated_to_channel, group_member_deleted, group_member_add, sidebar_category_created, sidebar_category_updated, sidebar_category_deleted, sidebar_category_order_updated, cloud_subscription_changed, thread_updated, thread_follow_changed, thread_read_changed, first_admin_visit_marketplace_status_received, draft_created, draft_updated, draft_deleted, post_acknowledgement_added, post_acknowledgement_removed, persistent_notification_triggered, hosted_customer_signup_progress_updated, channel_bookmark_created, channel_bookmark_updated, channel_bookmark_deleted, channel_bookmark_sorted, channel_access_control_updated, team_access_control_updated, presence, posted_notify_ack, scheduled_post_created, scheduled_post_updated, scheduled_post_deleted, custom_profile_attributes_field_created, custom_profile_attributes_field_updated, custom_profile_attributes_field_deleted, custom_profile_attributes_values_updated, content_flagging_report_value_updated, job_updated, recap_updated, post_translation_updated, post_revealed, post_burned, burn_on_read_all_revealed, board_created, view_created, view_updated, view_deleted, view_sorted, property_field_created, property_field_updated, property_field_deleted, property_values_updated, file_download_rejected, file_upload_rejected, show_toast, shared_channel_remote_updated, channel_join_request_created, channel_join_request_updated. Plugin events use the form `custom_<pluginid>_<event>`.

**v10.11.24 differences (85 constants):**
- v10 has 2 that v11 lacks: `channel_viewed` (defined but **never emitted** at either tag; only `multiple_channels_viewed` is used) and `cloud_payment_status_updated`.
- v10 lacks these 24: board_created, burn_on_read_all_revealed, channel_access_control_updated, channel_join_request_created/updated, content_flagging_report_value_updated, file_download/upload_rejected, job_updated, post_burned, post_revealed, post_translation_updated, property_field_created/updated/deleted, property_values_updated, recap_updated, shared_channel_remote_updated, show_toast, team_access_control_updated, view_created/updated/deleted/sorted.
- The API docs (`api/v4/source/introduction.yaml` L240-290) are stale: they list `channel_viewed` and `dialog_opened`; the real name is `open_dialog`.

**How to read the delivery filter** (`ShouldSendEvent`, `web_conn.go` L885-1035), in order:
1. Must be authenticated.
2. Queue backpressure drops (typing, status_change, multiple_channels_viewed).
3. Sanitized/sensitive split: normal users get the `contains_sanitized_data` copy; users with `manage_system` get the `contains_sensitive_data` copy. In v11, `required_permissions` must all be held.
4. `connection_id` set: only that connection. `omit_connection_id` matching: skip.
5. **`user_id` set: only that user** (takes precedence over channel and team).
6. `omit_users` contains the recipient: skip.
7. `channel_id` set: must be a channel member.
8. `team_id` set: must be a team member.
9. Guests: `user_updated` and `new_user` are visibility-filtered.

Scope names in the table below: "self" means `broadcast.user_id` is the recipient; "chan" means channel members; "team" means team members; "all" means everyone.

Types in the table: STR means a JSON-encoded **string** inside `data`; decode it a second time. `ms` means Unix milliseconds (int64).

| event | scope | data | source (v11) |
|---|---|---|---|
| hello | self | server_version, connection_id, server_hostname? | web_conn.go L829 |
| posted | chan | `post` STR(Post), `channel_type` ("O"/"P"/"D"/"G"), `channel_display_name`, `channel_name`, `sender_name`, `team_id` ("" for DM/GM), `set_online` bool, `otherFile`: **string `"true"`** (only if the post has files), `image`: **string `"true"`** (only if a file is an image), `mentions` STR([only *your* id], present only if you are mentioned), `followers` STR([only your id], CRT followers receiving a desktop notification), `should_ack` bool (only with posted_ack). The TS types say bool for otherFile/image, but the server sends strings. | notification.go L691-731; post.go L1096-1152; web_broadcast_hooks.go L47-87 |
| post_edited | chan | `post` STR | post.go L1057. Also emitted after post acknowledgement changes (post_acknowledgements.go L345, both tags) and for shared-channel attachment sync and content flagging (v11) |
| post_edited (ephemeral) | self + channel_id | `post` STR | post.go L807 |
| post_deleted | chan, 2 copies | non-admin: `post` STR; sysadmin: `post` STR, `delete_by` (user id). The post snapshot is taken **before** deletion, so `delete_at` is likely 0: treat the event itself as the deletion. | post.go L3409-3419 (v10 L2841-2850) |
| post_deleted (ephemeral) | self | `post` STR (id, user_id, type `system_ephemeral`, delete_at, update_at) | post.go L841 |
| post_unread | self (+team_id, channel_id) | msg_count, msg_count_root, mention_count, mention_count_root, urgent_mention_count (int64), last_viewed_at ms, post_id | channel.go L3368-3376 |
| ephemeral_message | self + channel_id | `post` STR | post.go L773, L2925 |
| reaction_added / reaction_removed | chan (presence-scoped, see §7) | `reaction` STR `{user_id,post_id,emoji_name,create_at,update_at,delete_at,remote_id,channel_id}` | reaction.go L175-189 |
| post_acknowledgement_added / _removed | chan | `acknowledgement` STR | post_acknowledgements.go L239-249 |
| typing | chan, omit_users {sender:true} (presence-scoped, droppable) | `parent_id` ("" means root), `user_id` | user.go L2899-2908 (v10 L2629) |
| status_change | **self only** | `status` ("online"/"away"/"dnd"/"offline"/"ooo"), `user_id` | platform/status.go L205-214 (identical in v10) |
| multiple_channels_viewed | self | `channel_times`: object `{channel_id: ms}`. Gated by ServiceSettings.EnableChannelViewedMessages (default true); droppable. | channel.go L3593/3653/3716 (v10 L3259) |
| channel_created | self (creator only) | channel_id, team_id | channel.go L203 |
| channel_updated | chan | `channel` STR(Channel); or, in the shared-channel variant, team-scoped `channel_id` only | channel.go L830; platform/services/sharedchannel/service.go L291/306 |
| channel_deleted | team if open, else chan | channel_id, delete_at ms | channel.go L1834-1842, L3798-3806 |
| channel_restored | team if open, else chan | channel_id | channel.go L1002-1009 |
| channel_converted | team | channel_id, channel_type | channel.go L934-937 |
| channel_scheme_updated | chan | (none) | channel.go L1262 |
| channel_member_updated | self | `channelMember` STR(ChannelMember: channel_id, user_id, roles, last_viewed_at, msg_count, mention_count, mention_count_root, urgent_mention_count, msg_count_root, notify_props, last_update_at, scheme_*, explicit_roles, autotranslation_disabled) | channel.go L1652, L1681, L4077, … |
| direct_added | chan | creator_id, teammate_id | channel.go L438 |
| group_added | self + channel_id (one per member) | `teammate_ids` STR(string[]) | channel.go L555-562 |
| user_added | (a) chan with omit_users {added}; (b) self + channel_id to the added user | user_id, team_id. **The channel id is only in `broadcast.channel_id`.** JoinDefaultChannels sends only a channel-scoped copy without the omit (L108). | channel.go L1980-1987 |
| user_removed | (a) chan: user_id, remover_id; (b) self (removed user): channel_id, remover_id | — | channel.go L3092-3101 |
| added_to_team | self | team_id, user_id | team.go L889, L1158, L1187 |
| leave_team | team with omit {user}, plus a self copy | user_id, team_id | teams/teams.go L246-257 |
| update_team / delete_team / restore_team / update_team_scheme | team | `team` STR (sanitized) | team.go L336-347 |
| memberrole_updated | self | `member` STR(TeamMember) | team.go L527 |
| user_updated | all with omit {user}, split sanitized/sensitive, plus a self copy | `user`: **object** (not a string) | user.go L1507-1537, L1062, L2924 |
| user_role_updated | self | user_id, roles (space-separated) | user.go L2125 |
| new_user | all (guests filtered) | user_id | user.go L416 |
| preferences_changed / preferences_deleted | self | `preferences` STR(Preference[]) | preference.go L70-75, L112-117 |
| preference_changed | self (only from `/expand` and `/collapse`) | `preference` STR | slashcommands/command_expand_collapse.go L78 |
| sidebar_category_updated | self (+team) | `updatedCategories` STR; the variant emitted on preference save has **no data** | channel_category.go L148; preference.go L66/108 |
| sidebar_category_created / _deleted / _order_updated | self + team | category_id; `order` (string[]) | channel_category.go L116/281/136 |
| thread_updated | self + team (CRT) | `thread` STR(UserThread), previous_unread_mentions, previous_unread_replies (int64) | notification.go L771/L1045; channel.go L3352; user.go L3183 |
| thread_read_changed | self + team, or self + channel_id | Variant A `{}` (mark all read in team); B `{timestamp ms}`; C `{thread_id, timestamp, unread_mentions, unread_replies, previous_unread_mentions, previous_unread_replies, channel_id}` | user.go L3119, L3281-3289; channel.go L3607/3669/3728 |
| thread_follow_changed | self + team | thread_id, state (bool), reply_count | user.go L3144 |
| emoji_added | all | `emoji` STR | emoji.go L89 |
| config_changed | all | `config`: object (client config) | platform/service.go L476 |
| license_changed | all | `license`: object | platform/service.go L492 |
| draft_created / draft_deleted | self + channel_id, omit_connection_id | `draft` STR. **Ignore both** (they come from the user's other clients). `draft_updated` is defined but has no emitter in server/channels. | draft.go L91, L187 |
| persistent_notification_triggered | self + team + channel | post STR, channel_type, channel_display_name, channel_name, sender_name, team_id, otherFile/image "true", `mentions` STR of **all** desktop recipients | post_persistent_notification.go L387-413 |
| scheduled_post_* | self, omit_connection_id | `scheduledPost` STR | scheduled_post.go L163 |
| open_dialog | self | `dialog` STR | integration_action.go L327 |
| role_updated | team, chan, or all | `role` STR | role.go L286 |
| user_activation_status_change, guests_deactivated | all | (none) | api4/user.go L1853; user.go L1332 |

In v11, `posted`/`post_edited` post payloads are **per-recipient** (`web_broadcast_hooks.go`): permalink embeds only if the recipient can read the channel, `channel_mentions` prop filtered, ABAC file redaction (`metadata.redacted_file_count`), and burn-on-read masking. v10 has only the permalink hook. No `posted` event is emitted for archived channels (`notification.go` L46-48).

---

## 7. Presence and status

**Setting online and offline**
- An authenticated connect calls `SetStatusOnline(user, manual=false)` and `UpdateLastActivityAtIfNeeded` (`web_conn.go` L203-208; router L67-70 for the challenge path). This is a no-op if the current status is manual or `EnableUserStatuses` is false. A `status_change` is broadcast (to self) only if the status changed (`status.go` L297-353).
- When the last active connection of the user (cluster-wide) unregisters: `QueueSetStatusOffline`, batched at 500 ms (`web_hub.go` L618-645). A reconnect can therefore flap offline → online.

**Setting away**
- Every pong (about every 60 s) calls `SetStatusAwayIfNeeded(false)`.
- The status becomes away if `now − status.LastActivityAt >= TeamSettings.UserStatusAwayTimeout × 1000`, default 300 s (`status.go` L475-510, L588).
- `LastActivityAt` is refreshed by `SetStatusOnline`, which runs on: WS connect or auth, `POST /api/v4/posts` (query `set_online`, default true, `api4/post.go` L143-186), `user_update_active_status{true}`, and manual status APIs.

**`user_update_active_status`** (`wsapi/user.go` L44-63)
```json
{"seq":N,"action":"user_update_active_status","data":{"user_is_active":true,"manual":false}}
```
- `user_is_active` is a required bool (otherwise 400 `api.websocket_handler.invalid_param.app_error`).
- `true` → `SetStatusOnline(manual)`.
- `false` → `SetStatusAwayIfNeeded(manual)`. **`manual:true` forces a manual away. Always send `false`.**
- In the webapp it is sent only when running inside the Desktop App (`components/logged_in/logged_in.tsx` L89, L163-171).
- **MatterMac should send it on idle and active transitions, like the Desktop App.** Without it the user decays to away about 5 minutes after connecting or last posting.

**`posted.set_online`**
- It is false for auto-responder posts, and for posts created with `set_online=false` (for example, push-notification replies).
- The webapp locally marks the sender online if it is true and the sender's status isn't manual (`websocket_actions.ts` L1050-1063).

**`user_typing`** (`wsapi/user.go` L16-42)
```json
{"seq":N,"action":"user_typing","data":{"channel_id":"<26 chars>","parent_id":"<root id or ''>"}}
```
- Extends session expiry if needed. Needs `create_post` permission, otherwise 400 invalid_param `channel_id`. Returns 503 `api.websocket_handler.server_busy.app_error` when the server is busy. Reply: `{"status":"OK","seq_reply":N}`.
- It does **not** change status.
- Throttle client-side to at least the `TimeBetweenUserTypingUpdatesMilliseconds` client config value (default 5000). `EnableUserTypingMessages` is client config only.

**Other users' statuses are not pushed.** `status_change` goes only to the user whose status changed, at both tags. Get others' statuses one of two ways:
- WS `get_statuses_by_ids` `{"user_ids":[…]}` → `data` is `{user_id: status}`. Missing users come back as `"offline"`. An empty or invalid list returns 400 invalid_param `user_ids` (`wsapi/status.go` L21-34; `platform/status.go` L77-132).
- REST `POST /api/v4/users/status/ids`, which is what the webapp polls, batching at the `UsersStatusAndProfileFetchingPollIntervalMilliseconds` interval (default 3000).
- Avoid `get_statuses`: it returns **all** non-offline cached statuses on the server.

**`presence` action** (router L82-107): data `{channel_id?}`, `{team_id?}`, `{thread_channel_id, is_thread_view}` → OK. It only affects filtering of typing and reaction events (`web_conn.go` L982-991, L1037-1044):
- An event is filtered only if the connection has a channel set that doesn't match **and** both the RHS-thread and thread-view channel IDs are set and don't match.
- Initially all three are unset (`"<>"`), so everything is delivered.
- v10 applies this filter only when `FeatureFlags.WebSocketEventScope` is on (default true); v11 always applies it.
- **Recommendation: don't send `presence`**, so reactions and typing stay unscoped for the local cache.

**`posted_notify_ack`**: metrics only. Skip it.

**`Connection-Id` HTTP header** (`model.ConnectionId`, `client4.go` L51): send it on REST calls so events carrying `omit_connection_id` (drafts, bookmarks, scheduled posts, views, property fields) are not echoed back to MatterMac.

**Registered actions (complete list):**
- Router built-ins: `authentication_challenge`, `presence`.
- wsapi: `ping`, `posted_notify_ack` (`system.go`), `user_typing`, `user_update_active_status` (`user.go`), `get_statuses`, `get_statuses_by_ids` (`status.go`).

---

## 8. Outbound size

- There is **no server cap** on outbound event size. gorilla's server fast path writes each message as a **single unfragmented frame** (`conn.go` L758-771).
- Payloads can be large: `config_changed` carries the full client config, and post props allow up to `PostPropsMaxRunes = 800000`.
- Queue limits: `sendQueueSize` 256; when the queue is full the connection is closed and removed (§4).

---

## 9. v10.11.24 vs v11.11.1

1. **Authentication:** v11 adds the MFA-enforcement check to `IsAuthenticated`. The pong handler and hub `hello` use `IsBasicAuthenticated` in v11 versus `IsAuthenticated` in v10 (equivalent there).
2. **Rejected events:** v11 drops rejected events (burn-on-read reaction hook, ABAC strip failure) before assigning a seq.
3. **Broadcast field:** v11 adds `required_permissions` (omitempty) to the broadcast JSON and filter.
4. **Typing/reaction scoping:** unconditional in v11; behind `WebSocketEventScope` (default true) in v10 (`web_conn.go` v10 L944).
5. **Broadcast hooks:** v11 has 9 (channel mentions, burn-on-read, ABAC files, only channel admins); v10 has 4 (add_mentions, add_followers, posted_ack, permalink). The `posted` field set is otherwise identical.
6. **Event constants:** see §6. `channel_viewed` is only a (dead) constant in v10.
7. **`thread_read_changed` emitters:** v11 adds the team "mark all read" path (`MarkTeamChannelsAndThreadsViewed`), which emits `{timestamp}` team-scoped and extra `multiple_channels_viewed`.
8. **Other differences:** `ping.version` string differs. `websocket.ts` and the router, `api4/websocket.go` and wsapi logic are identical. Dead-queue, resume and liveness constants are identical.

---

## 10. Unverified items

- `URLSessionWebSocketTask` default `maximumMessageSize` is 1 MiB; raise it to 16 MiB or more. Not checked against Apple docs.
- `URLSessionWebSocketTask` replying to server Ping frames automatically. **Required:** without pongs the server drops the socket after 100 s.
- Whether `URLSessionWebSocketTask` sends an `Origin` header. If it does, it must match SiteURL.
- HA cluster `GetWSQueues` resume behaviour (`platform/websocket_reliable.go`): not traced in depth.
- Desktop App idle thresholds for `user_update_active_status`: the Desktop App repo was not read.
- Whether plugins emit `draft_updated` or other core events.
- Exact `channel_display_name` and `sender_name` formatting for DM and GM channels (`notification.GetChannelName` / `GetSenderName` not traced).