# MatterMac: Mattermost authentication, identity, discovery and errors (v11.11.1 and ESR v10.11.24)

Everything below comes from the Go server, webapp and API YAML source at tags `v11.11.1` and `v10.11.24`, fetched into `/tmp/mm-research-auth/{v11.11.1,v10.11.24}/…`. Paths are repo-relative and line numbers are approximate (v11 unless stated). **v10Δ** marks a difference in ESR v10.11.24. Anything I could not confirm in code is marked UNVERIFIED.

---

## 0. What the Swift client must do

1. **Log in:** `POST /api/v4/users/login` with a JSON body where every value is a string. Read the `Token` response header and send `Authorization: Bearer <token>` on every request after that.
2. **Turn cookies off** on the `URLSession` (`httpCookieStorage = nil`, `httpShouldSetCookies = false`). The server reads the `MMAUTHTOKEN` cookie *before* it reads `Authorization`. A stored cookie wins, and then every non-GET request needs CSRF headers.
3. **Don't send `X-Requested-With: XMLHttpRequest`** on login. That header is the only thing that makes password login set cookies. Bearer requests never need it and never need `X-CSRF-Token`.
4. **MFA:** first send login without `token`. If the reply is 401 with id `mfa.validate_token.authenticate.app_error`, ask for the code and resend with `"token":"123456"`.
5. **Treat 401 `api.context.session_expired.app_error` as logged out.** A 500 is not a logout, even if its id is `api.context.invalid_token.error`.
6. **Discovery order:** `GET /api/v4/system/ping`, then `GET /api/v4/config/client?format=old` (limited config), then `GET /api/v4/license/client?format=old`. Log in, then fetch config again to get the full config (`MaxPostSize`, `EnableUserAccessTokens`, `MaxFileSize`, …). **Always send `format=old`**: v10 requires it and v11 ignores it.

---

## 1. `POST /api/v4/users/login`

**Handler and route**
- Handler: `server/channels/api4/user.go` `func login` (v11 ~L2125; v10 ~L1977).
- Route: L69, `api.RateLimitedHandler(api.APIHandler(login), {PerSec:5, MaxBurst:10})`. This per-route limiter only runs when `RateLimitSettings.Enable=true`.
- It is an `APIHandler`: no session required and no CSRF.

### Request body

The server parses it with `model.MapFromJSON`, which decodes into `map[string]string` (`server/public/model/utils.go` ~L507).

- **Every value must be a JSON string.**
- A non-string value (for example `"ldap_only": true`) is not an error. It just becomes `""`. That is standard Go `encoding/json` behaviour; the error is ignored.

| field | type | meaning |
|---|---|---|
| `login_id` | string | email, username, or LDAP login attribute |
| `password` | string | an empty value gives 400 `api.user.login.blank_pwd.app_error` |
| `token` | string | MFA TOTP code. Whitespace is trimmed; it must be exactly 6 digits (`server/platform/shared/mfa/mfa.go` `authenticate`, dgoogauth) |
| `id` | string | optional user ID instead of `login_id`. Only honoured when email or username sign-in is enabled |
| `device_id` | string | push device id. **Omit it for macOS** (see below) |
| `ldap_only` | `"true"` | parsed, but **unused**: `ldapOnly` is never read in `AuthenticateUserForLogin` (`app/login.go` L29, both tags) |
| `voip_device_id` | string | **v11 only** |
| `magic_link_token` | string | **v11 only**, guest magic link |

**`device_id` handling**
- v11 `DoLogin` (`app/login.go` ~L146) requires the form `apple_rn[beta][-vN]:<tok>` or `android_rn[-vN]:<tok>` (`model/session.go` `IsValidDeviceId` ~L326). Anything else is a 400 `api.user.attach_device_id.invalid_device_id.app_error`, and the login handler then **masks** it into a 401 `invalid_credentials_*`.
- In v11 a non-empty `device_id` forces a mobile session and revokes other sessions with the same device id.
- **v10Δ:** no format validation. A non-empty `device_id` still selects the mobile session length and revokes other sessions for that device.
- The webapp sends `deviceId` in camelCase, which the server ignores. Use `device_id`.

### How the login identifier is resolved

`app/login.go` `GetUserForLogin` (~L97):

1. If `EnableSignInWithEmail || EnableSignInWithUsername`:
   - If `id` is set, look up `GetUser(id)`.
   - Otherwise run the store query `GetForLogin(loginId, …)` (`channels/store/sqlstore/user_store.go`):
     - both enabled: `Username = lower(?) OR Email = lower(?)`
     - username only: `Username = lower(?)`
     - email only: `Email = lower(?)`
   - The match is case-insensitive. The webapp also trims and lowercases the id.
2. If that fails and LDAP is enabled: `Ldap().GetUser(loginId)`, then map to the local user by AuthData.
3. Otherwise: 400 `store.sql_user.get_for_login.app_error`, which is masked (see below).

Then `authenticateUser` (`app/authentication.go` L452):
- **LDAP user:** LDAP bind, then MFA.
- **User with any other `AuthService`** (SSO): 400 `api.user.login.use_auth_service.app_error`, which is masked.
- **Email user:** `CheckPasswordAndAllCriteria` (L110), which runs in this order:
  1. Preflight: account not deactivated, not a bot, `FailedAttempts < MaximumLoginAttempts` (default 10).
  2. Password check.
  3. MFA check.
  4. Postflight: email verified, if `RequireEmailVerification` is on.
