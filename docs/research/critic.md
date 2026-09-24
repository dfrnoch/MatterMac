# Errata and additions for the MatterMac research notes

I checked the notes against the pinned source (`v11.11.1`, with `v10.11.24` where it matters) and ran small probes on this machine (Xcode 27.0 27A266a, Swift 6.4). Sources and test programs are in `/tmp/critic/`. The probes did not modify the application sources.

Verdicts: **CONFIRMED** (source or test matches the note), **CORRECTED** (partly wrong or incomplete, fixed here), **REFUTED** (wrong), **RESOLVED** (a note marked it UNVERIFIED and I settled it), **GAP** (the notes don't cover it; filled here), **PLAUSIBLE** (inferred, not fully traced).

---

## 1. Login, MFA, auth headers

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| A1 | The login response carries a `Token` header and returns 200, not 201. | CONFIRMED | `app/login.go` `DoLogin` calls `w.Header().Set(model.HeaderToken, session.Token)`. `model/client4.go` L32 defines `HeaderToken="token"` and L34 `HeaderBearer="BEARER"`. `api4/user.go` `login` (L2125) encodes the body with no `WriteHeader`. Read the header with `HTTPURLResponse.value(forHTTPHeaderField:"Token")`. It is case-insensitive; don't index `allHeaderFields` directly, because HTTP/2 lowercases names. |
| A2 | The MFA ids, and the rule that the code must be "exactly 6 digits". | CORRECTED | `CheckUserMfa` (`app/authentication.go` L357-375) returns `mfa.validate_token.authenticate.app_error` as 400, and `authenticateUser` L464/L486 rewrites it to 401. `api.user.check_user_mfa.bad_code.app_error` is 401. The code rule comes from dgoogauth@5a805980 `Authenticate`: a 6-digit value is checked as TOTP (WindowSize 3, so ±30 s). **An 8-digit value whose first digit is 1-9 goes to the scratch-code path and returns `bad_code`, not `validate_token`.** Anything else (empty, malformed, contains a non-digit) returns `validate_token`. The token is `TrimSpace`d first. |
| A3 | Retrying with the same TOTP code. | GAP | `mfa.ValidateToken` saves `DisallowReuse`. `GetMfaUsedTimestamps` (`sqlstore/user_store.go` L580) returns a non-nil slice, so reuse is always enforced. If a login succeeded on the server but the response was lost, **a retry with the same code gets 401 `bad_code`**, and in v11 that attempt counts as a failure (the slot is kept because `mfaToken != ""`). The UI should ask for the next code. |
| A4 | An MFA probe without a token doesn't count as a failed attempt. | CONFIRMED | v11 `CheckPasswordAndAllCriteria` L110-165: `TryIncrementFailedPasswordAttempts`, then `DecrementFailedPasswordAttempts` if `mfaToken==""`. v10 L80-108 increments only when `mfaToken != ""`. |
| A5 | `ldap_only` is unused. | CONFIRMED | It is passed into `AuthenticateUserForLogin` and never read. |
| A6 | v11 validates `device_id`; v10 doesn't. | CONFIRMED | v11 `DoLogin` uses `IsValidStandardDeviceId` / `IsValidVoIPDeviceId` and returns 400, which the login handler masks to 401. v10 `DoLogin(…, deviceID string, …)` has no check. |
| A7 | Masked-error list and invalid-credential ids. | CONFIRMED | The list is identical at both tags (v11 `api4/user.go` L2133-2146, v10 L1984-1997). Plugin rejection uses the raw id `"Login rejected by plugin: …"`, which is masked. |
| A8 | Token precedence: cookie, then Bearer, then Token, then query. | CONFIRMED | `ParseAuthTokenFromRequest` L493. Extra detail: a deferred block truncates the token to 50 characters. That doesn't matter for 26-character tokens. |
| A9 | An invalid token on a no-session endpoint continues unauthenticated. | CONFIRMED | `web/handlers.go` L277-289. An error is set only when `StatusCode==500`, or when `RequireSession` is true (401 `session_expired`). |
| A10 | CSRF is checked only for cookie tokens. | CONFIRMED | `checkCSRFToken`: `tokenLocation == TokenLocationCookie && !TrustRequester && Method != GET`. |
| A11 | `PostEditTimeLimit` units (auth note said UNVERIFIED; posts note said seconds). | RESOLVED: seconds | `api4/post.go` L1057 `postEditTimeLimitExpired`: `GetMillis() > CreateAt + limit*1000`. `-1` means unlimited. |
| A12 | `POST /users/mfa` doesn't exist. | CONFIRMED | `api4/user.go` L66-67 registers only `PUT /users/{id}/mfa` and `POST /users/{id}/mfa/generate`. |
| A13 | `config/client`: v10 requires `format`, v11 ignores it. | CONFIRMED | v10 `getClientConfig` returns 501 when `format` is missing and 400 when it isn't `old`. The v11 body has no `format` read. |
| A14 | Mobile-keyword User-Agent sniffing. | CONFIRMED | `utils/utils.go` L232-242 matches `Mobile\|Android\|iOS\|iPhone\|iPad`. The default CFNetwork UA I observed, `<exe> (unknown version) CFNetwork/3896.100.1.1.1 Darwin/27.0.0`, is safe. |
| A15 | `X-Request-ID` is always server-generated. | CONFIRMED | `web/handlers.go` L171 `requestID := model.NewId()`. |
| A16 | The `desktop_token` login response is not sanitized, and cookies are always set. | CONFIRMED | `loginWithDesktopToken` calls `AttachSessionCookies` unconditionally and `Encode(user)` with no `Sanitize`. With the default cookie store, that cookie then wins over Bearer, and **every non-GET fails 401 CSRF** (A10). This is a second reason to disable cookies. |
| A17 | `SetInvalidParam` error id. | CORRECTED (detail) | `web/context.go` L251/L255 give `api.context.invalid_body_param.app_error` **even for query params** (`after`, `before`, `since`, `post.type`). Only `SetInvalidURLParam` gives `invalid_url_param`. |

---

## 2. WebSocket

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| W1 | A Bearer header on the upgrade authenticates the socket. | CONFIRMED | `APIHandlerTrustRequester` still goes through `ServeHTTP`, which runs the token parse. A Bun capture (`/tmp/critic/ws/srv.ts`) showed `URLSessionWebSocketTask` keeps `Authorization: Bearer …` on the upgrade. |
| W2 | `URLSessionWebSocketTask` and the `Origin` header (was UNVERIFIED). | RESOLVED | It sends **no `Origin`**. The captured headers were `accept, accept-encoding, accept-language (cs-CZ), authorization, connection, host, sec-websocket-extensions: permessage-deflate, key, version, upgrade, user-agent`. `app/server.go` L1279 `OriginChecker` allows an empty Origin, and so does the `AllowCorsFrom` path (`utils/api.go` `CheckOrigin`: `origin=="" → true`). Don't set an Origin yourself. |
| W3 | Auto-pong to server Ping frames (was UNVERIFIED). | RESOLVED: yes | `/tmp/critic/ws/srv2.ts` sent 6 pings, alternating payload and empty payload. All 6 pongs came back, even with no `receive()` pending. |
| W4 | With an expired or invalid token in the header, the upgrade succeeds and then the socket dies. | CONFIRMED, with a correction to the close code | The upgrade returns 101 with no session, the conn is not registered, and the `authTicker` closes it after 5 s. **`URLSessionWebSocketTask` reports `closeCode == 0` (`.invalid`) with `NSPOSIXErrorDomain` 54 or 57, not 1006.** A server close frame with an empty payload shows up as `closeCode == 1005` (tested with a raw Python server, `/tmp/critic/ws/raw.py`). The WebSocket alone can't tell "token dead" from "network": after repeated quick closes, call `GET /users/me` and treat a 401 as logout. |
| W5 | Resume needs header or cookie auth. | CONFIRMED | `api4/websocket.go` L100: `if cfg.ConnectionID=="" \|\| Session().UserId==""` then a new id. The file is byte-identical at v10 (`diff` is empty). |
| W6 | `sequence_number` means "next seq expected" (last + 1). | CONFIRMED, with an addition | `writePump` L526: `isInDeadQueue(wc.Sequence)` replays starting **at** that seq. **If you send the last seq you saw instead of last + 1, that event is replayed and you get a duplicate.** The webapp does `serverSequence = msg.seq + 1` (`websocket.ts` L419). An invalid id or a missing seq makes `PopulateWebConnConfig` fail, followed by `ws.Close()` right after the 101. A negative seq parses and then takes the lossy path, which sends `hello`. |
| W7 | Only *inactive* connections can be resumed. | CONFIRMED, with additions | `web_hub.go` L1017 `RemoveInactiveByConnectionID` checks `!conn.Active.Load()`. Additions: an inactive conn **stays in the hub index and keeps receiving broadcasts and action replies** into its 256-slot queue (`broadcast` / `directMsg` only check `connIndex.Has`). On overflow, `closeAndRemoveConn` runs and resume is gone. The reaper uses `staleThreshold` = 5 min against `lastUserActivityAt`. |
| W8 | Resume decision tree: success / lossless / lossy + `hello`. Encode errors still bump the seq. | CONFIRMED | `writePump` L526-558 and L577-592. On the lossy path, `hello` is written directly with seq 0 and later events continue at 1. |
| W9 | A non-empty `connection_id` with `sequence_number=0` corrupts numbering. | CONFIRMED | `CheckWebConn`: `seqNum==0` goes to the local `CheckConn` (so it can be "found"). `writePump` skips all resume logic when `Sequence==0`. The hub sends `hello` only if `reuseCount==0`. |
| W10 | With `authentication_challenge`, `hello` arrives before the OK reply. | CONFIRMED | The hub loop pushes `hello` into `send` before it answers `webConnReg.err`. The router's `SendMessage(resp)` runs after that. |
| W11 | Resume-detection trick: send `ping` right after open. | CONFIRMED (derived) | In every path, `hello` is enqueued (fresh) or written (lossy) before `writePump` reads `send`. A success or lossless resume writes no `hello`. |
| W12 | Events stop silently after mid-session failure. | CONFIRMED, with an addition | `IsBasicAuthenticated` L782. Addition: `ClearAllUsersSessionCache` leads to `Hub.InvalidateAll` (`web_hub.go` L679), which **clears `SessionToken` on every WebConn** on the node. All sockets then silently stop getting events, including sockets whose sessions are still valid. The `ping` action then returns FAIL `api.web_socket_router.not_authenticated.app_error` (router L109). **Send `ping` periodically (the webapp uses 30 s). On FAIL, reconnect; don't re-send the challenge.** |
| W13 | `ping` reply shape. | CONFIRMED | `wsapi/system.go`: `{text:"pong", version: CurrentVersion, server_time: ms, node_id:""}`. |
| W14 | `status_change` goes to the user themselves only. | CONFIRMED | `platform/status.go` L210: `NewWebSocketEvent(StatusChange,"","",status.UserId,…)`. |
| W15 | Liveness constants: pong wait 100 s, ping interval 60 s, 8 KiB read limit. | CONFIRMED | `web_conn.go` L33-44. `model/websocket_client.go` L21: `SocketMaxMessageSizeKb = 8*1024`. |
| W16 | Away status is triggered from the pong handler. | CONFIRMED | `readPump` pong handler calls `SetStatusAwayIfNeeded(false)`. `isUserAway` is at `platform/status.go` L588. |
| W17 | Precomputed event JSON has spaces after the colons. | CONFIRMED | `precomputedJSONBuf` builds `{"event": …, "data": …, "broadcast": …, "seq": N}`. `data` is always an object (`NewWebSocketEvent` does `make(map)`). |

### `posted` and `post_deleted` data (v11)

- **P-WS1 (CONFIRMED)**, `notification.go` L691-731:
  - The data carries `channel_type`, `channel_display_name`, `channel_name`, `sender_name`, `team_id`, and `set_online` (bool).
  - `team_id` is `""` for DMs and GMs: `handlePostEvents` L723-725 uses a blank Team.
  - `otherFile` and `image` are the **strings** `"true"`.
  - `post` is a JSON string. It carries `pending_post_id`, because the post was saved, then run through `PreparePostForClient`, and only then published.
- **P-WS2 (CORRECTED/GAP)**, `mentions`:
  - The hook adds `mentions`, containing only your own id, whenever you appear in the server's `mentions.Mentions`. That includes @channel/@here/@all, keyword and group mentions.
  - **In DMs, every message from the other person produces `mentions` for the recipient** (`DMMention`, `notification.go` L1060-1085).
  - Use `mentions` presence as "this incremented my mention count".
- **P-WS3 (CONFIRMED, v11)**:
  - `publishWebsocketEventForPost` removes `channel_mentions` and permalink metadata before serializing.
  - Per-recipient hooks add them back only when you are allowed to see them.
  - Burn-on-read posts go out with the message and file ids blanked.
- **P-WS4 (CORRECTED)**, `post_deleted` (`CleanUpAfterPostDeletion`, `app/post.go` ~L3393):
  - The payload is the pre-delete snapshot, so `delete_at` is 0 and **the original `message` text is not blanked**. Wipe it locally.
  - Deleting a post also deletes the `flagged_post` preference (asynchronously) and any drafts attached to that post.

---

## 3. Posts, pagination, dedup

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| P1 | `pending_post_id` is not validated, not a DB column, a global cache key, with TTL 30 s and 25k entries. | CONFIRMED | `Post.IsValid` (`model/post.go` L499-590) never looks at it. `app/post.go` L29-33 (`pendingPostIDsCacheTTL`, `PendingPostIDsCacheSize`). `deduplicateCreatePost` is right after `CreatePostMissingChannelWithFlags`. |
| P2 | The dedup hit returns a raw DB post: `pending_post_id` is `""`, no metadata, no WebSocket event. | CONFIRMED | `CreatePost` returns `foundPost` from `GetPostIfAuthorized` → `GetSinglePost` before `PreparePostForClient`. `api4 createPost` re-prepares only burn-on-read posts. |
| P3 | Dedup is atomic. | CORRECTED | It isn't. `seenPendingPostIdsCache.Get` and `SetWithExpiry` are separate calls, so two truly simultaneous identical requests can both create a post. Beyond the TTL a retry always duplicates. **Before retrying after more than about 25 s, reconcile with `GET /channels/{id}/posts?since=<last update_at>` and match by message and user.** |
| P4 | `getPostsForChannel` precedence. | CONFIRMED, with additions | `api4/post.go` `getPostsForChannel` checks `since>0`, then `after`, then `before`, then page. `since<=0` falls through to page. `after` doesn't pass `CollapsedThreadsExtended`. `include_deleted` needs system admin. |
| P5 | v10 accepts only the exact string `"true"` for these bools. | CONFIRMED | v10 `getPostsForChannel` L29-32: `== "true"`. |
| P6 | Non-CRT `since` returns deleted posts and edit-history rows. | CONFIRMED, with additions | `GetPostsSince` (`post_store.go` L1437): the CTE has `UpdateAt > ? AND ChannelId = ? LIMIT 1000`, with no ORDER BY and no DeleteAt filter. Additions: `reply_count` is **computed only when `skipFetchThreads=true`** (the same rule as the page query, `getRootPosts`). `Update` sets the old row's `UpdateAt = DeleteAt = now` and `OriginalId`, so history rows always land in `since`. |
| P7 | Editing a post doesn't touch channel state. | GAP | `SqlPostStore.Update` ends with `UPDATE Channels SET LastPostAt = now … WHERE LastPostAt < now`. **Every edit bumps the channel's `last_post_at`**, which moves it in "recent" sorting and feeds the view logic (C1). |
| P8 | The posts ETag depends on the CRT flag. | CORRECTED (harmless) | `GetEtag` calls `q.Where(RootId="")` and throws away the result (squirrel builders are immutable), so the CRT and non-CRT ETags are identical. The ETag is unquoted: `"<ver>.<maxUpdateAt>"`. |
| P9 | `per_page` is capped at 200 and a negative `page` becomes 0. | CORRECTED | `web/params.go` L217: a negative page is reset **only when the route has no `{user_id}`** (and isn't `channel_members`). On `/users/{id}/…` routes (flagged posts, threads, …) a negative page is passed through unchanged. Never send one. |
| P10 | At most 10 file ids per post. | CONFIRMED | `ArrayToJSON` length is `29n+1`, which must be ≤ 300 (`PostFileidsMaxRunes`), so n ≤ 10. |
| P11 | Creating a post leaves the author's read state alone. | GAP | `CreatePostAsUserWithFlags` calls `MarkChannelsAsViewed` for the author, unless the post has `from_webhook` or `from_bot`, or it is a CRT reply. The server advances your `last_viewed_at` and can emit `multiple_channels_viewed`. Don't also call `view` after sending. |
| P12 | The `post_edited` echo carries `pending_post_id`. | PLAUSIBLE REFUTED (not fully traced) | The update path loads the post from the DB, where the field isn't stored, so expect `""`. Reconcile edits by post `id`. |
| P13 | The system-post-type error id differs between versions. | CONFIRMED | v11 `createPostChecks` → `SetInvalidParam("post.type")` → `invalid_body_param`. v10 raises it in the app layer as `api.context.invalid_param.app_error`. |

---

## 4. Channels: view and read state

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| C1 | `POST /channels/members/{uid}/view` semantics. | CONFIRMED, with additions | `model/channel_view.go`. `api4 viewChannel`. `MarkChannelsAsViewed` (`app/channel.go` L3678). `GetChannelsWithUnreadsAndWithMentions` treats a channel as unread when `TotalMsgCount - MsgCount > 0 \|\| MentionCount > 0`; this uses total counts, not root counts. `UpdateLastViewedAt` sets `greatest(cm.LastViewedAt, c.LastPostAt)`. The response `times` is `max(LastPostAt, LastViewedAt)` from before the update. Additions: a `channel_id` you are not a member of returns **200 with `{}`**, not an error. |
| C2 | `view` is not a presence signal. | GAP | `SetActiveChannel` (`app/channel.go` L3158) runs on every view. With a non-empty `channel_id` it sets the status to **online** unless the status was set manually. It always refreshes `LastActivityAt`, so it also delays away. `ActiveChannel == channel` combined with activity within `StatusChannelTimeout` **suppresses push notifications for that channel** (`notification_push.go` `doesStatusAllowPushNotification`). On window blur or app deactivate, send `{"channel_id":"","prev_channel_id":"<current>"}`. |
| C3 | `/users/me/channels` streams, and zero channels produce a broken body. | CONFIRMED | `api4/channel.go` `getChannelsForUser`: `[` is written first, and a first-page `not_found` then appends an error. |

---

## 5. File upload

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| F1 | Multipart vs. simple is chosen by Content-Type. | CONFIRMED | `api4/file.go` `parseMultipartRequestHeader`: `multipart/form-data` with a boundary goes to the multipart path. Anything else, including a missing Content-Type, goes to `uploadFileSimple`. |
| F2 | Any Content-Type works for a simple upload. | **GAP (critical)** | `uploadFileStream` calls `r.ParseForm()` **before** dispatching. For `application/x-www-form-urlencoded`, Go reads the body as a form: up to 10 MB, and over that it fails with "http: POST too large", giving 400 `api.file.upload_file.read_request.app_error`. Either way the file bytes are consumed. **URLSession defaults, measured with a Python echo server (`/tmp/critic/net/up.swift`):** `upload(for:from: Data)` and `httpBody` send `application/x-www-form-urlencoded`; `upload(for:fromFile:)` sends `application/octet-stream`. **Always set Content-Type explicitly** (MIME type or `application/octet-stream`). `/api/v4/uploads/{id}` doesn't call ParseForm (`api4/upload.go` `doUploadData`), so it is unaffected. |
| F3 | The multipart body must have `channel_id` first. | CORRECTED | If `channel_id` is in the **query string**, a file-first multipart body still streams. The legacy buffered fallback, which reads only the form field `files`, applies only when `channel_id` is missing from both the query and the earlier parts. |
| F4 | Size and length checks. | CONFIRMED | `Content-Length: 0` gives 400. Chunked (`ContentLength == -1`) passes. `UploadFileX` returns 413 when `ContentLength > MaxFileSize`, and again when the written size exceeds it. `MaxBytesReader` caps the request at `MaxFileSize + 512` (`web/handlers.go` L224-234). |

---

## 6. Swift toolchain and Xcode project

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| S1 | The isolation table. | CONFIRMED, all rows | `/tmp/critic/iso/main.swift` and `run.sh`, called from `@MainActor`, print whether each function runs on the main thread: <br>• `-swift-version 6`: `plain=false nonisolated=false nonsending=true concurrent=false`. <br>• `+NonisolatedNonsendingByDefault`: everything true except `@concurrent`. <br>• `+ApproachableConcurrency` behaves the same **and** sets `hasFeature(InferIsolatedConformances)`. <br>• `-default-isolation MainActor`: `plain=true nonisolated=false classNonisoMethod=false`, and it also reports `hasFeature(InferIsolatedConformances)=true`. |
| S2 | What that means for MatterMac. | GAP | The app target (MainActor default + NonisolatedNonsending) and MatterKit (NonisolatedNonsending) both run any unannotated or `nonisolated` async helper **on the caller's actor, which is the main thread when UI code calls it**. JSON decoding of large lists, `AttributedString(markdown:)`, ImageIO thumbnailing and the dead-queue/resync merge must be `@concurrent` (or live in a separate actor), or they block the UI. |
| S3 | The Swift 6.4 compiler crash. | CONFIRMED | `/tmp/critic/crash`: `a.swift` (`@objc async` taking a `URLRequest`) and `b.swift` (async `willPerformHTTPRedirection`) both exit 133, "While silgen visitDecl". Adding `@concurrent` gives exit 0. Without the feature flag it also exits 0. |
| S4 | The pbxproj is valid. | CONFIRMED | Copied to `/tmp/critic/xc`. `plutil -lint` reports OK. `xcodebuild -list` shows targets MatterMacDemo and MatterMacDemoUITests and schemes MatterKit and MatterMacDemo. A Debug build with `-destination 'platform=macOS,arch=arm64'` gives **BUILD SUCCEEDED** and logs "Disabling hardened runtime with ad-hoc codesigning". Caveats: `objectVersion = 90` probably can't be opened by pre-27 Xcode (PLAUSIBLE); `SWIFT_STRICT_CONCURRENCY` does nothing in Swift 6 mode. |
| S5 | Keychain with ad-hoc signing (`CODE_SIGN_IDENTITY "-"`, no team). | GAP | `/tmp/critic/kc/kc.swift` (ad-hoc signed): `SecItemAdd` with `kSecUseDataProtectionKeychain` fails with **-34018 "A required entitlement is not present"**. The legacy file keychain returns 0. Legacy item ACLs are bound to the code signature, and an ad-hoc cdhash changes on every build, so expect access prompts or lost access to the stored token (PLAUSIBLE; no GUI test). The data-protection keychain needs team signing plus `keychain-access-groups`. |
| S6 | URLCache and ETag handling. | GAP | `/tmp/critic/net/etag.swift`: <br>• `urlCache = nil` plus a manual `If-None-Match` gives a **304 with 0 bytes** passed straight through. <br>• With the default `.ephemeral` in-memory cache, URLSession revalidates on its own and turns the server's 304 into a **200 with the cached body**, even when you set `If-None-Match` yourself (and despite `Expires: 0`). Your own 304 branch never runs. Disable the cache (`urlCache = nil`) if you implement ETags. |

---

## 7. Contradictions between the notes, resolved

- **`PostEditTimeLimit` units:** seconds (A11).
- **WebSocket "client sees 1006":** with `URLSessionWebSocketTask` a raw TCP close shows up as `closeCode 0`, and a close frame with no status as `1005` (W4).
- **"Max 5 files" (YAML) vs. 10:** 10, enforced only by rune length (P10).
- **Auth §2 and WebSocket §2 on header auth:** they agree (W1, W5).

## 8. Remaining gaps with implementation guidance (derived from code, not live-tested)

1. **Sleep/wake resume.** After a sleep or a network change, the old socket stays `Active` on the server until the pong timeout (up to about 100 s). A resume against it fails and you get a new `hello`, which means a full resync.
   - To improve the odds, `cancel(with: .goingAway)`, wait for the close to finish, then reconnect with `connection_id` and `last+1`.
   - Expect `hello` whenever the network path actually changed.
2. **Resume impossible after overflow.** More than 256 events queued while disconnected, or an admin-triggered session-cache purge (W12), both rule out resume. Always keep the REST resync path.
3. **`since` cursors.** Use server timestamps: the largest `update_at` you have seen, or `ping.data.server_time`. Never use the local clock.
4. **Keep the `Connection-Id` header** set to the current `hello.connection_id` on REST calls. `posted` has no `omit_connection_id`, so your own posts always echo back; reconcile them by `pending_post_id` (and by the P2/P3 rules on the dedup path).

The probe servers were throwaway local processes on ports 18765-18769.