- All errors from this path get `StatusCode = 401`.
- An MFA probe without `token` does not count as a failed attempt (the attempt slot is refunded in v11; v10 simply doesn't increment).

### Success response
- **HTTP 200.** No `WriteHeader` is called, although the YAML says 201.
- Body: a `User` JSON object after `Sanitize({})`. `password`, `mfa_secret`, `mfa_used_timestamps` and `last_login` are removed; `email` and names are kept.
- `terms_of_service_id` and `terms_of_service_create_at` (Unix ms) are added if present.
- Timestamps in the User object (`create_at`, `update_at`, `delete_at`, `last_picture_update`, …) are **Unix milliseconds**.

**Response header `Token: <26-char session token>`**
- Set in `DoLogin` (`app/login.go` L221: `w.Header().Set(model.HeaderToken, …)`).
- `HeaderToken="token"`; Go canonicalises it to `Token`.
- The official Go client does `AuthToken = r.Header.Get("Token")` and then sends `Authorization: BEARER <tok>` (`model/client4.go` L1055, L936).

**Cookies**
- `AttachSessionCookies` (`app/login.go` L288) runs **only if the request has `X-Requested-With: XMLHttpRequest`** (`api4/user.go` L2277).
- It sets:
  - `MMAUTHTOKEN`: the token, HttpOnly
  - `MMUSERID`: the user id
  - `MMCSRF`: the CSRF token
- All three have `Path=<subpath>`, `Max-Age=SessionLengthWebInHours*3600`, `Secure` when https, and `SameSite=None` only when the `MMEMBED=1` cookie is present.
- Bearer clients don't need any of them.

**Session length** (`DoLogin`)
- Mobile (`IsMobile` or a device id): `SessionLengthMobileInHours`.
- OAuth or SAML: `SessionLengthSSOInHours`.
- Everything else: `SessionLengthWebInHours`.
- Defaults are 30 days on a fresh install and 180 days for web/mobile on an upgraded server.
- `IsMobile` comes from `utils.IsMobileRequest`: the User-Agent contains `Mobile|Android|iOS|iPhone|iPad` (`channels/utils/utils.go` L232). Keep those strings out of the macOS User-Agent unless you want mobile semantics.

### Error masking

A deferred block in `login` (L2126–2186) rewrites every error whose id is **not** in this list:

```
mfa.validate_token.authenticate.app_error
api.user.check_user_mfa.bad_code.app_error
api.user.login.blank_pwd.app_error
api.user.login.bot_login_forbidden.app_error
api.user.login.remote_users.login.error
api.user.login.client_side_cert.certificate.app_error
api.user.login.inactive.app_error
api.user.login.not_verified.app_error
api.user.check_user_login_attempts.too_many.app_error
app.team.join_user_to_team.max_accounts.app_error
store.sql_user.save.max_accounts.app_error
api.user.check_user_login_attempts.too_many_ldap.app_error
```

Masked errors become **HTTP 401** with an id chosen from the *config*:
- If any of `SamlSettings.Enable`, `GitLabSettings.Enable`, `GoogleSettings.Enable`, `Office365Settings.Enable`, `OpenIdSettings.Enable` is true: `api.user.login.invalid_credentials_sso`
- Else if username sign-in is on and email sign-in is off: `api.user.login.invalid_credentials_username`
- Else if email sign-in is on and username sign-in is off: `api.user.login.invalid_credentials_email`
- Otherwise: `api.user.login.invalid_credentials_email_username`

Masked sources include:
- wrong password (`api.user.check_user_password.invalid.app_error`)
- unknown user
- SSO-only account (`use_auth_service`)
- LDAP errors (`ent.ldap.do_login.*`)
- guest-disabled errors
- invalid `device_id`
- plugin rejection

### Outcome table (identical in v10 and v11 unless noted)

| situation | status | `id` |
|---|---|---|
| MFA active and `token` empty or malformed (not 6 digits) → **MFA required** | 401 | `mfa.validate_token.authenticate.app_error` (created as 400 in `CheckUserMfa` L368, overwritten to 401 in `authenticateUser` L486 / L464) |
| wrong 6-digit MFA code | 401 | `api.user.check_user_mfa.bad_code.app_error` |
| wrong password (password is checked before MFA) | 401 | masked `api.user.login.invalid_credentials_*` |
| unknown `login_id` | 401 | masked |
| deactivated user (`delete_at>0`), checked before the password | 401 | `api.user.login.inactive.app_error` |
| locked (too many attempts) | 401 | `api.user.check_user_login_attempts.too_many.app_error`, or `…too_many_ldap.app_error` for LDAP users |
| email not verified | 401 | `api.user.login.not_verified.app_error` |
| bot account | 401 | `api.user.login.bot_login_forbidden.app_error` |
| blank password | 400 | `api.user.login.blank_pwd.app_error` |
| email/username sign-in disabled, SSO-only account, LDAP not licensed | 401 | masked. **There is no distinct "method disabled" id.** Decide which UI to show from the limited client config. |

- Malformed and missing MFA codes return the same id. The webapp tracks whether it already showed the MFA field (`webapp/channels/src/components/login/login.tsx` ~L701: `!showMfa && id==='mfa.validate_token.authenticate.app_error'`).
- Messages are localised from `Accept-Language` (`public/shared/i18n/i18n.go`). English: `"Invalid MFA token."` for both MFA ids; `"Enter a valid email or username and/or password."` for `invalid_credentials_email_username`.
- **v10Δ:** failed-attempt counting uses a global mutex with increment-after-failure; v11 claims an attempt slot atomically. The error ids are the same.

### Separate MFA check endpoint
- **`POST /api/v4/users/mfa` does not exist in the server at either tag.** I scanned every non-test `server/channels/api4/*.go` and `web/*.go`: there is no `Users.Handle("/mfa")` and no `checkUserMfa` handler.
- The v10 YAML (`api/v4/source/users.yaml` L1530) and webapp `client4.ts` (~L1156) still reference it.
- What a request to it returns is UNVERIFIED: either 404 JSON `api.context.404.app_error` or 405, because `mfa` also matches the `{user_id}` pattern of `/users/{user_id}`, which has no POST.
- **Use the login probe above instead.**
- The MFA endpoints that do exist, `PUT /users/{id}/mfa` and `POST /users/{id}/mfa/generate`, are `APISessionRequiredMfa` (L66–67). They skip the MFA-enforcement check so a user can enrol.

### Other login endpoints
- `POST /users/login/desktop_token`, see §7.
- `POST /users/login/switch` (change auth method).
- `POST /users/login/cws` (Cloud only).
- **v11 only:** `POST /users/login/type` (`{"login_id"}` → `{"auth_service":""|"magic_link","is_deactivated":bool}`). It returns a bare 404 unless guest magic links are enabled and licensed.
- `POST /users/login/sso/code-exchange` exists in both but is deprecated: `Deprecation: true` header and 410 `api.user.login_sso_code_exchange.deprecated.app_error` unless the feature flag `MobileSSOCodeExchange` is on (default false; `model/feature_flags.go`).

---

## 2. How requests are authenticated

The core is `web/handlers.go` `Handler.ServeHTTP` (L160) together with `app/authentication.go` `ParseAuthTokenFromRequest` (L493). It is identical in v10.

### Where the token is read from (first match wins)

1. **Cookie `MMAUTHTOKEN`**
2. `Authorization: Bearer <tok>`: the check is `len>6 && ToUpper(h[0:6])=="BEARER"` and the token is `h[7:]`. That means exactly one space.
3. `Authorization: Token <tok>`: the check is `ToLower(h[0:5])=="token"` and the token is `h[6:]`. Any session token works here, not only OAuth ones.
4. Query `?access_token=`: accepted only when the session is OAuth. Otherwise 401 `api.context.token_provided.app_error` (L290).
5. `X-Cloud-Token` and `X-RemoteCluster-Token`: server-to-server only, not relevant.

### Token lookup
- `App.GetSession` (`app/session.go` L86): check the cache or DB. If not found, try it as a PAT. Reject expired sessions and idle-timed-out sessions.
- Idle timeout applies only when `SessionIdleTimeoutInMinutes>0 && !ExtendSessionLengthWithActivity`, and only to sessions that are not OAuth, mobile or PAT.

**If the token is invalid** (L282–289):
- GetSession returned a 500: that error is returned (id `api.context.invalid_token.error`, 500).
- The endpoint requires a session: 401 `api.context.session_expired.app_error`, plus `Set-Cookie: MMAUTHTOKEN=; Max-Age=-1`.
- The endpoint does not require a session (ping, `config/client`, …): **the request silently continues unauthenticated.** For example, `config/client` then returns the limited config.

### CSRF

`checkCSRFToken` (L517). A check happens only when **all** of these are true:
- the session is valid
- the token came from the **cookie**
- the handler is not `TrustRequester`
- the method is not GET

When checked, it passes if `X-CSRF-Token == session.Props["csrf"]` (also exposed as the `MMCSRF` cookie). Otherwise, if `X-Requested-With: XMLHttpRequest` is present and `ExperimentalStrictCSRFEnforcement=false` (the default), it passes with a debug log. Otherwise it fails with 401 `api.context.session_expired.app_error` ("Appears to be a CSRF attempt").
- **v10Δ:** v11 also clears the cookie on failure.
- v11.0.2 changelog: "Reverted a breaking change related to ServiceSettings.ExperimentalStrictCSRFEnforcement".

**A bearer-header request needs neither `X-Requested-With` nor `X-CSRF-Token`.** `X-Requested-With` is only read in two places: the login cookie attachment (`api4/user.go` L2277) and the CSRF fallback above.

### Handler flags (`api4/handlers.go`)

| wrapper | requires session | requires MFA | trusts requester |
|---|---|---|---|
| `APIHandler` | no | no | no |
| `APISessionRequired` | yes | yes | no |
| `APISessionRequiredMfa` | yes | no | no |
| `APIHandlerTrustRequester` | no | no | yes |

`SessionRequired` (`web/context.go` L138):
- Empty `UserId`: 401 `api.context.session_expired.app_error`.
- PAT session while `EnableUserAccessTokens=false`: the same error.

**Enforced MFA** (`App.MFARequired`, `app/authentication.go` L378):
- Applies when the license has MFA and `EnableMultifactorAuthentication` and `EnforceMultifactorAuthentication` are both on.
- Users without MFA, other than OAuth sessions, bots, SSO users, and guests unless `GuestAccountsSettings.EnforceMultifactorAuthentication`, get **403 `api.context.mfa_required.app_error`** on every session endpoint.
- The one exception is **`GET /api/v4/users/me`**. **v10Δ:** v10 exempts any method on `/api/v4/users/me`.

### WebSocket
- `GET /api/v4/websocket` is `APIHandlerTrustRequester` (`api4/websocket.go` L54).
- A `Bearer` header on the upgrade request authenticates the socket.
- Otherwise the client sends `{"action":"authentication_challenge","data":{"token":…}}` after open (`app/platform/websocket_router.go` L39).

---

## 3. `/users/me`, logout, expiry signals

**`GET /api/v4/users/me`**
- `api4/user.go` `getUser` (L305). `me` is replaced by the session user id (`web/context.go` `RequireUserId` L301).
- Returns 200 with the `User` object after `Sanitize({})`, the same shape as the login response.
- Sets an `ETag` header. `If-None-Match` with a matching value returns **304** with no body.
- This is the right call to validate a stored token at launch.

**`POST /api/v4/users/logout`**
- `APIHandler`, so it needs no valid session (`Logout` L2538).
- Always clears `MMAUTHTOKEN`. If a session is present it runs `RevokeSessionById`: the session row is deleted, the cache cleared, and a mobile wipe signal sent for device sessions.
- Returns 200 `{"status":"OK"}`, including when the token was already invalid.
- **With a PAT, logout only deletes the PAT's derived session.** The PAT stays valid, and the next request creates a new session.

**Expiry and invalid signals**

| status | id | meaning |
|---|---|---|
| 401 | `api.context.session_expired.app_error` ("Invalid or expired session, please login again.") | expired, revoked, idle-timeout, PAT disabled/expired/revoked, or CSRF failure. `detailed_error` is only present when `EnableDeveloper=true`. |
| 401 | `api.context.token_provided.app_error` | a non-OAuth token was sent in the query string |
| 403 | `api.context.mfa_required.app_error` | MFA is enforced and not yet set up. Show the MFA enrolment flow. |
| 500 | `api.context.invalid_token.error` | server or DB failure during lookup. **Do not log out.** |

**Session extension**
- Only when `ExtendSessionLengthWithActivity=true` (the default on new installs).
- Happens on `createPost` and `viewChannel`: `api4/post.go` ~L189 and `api4/channel.go` `viewChannel` ~L2053, via `App.ExtendSessionExpiryIfNeeded` (`app/session.go` L421).
- The server does not tell the client the new expiry.

---

## 4. Personal access tokens (PATs)

**Using a PAT**
- `Authorization: Bearer <pat>` (or `Token <pat>`).
- On first use `createSessionForUserAccessToken` (`app/session.go` L602) creates a session with `Props.type="UserAccessToken"` and a 100-year expiry. In v11 the expiry is clamped to the PAT's `expires_at`.
- The session is exempt from idle timeout and from MFA enforcement? No — it is **not** exempt from MFA enforcement unless the owner is a bot. It is exempt from the idle timeout.

**PAT failures (all surface as 401 `api.context.session_expired.app_error`)**
- `EnableUserAccessTokens=false` (non-bot): internal `app.user_access_token.invalid_or_missing` "EnableUserAccessTokens=false"
- inactive token or deleted user
- **v11 only:** expired (`app.user_access_token.expired`)
- **A client cannot tell "PAT disabled" apart from "invalid PAT" by error id.**

**Detecting PAT policy without admin rights**
- Not possible unauthenticated: `EnableUserAccessTokens` is **only in the full client config** (`config/client.go` L40).
- After logging in, fetch `GET /config/client?format=old` and read `EnableUserAccessTokens` (`"true"`/`"false"`). **v11 only:** also `MaximumPersonalAccessTokenLifetimeDays` (string int; `"0"` means no policy).

**Creating a PAT**
- The user needs permission `create_user_access_token`. It is granted by the role `system_user_access_token`, or by `system_admin`. Check `user.roles` from `/users/me`; the roles are space-separated.
- `POST /api/v4/users/{id}/tokens` with body `{"description":"…","expires_at":<Unix ms>}`. `expires_at` is **v11 only**; v10's `UserAccessToken` model has no such field.
- Response: `{"id","token","user_id","description","is_active","expires_at"}`. `token` is returned only once.
- OAuth sessions are refused with 403.

---

## 5. Unauthenticated discovery

### `GET /api/v4/system/ping`

`api4/system.go` `getSystemPing` (L147) is an `APIHandler`, identical in both tags. It takes **no `format` parameter**.

Body:
```json
{"status":"OK","AndroidLatestVersion":"","AndroidMinVersion":"","IosLatestVersion":"","IosMinVersion":"","ActiveSearchBackend":"database"}
```

- `status` is `"OK"` or `"UNHEALTHY"`. `UNHEALTHY` happens when the goroutine threshold is exceeded, or when a check fails under `get_server_status=true`.
- `TestFeatureFlag` is included if the feature flag is not `"off"`.

Query parameters:
- `get_server_status=true`: adds `database_status` and `filestore_status`, plus response headers `status`, `database_status`, `filestore_status`. Also adds `root_status` (bool), but only for admins. It writes to the DB, so don't poll with it.
- `device_id=…`: adds `CanReceiveNotifications`.
- `use_rest_semantics=true`: without it, a non-OK status returns **HTTP 500**. The webapp always sends `use_rest_semantics=true`.

The body has no server version. Read `X-Version-Id` from the response headers instead (§8).

### `GET /api/v4/config/client?format=old`

`api4/config.go` `getClientConfig` (L253), `APIHandler`:
- No session: `LimitedClientConfigWithComputed()`
- Session: `ClientConfigWithComputed()` (`app/platform/config.go` L330–359)

**v10Δ:**
- `format` missing: 501 `api.config.client.old_format.app_error`
- `format != "old"`: 400 `api.context.invalid_body_param.app_error`
- v11 ignores `format` (v11.0 changelog: "Format query parameter requirement in the /api/v4/config/client endpoint has been deprecated").

**Every value is a string** (`map[string]string`). Parse `"true"`/`"false"` and integers yourself.

The key builders are `config/client.go` `GenerateLimitedClientConfig` (L285) and `GenerateClientConfig` (L16).

**Keys in the LIMITED config (unauthenticated), which the full config also includes:**
- **Build and identity:** `Version` (e.g. `"11.11.1"`, `model.CurrentVersion`), `BuildNumber`, `BuildDate`, `BuildHash`, `BuildHashEnterprise`, `BuildEnterpriseReady`, `ServiceEnvironment`, `IsFipsEnabled` (**v11 only**), `DiagnosticId`, `TelemetryId`, `SiteURL` (trailing `/` trimmed), `SiteName`, `WebsocketURL`, `WebsocketPort`, `WebsocketSecurePort`.
- **Login methods:**
  - `EnableSignUpWithEmail`, `EnableSignInWithEmail`, `EnableSignInWithUsername`
  - `EnableLdap` and `LdapLoginFieldName`: `"false"`/`""` unless the license has the LDAP feature
  - `EnableSaml` and `SamlLoginButtonText`: need the SAML license feature
  - `EnableSignUpWithGoogle`, `EnableSignUpWithOffice365`: need the license feature (forced on for Cloud)
  - `EnableSignUpWithOpenId`, `OpenIdButtonText`, `OpenIdButtonColor`: need the OpenId license feature
  - `EnableSignUpWithGitLab`, `GitLabButtonColor`, `GitLabButtonText`: **v11 only when the license has OpenId; the key is absent otherwise.** v10 always includes them. Changelog v11.0: "GitLab SSO has been deprecated from Team Edition."
  - `EmailLoginButton*` colours
  - v10 only: `LdapLoginButton*` and `SamlLoginButton*` colours
- **MFA and guests:** `EnableMultifactorAuthentication`, `EnforceMultifactorAuthentication` (`"false"` unless the license has MFA), `EnableGuestAccounts`, `HideGuestTags`, `GuestAccountsEnforceMultifactorAuthentication`, `EnableGuestMagicLink` (**v11 only**).
- **Password rules:** `PasswordMinimumLength`, `PasswordRequire{Lowercase,Uppercase,Number,Symbol}`, `PasswordEnableForgotLink`, `ForgotPasswordLink`.
- **Other:** `EnableCustomEmoji` (limited, not full-only), `EnableUserStatuses`, `EnableUserCreation`, `EnableOpenServer`, `EnableCustomBrand`, `CustomBrandText`, `CustomDescriptionText`, `DefaultClientLocale`, support links (`TermsOfServiceLink`, `PrivacyPolicyLink`, `AboutLink`, `HelpLink`, `ReportAProblem*`, `SupportEmail`), `PluginsEnabled`, `AppsPluginEnabled`, `HasImageProxy`, `EnableDiagnostics`, `EnableClientMetrics`, `EnableComplianceExport`, `EnableBotAccountCreation`, `EnableDesktopLandingPage`, `AppDownloadLink`, `MobileExternalBrowser`.
- **`EnableFile`** and `FileLevel` are **log** settings (`LogSettings.EnableFile`). **`EnableFile` does not mean file attachments.**
- **Conditional keys:** `EnableCustomTermsOfService` and `CustomTermsOfServiceReAcceptancePeriod` (license), `CustomTermsOfServiceId`, `AsymmetricSigningPublicKey`.
- **Computed:** `NoAccounts`.
- **All `FeatureFlag<Name>` keys** (L458).

**Keys only in the FULL config (session required):**
- **Limits:** `MaxPostSize` (computed), `MaxFileSize` (bytes; default 104857600), `EnableFileAttachments`, `EnableMobileFileUpload`, `EnableMobileFileDownload` (`"true"` unless the Compliance license applies).
- **Tokens and integrations:** `EnableUserAccessTokens`, `MaximumPersonalAccessTokenLifetimeDays` (**v11 only**), `EnableOAuthServiceProvider`, `EnableCommands`, `EnableIncomingWebhooks`, `EnableOutgoingWebhooks`, `EnablePostUsernameOverride`, `EnablePostIconOverride`.
- **Threads and posts:** `CollapsedThreads` (`disabled` | `default_on` | `default_off` | `always_on`; default `always_on`), `ExperimentalEnablePostMetadata` (always `"true"`), `PostEditTimeLimit` (`-1` = unlimited; units UNVERIFIED, believed seconds), `PostPriority`, `PostAcknowledgements` (license), `ScheduledPosts` (license), `AllowPersistentNotifications*`, `PersistentNotification*`, `AllowSyncedDrafts`, `UniqueEmojiReactionLimitPerPost`, `MaxNotificationsPerChannel`, `EnableConfirmNotificationsToChannel`, `EnableBurnOnRead` and `BurnOnRead*` (**v11 only**).
- **Display and privacy:** `TeammateNameDisplay`, `LockTeammateNameDisplay`, `ShowEmailAddress`, `ShowFullName`, `RestrictDirectMessage`.
- **Rendering:** `EnableLinkPreviews`, `EnablePermalinkPreviews`, `EnableSVGs`, `EnableLatex`, `EnableInlineLatex`, `EnableEmojiPicker`, `EnableGifPicker`, `GiphySdkKey`, `CustomUrlSchemes` (comma-joined), `MaxMarkdownNodes`.
- **Presence and typing:** `EnableUserTypingMessages`, `TimeBetweenUserTypingUpdatesMilliseconds` (ms), `EnableChannelViewedMessages`, `EnableCustomUserStatuses`, `EnableLastActiveTime`.
- **Session and notifications:** `ExtendSessionLengthWithActivity`, `SendPushNotifications`, `SendEmailNotifications`.
- **Other:** `EnableCustomGroups`, `ExperimentalSharedChannels`, `EnableCrossTeamSearch`, `SchemaVersion`, `InstallationDate`, `UpgradedFromTE`.
- **Renamed or removed:** `EnableChannelCategorySorting` (v11) replaces `ExperimentalChannelCategorySorting` (v10). `ExperimentalViewArchivedChannels` exists in v10 only.

**There is no `ServerVersion` key.** Use `Version` and `BuildNumber`, or `X-Version-Id`.

**Max post length**
- `MaxPostSize` (string, in runes) is in the **authenticated config only**. It is `platform.MaxPostSize()` → `SqlPostStore.determineMaxPostSize`, which computes `max(column_bytes/4, 16383)`. In practice the value is at least **16383**.
- No `/system` endpoint exposes it.
- If a post is too long, the server returns 400 `model.post.is_valid.message_length.app_error` with parameters `Length` and `MaxLength` (`model/post.go` ~L529).

### `GET /api/v4/license/client?format=old`

`api4/license.go` `getClientLicense` (L30), `APIHandler`, identical in both tags.
- `format` missing: 400 `api.license.client.old_format.app_error`
- `format` anything else: 400 invalid parameter

Values are strings (`channels/utils/license.go` `GetClientLicense`):
- `IsLicensed`
- `SkuShortName`, `Users`
- Feature flags: `LDAP`, `LDAPGroups`, `MFA`, `SAML`, `Cluster`, `Metrics`, `GoogleOAuth`, `Office365OAuth`, `OpenId`, `Compliance`, `MHPNS`, `Announcement`, `Elasticsearch`, `DataRetention`, `IDLoadedPushNotifications`, `EmailNotificationContents`, `MessageExport`, `CustomPermissionsSchemes`, `GuestAccounts`, `GuestAccountsPermissions`, `CustomTermsOfService`, `LockTeammateNameDisplay`, `Cloud`, `SharedChannels`, `RemoteClusterService`, `OutgoingOAuthConnections`
- `IsTrial`, `IsGovSku`, `IsNonProduction` (**v11 only**), `Company`

Callers without `read_license_information` (all anonymous callers and normal users) get the **sanitized** version, which drops `Id`, `Name`, `Email`, `IssuedAt`, `StartsAt`, `ExpiresAt` and `SkuName`.

---

## 6. Errors, request id, rate limiting

**AppError body** (`model/utils.go` L232, identical in both):
```json
{"id":"api.context.session_expired.app_error","message":"<localized>","detailed_error":"","request_id":"<26 chars>","status_code":401}
```
- `detailed_error` is emptied unless `EnableDeveloper=true` (`web/handlers.go` L445).
- **There is no `is_oauth` field.**
- In `ExperimentalEnableHardenedMode`, every 5xx becomes `id:""` and `message:"Internal Server Error"`.
- Always branch on `id`. `message` is localised from `Accept-Language`.

**When errors are JSON and when they are HTML**
- JSON for `/api/*`, `/hooks/*`, `POST /oauth/authorize`, `/oauth/access_token`, `/oauth/deauthorize` and `/oauth/intune`, or when the request has any **`X-Mobile-App`** header (`handleContextError` L458).
- Every other path, for example `/.well-known/*` and `/login/*`, returns HTML or a redirect to `/error?…`.

**Common generic errors**
- 400 `api.context.invalid_body_param.app_error` or `api.context.invalid_url_param.app_error`
- 403 `api.context.permissions.app_error`
- 413 `api.context.request_body_too_large.app_error` (`MaximumPayloadSizeBytes`, default 300000)
- 414 `basic_security_check.url.too_long_error` (2048 characters)
- 503 `api.context.server_busy.app_error`
- 404 `api.context.404.app_error` for unknown `/api/v4/*` routes. These come from `web.Handle404` and carry **no** `X-Request-ID` or `X-Version-Id`.

**`X-Request-ID`**
- Set on every `ServeHTTP` response (L243). It is always a fresh `model.NewId()` (26 characters); **an `X-Request-ID` sent by the client is ignored**.
- The same value appears as `request_id` in error bodies.
- Go writes the header as `X-Request-Id`. Look headers up case-insensitively.

**Rate limiting** (`app/ratelimit.go`, throttled GCRA)

Where it applies:
- Only when `RateLimitSettings.Enable=true`. The default is false; when enabled the defaults are PerSec 10, MaxBurst 100, keyed by remote address.
- A global wrapper covers the whole server (`app/server.go` L1074–1083).
- Per-route limiters: `/users/login` (5/s, burst 10), `/users/login/desktop_token` (2/s, burst 1), and **v11 only** `/oauth/apps/register` (2/s, burst 1).
- With `VaryByUser`, there is an extra per-user limit inside `ServeHTTP` (L297).

Headers:
- **Added to every response that passes a limiter**: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (integer seconds, rounded up).
- `Retry-After` (integer seconds) appears only when the request was limited.
- Go writes these as `X-Ratelimit-*`.
- The headers use `Header().Add`, so login responses can carry **two values per header** (global and per-route). Foundation joins them with `", "`. Parse all values and take the most restrictive.

The 429 itself:
- `http.Error(w,"limit exceeded",429)`. The **body is plain text `limit exceeded\n`, not JSON.**
- A 429 from the global limiter comes before `ServeHTTP`, so it has no `X-Request-ID` or `X-Version-Id`.
- The exact value of `X-RateLimit-Limit` relative to burst is UNVERIFIED (throttled's `RateLimitResult.Limit`).

---

## 7. Browser and SSO options for a third-party native client

### A. Password or LDAP login (§1)
Works for any email, username or LDAP account, with no registration. It cannot be used for SSO accounts.

### B. PAT pasted by the user (§4)
Needs `EnableUserAccessTokens` plus the user's permission to create tokens.

### C. The official **desktop** SSO flow

No admin setup is needed. It relies on an undocumented contract that is shared with Mattermost Desktop.

1. Generate `client_token`: 64 random characters. The `dev-` prefix is reserved for development builds.
2. Open the system browser, or `ASWebAuthenticationSession` with callback scheme `mattermost`, at one of:
   - `{site}/oauth/{gitlab|google|office365|openid}/login?desktop_token=<client_token>[&redirect_to=/relative]` (`web/oauth.go` `loginWithOAuth` L468; `redirect_to` must be relative or same-origin, else 400 `api.invalid_redirect_url`)
   - `{site}/login/sso/saml?desktop_token=<client_token>` (`web/saml.go` L30)
3. After the identity provider succeeds, `completeOAuth` (L305) or `completeSaml` (L110) calls `GenerateAndSaveDesktopToken`: a 64-character `server_token` with a **3-minute TTL** (`model.DesktopTokenTTL`). It then redirects to `{site}/login/desktop?client_token=…&server_token=…[&redirect_to][&isDesktopDev=true]`.
4. That webapp page (`webapp/channels/src/components/desktop_auth_token.tsx` `forwardToDesktopApp` ~L82) runs outside the desktop app and executes `window.location.href = "mattermost://<host>/login/desktop?client_token=…&server_token=…"`. It uses `mattermost-dev:` when `isDesktopDev` is set.
5. The client checks `client_token` itself; the server never checks it. Then it calls `POST /api/v4/users/login/desktop_token` with `{"token":"<server_token>","device_id":""}` (`api4/user.go` L2300).
   - Success: 200, the `Token` header, **and cookies are always set**.
   - The body is a User that the handler never passes through `Sanitize()`, so it may contain `password`/`mfa_secret` fields. Never persist it.
   - Errors: 401 `app.desktop_token.validate.invalid` (bad or expired token), 401 `api.user.login_with_desktop_token.not_oauth_or_saml_user.app_error`.
   - The session is SSO-length.

Implementation update (2026-09-24): a scoped `ASWebAuthenticationSession` captures the JS-initiated `mattermost:` navigation in the opt-in local fixture on macOS 27, with Mattermost Desktop installed. No global scheme registration is added. The user subsequently confirmed successful Keycloak completion on their 10.11.9 deployment using its custom GitLab route. Other providers/browsers/OS versions remain unverified. See [decision 0011](../decisions/0011-scoped-desktop-sso.md).

### D. The official **mobile** SSO flow

No admin setup is needed. It relies on an undocumented contract.

1. Open one of:
   - `{site}/oauth/{service}/mobile_login?redirect_to=mmauth://callback` (`web/oauth.go` L505)
   - `{site}/login/sso/saml?action=mobile&redirect_to=mmauth://callback`
   
   `redirect_to` must start with a scheme listed in `NativeAppSettings.AppCustomURLSchemes` (default `["mmauth://","mmauthbeta://"]`, `model/config.go` L340). Otherwise the server returns 400 `api.invalid_custom_url_scheme` as an HTML page. `fullyQualifiedRedirectURL` (L586) only keeps it if it is exactly `<scheme>://callback`, with no path or query.
2. On success the server shows an HTML page (`RenderMobileAuthComplete`) that meta-refreshes after 2 seconds to:
   `mmauth://callback?MMAUTHTOKEN=<token>&MMCSRF=<csrf>&srv=<SiteURL>` (`web/oauth.go` ~L446, `web/saml.go` ~L297)
   - The same in v10.
   - **Check that `srv` matches the server you started with.**
3. The session is a mobile session: mobile length, and exempt from the idle timeout.
4. An admin can add e.g. `mattermac://` to `AppCustomURLSchemes` so you don't have to borrow `mmauth`.

### E. OAuth 2.0 provider: the only flow meant for third parties

It needs `ServiceSettings.EnableOAuthServiceProvider` (default **true** in both tags) **and a registered OAuth app**.

**Registering the app**
- Admin-created, or by any user with `manage_oauth`: `POST /api/v4/oauth/apps` with `{"name","description","callback_urls":[…],"homepage","icon_url","is_trusted","is_public"}` (`api4/oauth.go` L29).
  - `is_public` is **v11 only**: it creates the app with no secret.
  - `is_trusted` can only be set by a system admin; it skips the consent screen.
  - Manually created apps: **callback URLs must be http or https** (`model/oauth.go` L111).
- **v11 dynamic client registration (DCR):** `POST /api/v4/oauth/apps/register`, unauthenticated.
  - Needs `EnableDynamicClientRegistration=true` (default **false**) and optionally matches `DCRRedirectURIAllowlist`.
  - Body: `{"redirect_uris":[…],"token_endpoint_auth_method":"none"|"client_secret_post","client_name","client_uri"}`.
  - Success: **201** `{"client_id","client_secret"?,"redirect_uris","token_endpoint_auth_method","grant_types":["authorization_code","refresh_token"],"response_types":["code"],"scope":"user","client_name","client_uri"}`.
  - Errors: **400** `{"error":"invalid_client_metadata"|"invalid_redirect_uri"|"unsupported_operation","error_description"}`. This is RFC 7591 style, not an AppError (`api4/oauth.go` L348, `model/oauth_dcr.go`).
  - If `token_endpoint_auth_method` is omitted, the app is confidential.

**Discovery (v11 only)**
- `GET {site}/.well-known/oauth-authorization-server`, and any path suffix after it (`web/oauth.go` L33). Response, per `model/oauth_metadata.go` L40:
  ```json
  {"issuer":"<SiteURL>","authorization_endpoint":"<SiteURL>/oauth/authorize","token_endpoint":"<SiteURL>/oauth/access_token","response_types_supported":["code"],"registration_endpoint":"<SiteURL>/api/v4/oauth/apps/register (only if DCR on)","scopes_supported":["user"],"grant_types_supported":["authorization_code","refresh_token"],"token_endpoint_auth_methods_supported":["none","client_secret_post"],"code_challenge_methods_supported":["S256"]}
  ```
- If the provider is disabled: 501 as an **HTML** page (send `X-Mobile-App` to get JSON).
- **v10Δ:** the route doesn't exist. The SPA catch-all returns 200 `text/html` (`web/static.go` L50). Check the Content-Type before parsing.

**Authorize step**
- `GET {site}/oauth/authorize?response_type=code&client_id=<26>&redirect_uri=<exact>&state=<≤1024>&scope=user&code_challenge=<43–128 b64url>&code_challenge_method=S256` (`web/oauth.go` L130).
- If the user is not logged in: 302 to `/login?redirect_to=…` (or SAML when `login_hint=saml`).
- Then the webapp consent page, unless the app is trusted or was previously authorized.
- Then 302 to `redirect_uri?code=<52 chars>&state=…`. The code expires after **10 minutes**.
- For public clients, `code_challenge` is required (`api.oauth.allow_oauth.pkce_required_public.app_error`). Only `S256` is supported.
- `redirect_uri` must **exactly** match a registered callback (`slices.Contains`, `model/oauth.go` L174), including the port.

**Redirect URIs for a native app**
- **Custom schemes are rejected at authorize time in v11.11.1.** `AuthorizeRequest.IsValid` (`model/authorize.go` L119) requires `IsValidHTTPURL` (http:// or https:// prefix), and so do `AuthData.IsValid` L79 and `AccessData.IsValid` L56.
- The v11.11 changelog says: "OAuth Dynamic Client Registration (DCR) redirect URI validation now accepts custom (non-HTTP) URI schemes such as cursor:// … unblocking desktop OAuth clients". In this code that only covers *registration*.
- **Use a loopback redirect, e.g. `http://127.0.0.1:<fixed-port>/callback`.** Whether a custom scheme works end to end is UNVERIFIED on a live server; this code says it does not.

**Token step**
- `POST {site}/oauth/access_token`, `application/x-www-form-urlencoded` (`web/oauth.go` L239).
- Fields: `grant_type=authorization_code`, `client_id`, `code`, `redirect_uri`, `code_verifier` (43–128 characters), and `client_secret` for confidential clients only. A public client that sends a secret gets 400 `model.oauth.validate_grant.public_client_secret.app_error`.
- Response 200, with `Cache-Control: no-store`:
  ```json
  {"access_token":"<session token>","token_type":"bearer","expires_in":<seconds int32 = SessionLengthSSOInHours*3600>,"scope":"","refresh_token":"<'' for public clients>","id_token":"","audience":"<omitted if empty>"}
  ```
- Errors are AppError JSON (e.g. `api.oauth.get_access_token.expired_code.app_error`, `model.authorize.validate_pkce.verification_failed.app_error`), not RFC 6749 `{"error":…}`.
- **Public clients cannot refresh**: `model.oauth.validate_grant.public_client_refresh_token.app_error`. When the token expires, run authorize again; with a remembered consent and a live browser session it redirects immediately.
- Confidential clients refresh with `grant_type=refresh_token&refresh_token=…&client_id&client_secret`. The refresh token rotates.

**Using the access token**
- `Authorization: Bearer <access_token>`.
- The session has `IsOAuth=true`, scope `user` (full user access), and is exempt from MFA enforcement.
- Some endpoints refuse OAuth sessions: PAT creation, OAuth app management, `POST /oauth/authorize`.
- `?access_token=` in the query string is also allowed for OAuth sessions.

**v10Δ for the OAuth provider:**
- No PKCE, no public clients, no DCR, no `.well-known`.
- `client_secret` is mandatory at `/oauth/access_token` (400 `api.oauth.get_access_token.bad_client_secret.app_error`).
- So a native client on v10 needs an admin-created *confidential* app with the secret embedded in the binary, plus a loopback redirect.

### What a third-party app can and cannot do without admin help
- **Can:** password, LDAP and MFA login; user-supplied PATs; and piggyback on the official desktop flow (C) or mobile flow (D) for SSO accounts. C and D are not a supported third-party API and borrow official URL schemes.
- **Cannot:** use a sanctioned OAuth or PKCE flow without an admin (or a `manage_oauth` user) creating the app, or an admin enabling DCR (v11).
- **The clean setup:**
  - v11: an admin creates a **public** OAuth app (Integrations page or `is_public:true`) with the redirect `http://127.0.0.1:<port>/callback`. The client does authorization code + PKCE S256 with no secret and no refresh.
  - Alternatively the admin enables DCR, and the client self-registers with `token_endpoint_auth_method:"none"`.

---

## 8. Server version: `X-Version-Id`

- Set on every response that goes through `web.Handler.ServeHTTP` (`web/handlers.go` L244 in v11, L222 in v10), including 401 responses. It is missing on router 404s and on 429s from the global limiter.
- Format: `fmt.Sprintf("%v.%v.%v.%v", model.CurrentVersion, model.BuildNumber, ClientConfigHash, license != nil)`.
- Example: `11.11.1.<BuildNumber>.<hex hash>.true`.
- **Parse it as:** the first three dot-separated parts are the semantic version, and the **last** part is `true`/`false` (licensed). Don't rely on the middle parts.
- `BuildNumber` is `"dev"` for development builds. Whether `BuildNumber` can contain dots is UNVERIFIED.
- The hash changes whenever the client config changes; the webapp uses a change in this header to trigger a reload. **v10Δ:** the hash is md5 (32 hex characters); v11 uses sha256 (64 hex characters) (`app/platform/config.go` L243).
- The webapp only reads the header when `Cache-Control` is absent (`client4.ts` ~L4898).

---

## 9. v10.11.24 vs v11.11.1 differences

| area | v10.11.24 | v11.11.1 |
|---|---|---|
| `config/client` `format` | required (`old`) | ignored |
| `EnableSignUpWithGitLab` in limited config | always | only with an OpenId license feature |
| `device_id` at login | any string | must match `apple_rn…:` or `android_rn…:`, else masked 401 |
| `voip_device_id`, `magic_link_token`, `/users/login/type` | — | present |
| MFA-enforced exemption for `/users/me` | any method | GET only |
| PAT `expires_at` and `app.user_access_token.expired` | — | present |
| `MaximumPersonalAccessTokenLifetimeDays` config key | — | present |
| OAuth PKCE, public clients, DCR, `.well-known` | — | present (v11.2+) |
| `X-Version-Id` hash | md5 | sha256 |
| CSRF failure | 401 | 401 + cookie cleared |
| `IsNonProduction` license key, `IsFipsEnabled` config key | — | present |

---

## 10. UNVERIFIED items

- What `POST /api/v4/users/mfa` returns (404 or 405). It is not registered in either tag.
- The exact meaning of the `X-RateLimit-Limit` value.
- Whether `ASWebAuthenticationSession` captures the JS or meta-refresh navigation to `mattermost://` and `mmauth://`.
- Whether custom-scheme redirect URIs work end to end in v11.11.1. The code says no; the changelog implies yes.
- The units of `PostEditTimeLimit` (believed seconds) and `InstallationDate` (believed Unix ms).
- Whether `BuildNumber` can contain dots.

Scratch copies of all sources are in `/tmp/mm-research-auth/` (`v11.11.1/…`, `v10.11.24/…`, `changelog11.txt`, `users-*.yaml`, `en11.json`).