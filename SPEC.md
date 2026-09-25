# MatterMac — complete AI coding-agent specification

**Project:** MatterMac  
**Product:** An independent, open-source, native macOS client for existing Mattermost servers.  
**Implementation:** Swift application code, SwiftUI and AppKit, Apple system frameworks, Swift Package Manager.  
**Primary constraints:** Small distribution, bounded RAM, responsive UI, low idle CPU; account sign-ins in macOS Keychain; a bounded, encrypted on-device content cache for fast launch.  
**Specification date:** September 24, 2026.  
**Status:** Build instructions and proposed acceptance targets, not an implemented application or measured benchmark.

---

## 1. Mission and interpretation

You are the lead macOS engineer implementing MatterMac in this repository. Build a real, usable application, not a visual mockup, architecture exercise, or browser wrapper.

MatterMac replaces the Mattermost desktop interface. It connects directly to the user's existing Mattermost server using the user's normal account and the server's available APIs. Messages, channels, teams, permissions, attachments, search, and authoritative read state remain on that Mattermost server. Users of the official Mattermost application must be able to communicate with MatterMac users normally.

Do not build a new chat service. Do not introduce a hosted MatterMac account, backend, database, synchronization service, authentication proxy, analytics service, or media server. Do not require the official Mattermost desktop application to run alongside MatterMac.

The client is macOS-only. Use a minimum deployment target of macOS 14 initially. Build for Apple silicon and Intel where the selected stable Xcode toolchain supports that deployment target. Record exact toolchain and SDK versions; never infer runtime compatibility from a successful cross-compilation.

All application-owned runtime code and tests must be Swift. Swift calls into AppKit, Foundation, Image I/O, Core Graphics, AuthenticationServices, and other Apple system frameworks are allowed. “Written in Swift” refers to our implementation, not a claim that Apple's frameworks or macOS are implemented in Swift. Build configuration, property lists, asset metadata, Markdown, and minimal CI command glue are naturally allowed.

Per the explicit 2026-09-24 user request, persist verified account sign-ins (canonical server endpoint, user ID, bearer token and token kind) in macOS Keychain. Per the explicit 2026-09-25 user request, keep a bounded on-device cache of content that makes MatterMac fast to open: image bytes (avatars, team icons, attachment thumbnails and previews, custom emoji), the directory (teams, channels, memberships, sidebar categories, user profiles, relevant preferences), the last open team and channel, and the latest messages of recently opened channels (§7). Drafts, pending sends, pasted images, search, and local presentation settings stay session-only. Make the resulting tradeoffs clear in the UI.

Priority order when requirements conflict: security and correct user-visible behavior; protection against silently losing work during a running session; bounded resources; accessibility and native interaction; then optional features and visual effects. Do not “solve” a resource target by dropping messages, breaking input methods, or concealing an unsupported feature.

## 2. Non-negotiable implementation constraints

- No Electron, Chromium, WKWebView, embedded HTML interface, JavaScript runtime, React Native, Flutter, Tauri, Rust core, Go helper, or unofficial bridge to the official desktop process.
- No server component in the shipped product. A development-only Mattermost test instance is permitted; it is not a MatterMac backend.
- No SQLite, Core Data, SwiftData, Realm, `URLCache`/disk HTTP cache, automatic file logging, or UserDefaults-backed user state. Application persistence is limited to saved sign-ins in macOS Keychain and the encrypted, bounded `ContentCache` (§7).
- No `@AppStorage` or `@SceneStorage` for account, navigation, composer, or preference state. Disable relevant window restoration and text-document autosaving mechanisms.
- No unbounded arrays of history, event streams, worker tasks, retry queues, image buffers, search results, or user-directory records.
- No synchronous network or file operations on the main actor. No full-history Markdown parsing or image decoding on the main actor.
- No source or binary third-party dependency containing a bundled non-Swift runtime implementation without a new, explicit product decision. A Swift wrapper around C/C++ is not a pure-Swift dependency.
- Prefer zero external runtime dependencies for v1. Add a small pure-Swift package only when justified by tests, license review, transitive-source audit, and measured size impact. Do not add a large state framework, networking framework, or Markdown engine by habit.
- No bundled fonts, emoji atlas, language model, code-editor engine, video codec stack, telemetry SDK, or crash-reporting SDK in the initial product.
- No silent downgrade of TLS, no certificate-validation bypass, no credential scraping, and no bypass of administrator authentication or authorization policy.
- No claims of end-to-end encryption, zero forensic traces, exact-once network delivery, feature parity, or measured performance without supporting implementation and evidence.

A user-triggered system authentication session is allowed for supported browser-based login. It is not a webview-based application interface. Opening an unsupported feature in the user's browser is permitted only through an explicit, accurately labeled action; that does not count as native feature support.

## 3. Product scope and completion tiers

### Core messaging v1

Implement server connection, supported account login, team and channel navigation, public/private channels the user may access, DMs and group DMs, paginated history, sending, editing, deleting, replies and threads, reactions, mentions, unread indicators, server search, attachment upload/download, basic native formatting, and robust reconnect behavior.

Include a usable native keyboard workflow, text selection and copying, accessibility labels, dark/light appearance, and session-only drafts. Basic user profiles, channel information, membership-aware actions, and system-post presentation are part of the usable product, not merely placeholder menus.

Make single-server messaging work first. Add multiple independently authenticated server sessions before claiming multi-server support. Use a default maximum of three connected sessions and one active account per configured server slot, with explicit disconnect/reconnect behavior. Namespace all state by server and account, even in the first milestone.

### Capability-dependent functionality

SSO, OAuth, custom emoji, collapsed-thread behavior, channel categorization, plugin-backed actions, guest access, custom statuses, and advanced search depend on server version, configuration, permissions, or deployment. Implement verified capabilities and explain unsupported states. Do not substitute a success-looking interface for a missing implementation.

### Explicitly not native v1 features

Mattermost Calls, screen sharing, camera calls, arbitrary webapp plugins, Boards, Playbooks dashboards, enterprise administration, custom theme CSS, and background notifications after the app quits are outside the native messaging v1 commitment.

Show a clear compatibility page for these features. A call-related post must remain readable; a “Join in browser” action must be labeled as external. Do not silently bundle WebRTC or introduce a browser engine to satisfy a checkbox. Section 20 defines the later calls decision.

No implementation milestone is complete just because a static mock looks correct. End-to-end messaging must be verified against an actual Mattermost instance and an official client in an authorized test environment.

## 4. User experience and application behavior

### First launch

Present MatterMac branding, a server URL field, and a short disclosure: “MatterMac saves account sign-ins in macOS Keychain. Signing out removes the saved sign-in. Messages and drafts stay in memory only; quitting discards them. Your server stores sent messages.” On subsequent launches, show progress while revalidating saved sign-ins and a retry action for temporary failures.

Do not request a microphone, camera, contacts, full-disk access, or notifications at launch. Do not sign the user up for another service. No splash animation or network request should prevent the initial connection screen from appearing.

Normalize the supplied server URL carefully. Preserve a reverse-proxy subpath, support a custom port, reject embedded credentials and inappropriate schemes, and show the final origin before sending credentials. A server at `https://chat.example.org/company/chat` is not necessarily hosted at the origin root.

### Main window

Use a compact three-region layout: team/channel navigation, active conversation, and an optional thread or details panel. Add a small server switcher when multiple sessions exist. Prefer native split views, toolbar controls, menus, focus behavior, and SF Symbols rather than copying the official web client's entire visual design.

Provide a clear channel header, member/status information on demand, an unread boundary, message list, composer, reply context, pending-send state, connection state, and a jump-to-latest action.

Opening the thread panel must not discard the main timeline's anchor. Switching servers must immediately switch the visible session identity; late responses from the old session must not appear in the new one.

### Interaction rules

Use Command-K for a quick switcher, Command-F for search, Escape to dismiss a transient panel, Shift-Return for a newline, and Return to send only when the composer is not accepting an input-method composition or completion. Provide normal menu equivalents and configurable-in-session send behavior. Do not override standard macOS editing shortcuts casually.

Preserve drafts and selection while switching channels within the same running session. Warn on explicit quit/sign-out when unsent content exists. Explain that crashes and forced termination cannot restore a RAM-only draft. Never claim durable offline sending.

When the user is reading old history, incoming posts must not pull the viewport to the bottom. Show an unread/new-message indicator. Auto-follow only when the user is already at the live edge or has explicitly jumped there.

Use progressive loading, accurate empty states, retry affordances, and inline errors. Avoid spinner-only interfaces without explanations. Failed or uncertain sends must remain distinguishable from confirmed messages.

### Native quality

Support resizing, Retina scale changes, dark/light appearance, increased contrast, reduced motion, VoiceOver, keyboard-only navigation, and standard copy/paste. Use native menus for message actions and normal file panels for attachments.

Read and respect server-side preferences where supported. Do not write server preferences merely to persist MatterMac's own window geometry, local cache choices, or theme. Explicit server preference changes must be distinguishable from temporary local presentation changes.

## 5. Repository structure

Use one monorepo with a normal macOS application project and one local Swift package containing focused targets. Avoid one package per tiny type and do not create unused abstraction layers.

```text
MatterMac/
├── SPEC.md
├── AGENTS.md
├── README.md
├── LICENSE
├── SECURITY.md
├── CONTRIBUTING.md
├── MatterMac.xcworkspace/
├── Apps/
│   └── MatterMac/
│       ├── MatterMac.xcodeproj/
│       ├── Sources/
│       │   ├── MatterMacApp.swift
│       │   ├── AppDelegate.swift
│       │   └── AppComposition.swift
│       ├── Resources/
│       │   ├── Assets.xcassets/
│       │   └── Localizable.xcstrings
│       └── Configuration/
│           ├── Info.plist
│           ├── MatterMac.entitlements
│           └── Release.xcconfig
├── Packages/
│   └── MatterMacKit/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── MatterMacModels/
│       │   ├── MattermostAPI/
│       │   ├── MattermostRealtime/
│       │   ├── MatterMacCore/
│       │   ├── MatterMacUI/
│       │   └── MatterMacPlatform/
│       └── Tests/
│           ├── ModelsTests/
│           ├── APITests/
│           ├── RealtimeTests/
│           ├── CoreTests/
│           ├── UITestsSupport/
│           └── TestSupport/
├── Tests/
│   ├── MatterMacUITests/
│   ├── Integration/
│   └── Fixtures/
├── Tools/
│   └── MatterMacDev/
│       ├── Package.swift
│       └── Sources/
├── docs/
│   ├── architecture.md
│   ├── compatibility.md
│   ├── authentication.md
│   ├── privacy.md
│   ├── performance.md
│   ├── threat-model.md
│   ├── progress.md
│   └── decisions/
└── .github/workflows/
```

Check in shared Xcode schemes and a reproducible project configuration. The workspace references the app and local package. Xcode must open and build the app without a hidden generator or proprietary development service.

Boundaries:

- `MatterMacModels`: typed identifiers, server/account scope, domain values, DTO-independent presentation-neutral types. No AppKit or SwiftUI.
- `MattermostAPI`: HTTP request construction, authentication transport, bounded response handling, API DTOs, error decoding, upload/download transport, rate-limit policy, and injectable service interfaces.
- `MattermostRealtime`: WebSocket lifecycle, envelopes, ordered event consumption, liveness, reconnect/resume, and a testable event-source interface. Do not duplicate the app state here.
- `MatterMacCore`: session coordination, normalized state, reducers/state transitions, RAM budgets, history windows, send reconciliation, command execution, and compact view updates. It may depend on Models/API/Realtime; it must not depend on UI or AppKit.
- `MatterMacUI`: SwiftUI shell, reusable AppKit timeline/composer, view models and UI-specific layout. No direct `URLSession`, login transport, file writes, or server permission enforcement.
- `MatterMacPlatform`: file-panel adapters, system authentication presentation, lifecycle hooks, explicit external navigation, and optional notifications. Inject these into coordinators; do not make Core import AppKit.
- `Apps/MatterMac`: composition root, application lifecycle, menu wiring, and scene setup. Keep it small.
- `TestSupport`: test-only transport fakes, clock, IDs, server fixtures, and event replay. Do not link fixtures into the release app.

An extra shared transport target is allowed if real duplication appears. Otherwise use a few clear protocols and constructor injection. Do not create a service locator singleton or a global mutable account store.

## 6. Swift, concurrency, and state ownership

Use Swift 6 language mode with strict concurrency checking. Select and pin an actually available stable Xcode/Swift toolchain; document defaults that affect actor isolation. Do not silence concurrency problems with blanket `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, or warning suppression.

Keep UI-bound observable models on `@MainActor`. Keep network state, caches, parsing, reconciliation, and CPU work in clearly owned non-main contexts. A `Task` created from a main-actor view may inherit that isolation; declaring a function `async` does not establish that its work leaves the main actor. Verify the toolchain's isolation behavior and explicitly structure expensive work accordingly. [S8]

Prefer structured concurrency, cancellation, actors for owned mutable state, immutable `Sendable` values across boundaries, and small observable view models. Avoid one task for every cached message or every arrival in a busy channel.

Use session epochs and request generations. After switching account, signing out, replacing a socket, or abandoning a channel load, reject stale results even when task cancellation arrives too late. An actor method can suspend and allow state to change; validate the epoch after relevant awaits.

Keep entities normalized by scoped IDs. Store one canonical post payload per retained post, not a copy in the timeline, search screen, thread panel, and pending-send list. Maintain references where useful, but ensure those references do not accidentally pin entire histories.

The UI receives bounded snapshots or incremental patches of visible data. Do not copy the full session graph for every typing event. Do not trigger a whole sidebar rebuild because one reaction changed. Use stable identity based on server/account and post ID, never a new random UUID during each render.

Caches, delegates, notification observers, retained task handles, continuations, and closures must have documented lifetimes. Add deallocation/lifecycle tests for session teardown. Check for actor-task and URLSession-delegate retain cycles.

Use typed errors and explicit state machines instead of strings scattered across views. Distinguish authentication failure, permission denial, unsupported capability, transport loss, cancellation, malformed data, rate limiting, and unknown send outcome.

## 7. Keychain sign-ins and the on-device content cache

### Application-controlled persistence

Persist verified sign-ins in macOS Keychain: bearer token and kind, canonical server endpoint, and expected user ID. Never persist passwords. Do not move persistence to iCloud or an app-controlled remote service.

Keep an on-device content cache (user request, 2026-09-25) so launch and channel switches show content before the network answers:

- Scope: compressed image bytes of resources that are immutable under their key (profile image and team icon per revision, file thumbnail/preview, custom emoji; never proxied external images); a directory snapshot (teams, channels, memberships, categories, profiles, name-format/clock/favorite/hidden/saved/link-preview preferences, last open team and channel); and the newest `postsPerChannel` posts (plus their thread roots) of up to `channelsPerAccount` recently opened channels. Never drafts, pending or failed sends, pasted images, search, typing, presence, or local presentation settings.
- Storage: the app's Caches directory (inside the sandbox container), excluded from backups, one directory per account named by a digest of server and user. Every file is sealed with AES-GCM under a random per-account key in the login Keychain (not synchronized); kind and name are authenticated. A file that does not open is deleted.
- Bounds: `ResourceBudget.diskCache` media bytes/entries, content bytes/entries and a per-object limit, enforced by cost-tracked LRUs whose recency survives relaunch.
- Semantics: cached content is a starting point, never the truth. Sessions restore the directory before their first request and still fetch every channel list; a channel window seeded from the cache is marked `isCached`, is replaced by the server's first page, is never written back, and never marks the channel read. Only windows loaded from the server and at the live edge are written.
- Lifetime: Quit writes the cache. Sign Out, a server-ended session, and a saved sign-in rejected at restore remove that account's files and key. Settings ▸ Accounts shows the cache size and offers Clear Cache. Membership loss removes the channel's cached posts.

Use `URLSessionConfiguration.ephemeral` for API, WebSocket, and media requests. Apple documents that ephemeral configurations do not persist their caches, cookies, or credentials. Additionally disable the URL cache and shared credential storage where appropriate, and avoid shared cookie jars. Keep required authentication cookies in an isolated session-only store, not a process-global or disk store. [S5]

Do not use `URLSession.shared`, background transfer sessions, shared `URLCache`, disk-writing image libraries, cached Quick Look previews, or download-task temporary files for automatic previews. Audit the actual chosen APIs; naming a custom dictionary “memory cache” is not a privacy audit.

Save verified password-login, browser-SSO and PAT sign-ins in the local macOS Keychain by default; do not synchronize them to iCloud. Validate `/users/me` against the saved user ID before restoring an account. Quit closes transports without server logout. Explicit Sign Out removes the saved sign-in before ending the server session; expired or mismatched credentials are removed. Transient failures preserve saved credentials and offer retry. Bound saved account count and encoded bytes through ResourceBudget. Keep secrets out of URL query strings, analytics, errors, clipboard inspection, process arguments, and logs. Minimize password lifetime; Swift strings may have copies and must not be described as securely zeroized merely because a variable was reset.

### Explicit user actions

A user choosing Save Attachment, Copy Message, or Export Diagnostics authorizes that specific external action. Use native destination selection and describe what will be written. A downloaded attachment may be streamed to the chosen destination with bounded memory; do not accumulate the whole file in RAM to preserve a simplistic “no disk” claim.

For uploads, read a user-selected file through a scoped handle; do not copy it into an app staging directory. Keep the handle only as long as required. If the file changes or becomes unavailable before upload completes, report it. Do not persist security-scoped bookmarks.

Pasted image data remains session-only, with an explicit memory cap. At a cap, reject the new operation with an explanation instead of silently writing temporary data or deleting an older draft.

### OS boundaries and notifications

Promise “application-managed persistence is limited to the Keychain sign-ins and the encrypted content cache,” not “no other bytes ever reach disk.” macOS swap, system diagnostics, filesystem metadata, the system authentication service, browser history, file dialogs, clipboard managers, and Notification Center are outside that absolute guarantee. Document what was audited and what remains outside the application boundary.

Disable native OS notifications by default in strict session mode. Use in-app badges and optional in-app sounds. Enabling Notification Center must be an explicit exception with a disclosure that the OS may retain delivered notifications. Default such notifications to generic text, with no message contents or attachment thumbnails. Do not put a secret into notification identifiers or userInfo. Clear app-delivered notifications on logout where possible without claiming guaranteed erasure.

Use `ASWebAuthenticationSession` with an ephemeral-session preference where supported, and explain authentication-service limitations. Never assume this provides an absolute no-storage guarantee for an IdP or the OS.

Release diagnostics stay in a bounded in-memory ring containing redacted categories, durations, counters, and non-sensitive codes. No automatic file logs, unified-log message contents, telemetry, or crash uploads. Developer-enabled Instruments captures and explicitly requested test reports are separate from normal user operation.

On logout, first remove the saved Keychain sign-in, remove the account's cached content and cache key, then cancel requests and tasks, close sockets, discard session stores, clear text undo buffers and previews, remove relevant delivered notifications, and reset the visible account context. Attempt appropriate server-side session logout when possible. Discarding a PAT locally is not revoking it; never revoke a user's PAT without an explicit action. If offline, explain that server logout could not be confirmed.

## 8. Connection, authentication, and server compatibility

Mattermost publishes a REST API for clients and third-party applications, including session-token login and a WebSocket interface. Use this integration model rather than scraping the webapp or operating as a bot. [S1]

Before implementing an endpoint, consult the current official reference and, where needed, the matching server source. Pin source citations to the tested release/commit in `docs/compatibility.md`. A moving `master` branch is research material, not evidence of support in every released server.

### Server discovery

Probe the selected Mattermost base URL using the documented public configuration/system endpoints applicable to the target version. Do not require administrator API access for discovery. Capability probing must be bounded, rate-limited, and non-mutating.

Support HTTPS and normal OS trust evaluation, including an organization-managed trusted CA. A development-only loopback HTTP mode is allowed behind an explicit development setting. Do not introduce a blanket ATS exemption or accept any certificate in production.

Preserve subpaths in REST, WebSocket, files, permalinks, and auth callbacks. Build URLs with URLComponents/path components and test escaping. Do not concatenate user input into endpoint paths. Prevent cross-origin redirects from carrying bearer tokens or cookies; detect a canonical-server redirect before credentials are sent.

### Login methods

Implement password login where enabled, including the server's supported email/username/LDAP identifiers and MFA flow. The documented login endpoint is `POST /api/v4/users/login`; successful session login provides a `Token` response header used as a bearer token. Read headers case-insensitively and follow the tested server's successful response behavior rather than assuming one status from an old example. Verify `/api/v4/users/me` after authentication. [S1, S2]

An advanced user-supplied personal access token flow is permitted only where the server and account policy allow it. PAT support is not a universally available fallback; administrators control availability and permissions. Do not automatically create a PAT or ask for administrator credentials. Keep the token in RAM and explain its server-side lifetime. [S3]

Build an authentication adapter for supported browser-based login. Prefer an audited public-client OAuth authorization-code flow with PKCE when the server supports it and the required app registration/redirect configuration exists. Use state validation, callback binding, one-time codes, strict redirect handling, and cancellation. Never embed a client secret in a desktop binary.

Mattermost's v11 changelog documents OAuth PKCE additions and conditional discovery/dynamic registration. Do not assume older deployments have them, automatically register clients on every server, or interpret server OAuth-provider capability as proof that every organization's SAML/OIDC login works with MatterMac. [S4]

The current API source also includes desktop-token login and evolving SSO flows. Treat these as version-dependent options requiring end-to-end validation, not interchangeable token-extraction tricks. Do not claim the official client's callback scheme as MatterMac's own or intercept another application's login. [S2]

SSO-only deployments without a verified supported native flow must receive an accurate explanation. Core password/PAT test coverage does not count as SSO support. Do not ask users to disable MFA, paste browser cookies, inspect local credential databases, or weaken enterprise policy.

### Compatibility contract

Record exact tested server releases, auth methods, enabled features, deployment path, and OS versions. Test at least two supported server release lines when feasible; do not hardcode “all Mattermost versions.” Prefer feature detection plus tested version checks to license-name guessing.

Treat 401 as reauthentication/revocation according to the endpoint. Treat 403 as permissions/policy, not necessarily an expired token. Treat 404 as ambiguous without leaking private resource information. Unknown configuration or permission state is not permission granted.

## 9. API transport and data models

Use Foundation `URLSession` with an injectable transport for tests. Avoid Alamofire, generated megaclients, and copying an entire official client SDK into the app. Implement the subset used by actual UI milestones.

Use typed `Codable` wire models and explicit mapping to domain values. Mattermost IDs are opaque strings, not necessarily UUIDs. Represent timestamp units explicitly; do not confuse Unix milliseconds with seconds. Decode missing optional fields and unknown enum values safely, while rejecting missing identity and authorization-critical data.

A `PostList` includes an order and a post map; do not assume dictionary iteration is timeline order. Preserve server ordering and membership context. Avoid decoding arbitrary plugin props into an unbounded `[String: Any]`; use a bounded JSON value representation or ignore unused fields without retaining the raw response.

Implement request IDs, safe error decoding, timeout policy, cancellation, in-flight deduplication for identical reads, and per-server concurrency limits. Honor documented rate-limit signals and Retry-After when present. Backoff safe reads with jitter; do not blindly retry writes whose result is unknown.

Set response size budgets before consumption, verify actual received/decompressed size during consumption, and cancel oversized responses. Content-Length alone is not a bound. Use bounded streaming/delegate paths for large content; restrict eager `data(for:)` use to bounded responses. Streaming implementations must be tested for actual memory and disk behavior.

Keep an endpoint matrix documenting method, path, parameters, response model, auth requirement, permissions, tested versions, and tests. The initial matrix should cover login/me/logout, team/channel navigation, posts/history/threads, members/profiles as needed, reactions, channel views/unread state, search, and files. Add optional endpoints only when their feature is implemented.

Do not invent routes for actions merely because their names look plausible. Respect server-side permissions on send/edit/delete/join/leave/reaction/file actions. Optimistic UI never overrides the server's authorization decision.

## 10. Realtime connection and synchronization

Use `URLSessionWebSocketTask` and the real Mattermost `/api/v4/websocket` protocol, not Socket.IO. Choose a supported native authentication mechanism such as an authorization header or the documented authentication challenge. Keep tokens out of query strings. [S1, S6]

Implement explicit states: disconnected, connecting, authenticating, synchronizing, connected, backing off, and authentication required. Keep one owned receive loop and liveness controller per connected server session. Avoid duplicate reconnect tasks after a timeout, wake event, and network-path change occur together.

Consume envelopes in order. Handle at least hello, posted, post_edited, post_deleted, reactions, typing, status changes, channel/member changes, read-state changes, relevant preferences, and thread updates when supported. Some event fields contain serialized JSON strings; decode the correct wire representation with bounds and tests.

Ignore or summarize unknown events without crashing. A single unknown optional property must not break login. Malformed identity or untrusted payload bounds must not be ignored in the name of compatibility.

Distinguish client action sequence/reply IDs from server event sequence. The current official client supports connection-ID and sequence-based recovery and performs missed-event handling when recovery fails. Implement only the semantics verified for supported server versions. A sequence number is not an eternal durable cursor or a timestamp. [S7]

Attempt supported session-memory resume first. On a new connection identity, sequence gap, unavailable resume, or event-buffer overflow, mark affected data stale and reconcile through REST. Recheck identity/membership, channel summaries, the active history window, open threads, and pending writes. Load other channels lazily.

The posts `since` mode is not interchangeable with normal paginated history: the API source documents incompatible pagination parameters, a capped response, and potentially nonconsecutive results. Do not implement “fetch since last timestamp” as proof that every gap and deletion is resolved. Use overlapping reconciliation plus bounded fresh windows and explicit stale markers. Do not rely on administrator-only deleted-post access. [S9]

Protect the initial REST snapshot/WebSocket race by establishing a defined buffering and merge procedure. Never discard an arriving edit because an older snapshot finishes later. Use post update/delete state, request generation, and authoritative refresh where ordering is ambiguous. Test both event-before-response and response-before-event paths.

Mattermost may send account-visible events for many channels. Do not invent a per-channel subscription API to reduce them. Bound event processing; keep inactive channel summaries lightweight and hydrate details only when needed. Missing fine-grained updates should lead to refresh, not unlimited buffering.

Use a bounded mailbox with item and byte accounting. Coalesce replaceable typing/status events. Do not silently drop durable post/edit/delete or membership changes. When durable processing cannot keep up, intentionally invalidate affected state, recover, and show connectivity state instead of accumulating unbounded memory.

After macOS sleep, reconnect and reconcile; do not immediately mark everything as read. With no network, allow access only to content already in RAM and label it stale. Quitting loses that local history.

## 11. Sending, edits, deletes, and session-only drafts

Represent pending sends explicitly: queued in this session, uploading, sending, confirmed, failed, or outcome unknown. Preserve pending content when changing channels. Show per-item retry/cancel controls; never display “sent” just because bytes reached a socket.

Use a stable client pending-post identifier for one logical send, following the server's accepted format. Merge REST confirmations and WebSocket echoes into one canonical post. The current server source uses `pending_post_id` for deduplication within a cache window; that is not an indefinite exactly-once guarantee. Test the target versions and do not invent a permanent Idempotency-Key contract. [S10]

A timeout after upload or POST can mean success with a lost response. Keep an unknown-outcome state, attempt bounded reconciliation, and avoid silent endless retries. Where certainty is unavailable, present a user retry decision that explains the possible duplicate. Do not merge unrelated messages merely because their text is identical.

Use actual server limits for message text, attachment count/size, editing windows, and permissions where discoverable; combine them with client resource limits and show which limit was reached. Preserve input on validation errors.

Editing and deleting must handle permission changes and races with other clients. Confirm destructive deletion and preserve a failed edit in session memory. Distinguish a deleted post placeholder from an inaccessible channel without disclosing restricted data.

Drafts are keyed by server, account, channel, and optional root thread. Never autosave them to server draft endpoints under the guise of “no local storage” unless the user explicitly requests a separate server-draft feature later.

Set an explicit total draft/pending-text budget and combined draft/pending item count. Do not evict unsent text as an ordinary LRU cache item. When the budget is reached, stop accepting new queued operations gracefully and let the user send, discard, or explicitly copy existing content. Intercept a large paste before materializing avoidable duplicate buffers.

## 12. History, threads, unread state, and search

Fetch a small initial history page, then page around known anchors using supported before/after parameters. Retain a bounded working window. Track gaps explicitly: an evicted range is not an empty range.

Keep compact post identity and window information, but cap those structures too. “We evicted the message strings” is insufficient if millions of IDs, height estimates, or tombstones still accumulate.

Use a stable post-ID plus pixel offset anchor when prepending, trimming, reflowing, or changing scale. Reserve preview dimensions before decoding images. A resize may invalidate layout; recompute incrementally rather than measuring the whole server history.

Threads use root IDs and the relevant supported APIs. Fetch an opened thread on demand and keep its budget separate within the overall process budget. Support edited/deleted roots, permissions changes, and very long threads without loading them in full. Where collapsed-thread semantics differ, document the supported behavior.

Mark a channel or thread read only under a defined visibility policy: the app is active, the correct conversation is visible, and the relevant content has been exposed to the user. Do not mark messages read merely because data was fetched or the app received a WebSocket event. Follow the actual server read-state model and reconcile changes from other clients; do not invent arbitrary per-post receipts where the API does not provide them.

Read/unread commands are mutating server operations and must handle errors. Do not retry an old “viewed” request in a way that marks newly arrived unseen messages read. Capture operation context and reevaluate when necessary.

Search belongs on the Mattermost server, not a local full-history index. Debounce input, cancel superseded searches, paginate, and cap retained results. Preserve native keyboard navigation and open results by real permalink/channel/thread context. Respect the server's supported query grammar and permission behavior.

## 13. Native rendering architecture

Use SwiftUI for the application shell, lightweight navigation, settings-in-session, sheets, and small controls. Use AppKit for the high-volume message timeline and the composer through small, well-contained representable bridges.

Start with a view-based `NSTableView` in an `NSScrollView` for the timeline, with reusable cells and variable row heights. AppKit supports view reuse; explicitly reset reused cell state and cancel stale per-cell work. This architecture is a starting decision, not a claim that every SwiftUI list is slow or every table is fast. Measure the actual implementation. [S11]

Do not create one SwiftUI hosting tree or text-layout object for every post in retained history. Do not use a `ScrollView` plus an ever-growing stack as virtualization. Bound retained data separately from visible row creation.

Expose rows by stable post identity and revision. Update inserted/deleted/changed rows rather than calling reloadData on every event. For a large reconciliation, one bounded snapshot replacement is acceptable when it preserves selection and anchor state.

Maintain a byte/count-bounded row-height cache keyed by post revision, grouping context, width bucket, font scale, and attachment layout. Do not cache a separate measurement for every fractional width during dragging. Measure visible/near-visible content first, update estimates incrementally, and test scroll anchoring when actual heights arrive.

Use attributed text with native text layout for readable messages. Support selection within messages and code blocks, reliable Copy Text/Copy Link actions, and a deliberate multi-message selection/copy interaction. Do not claim continuous drag selection across virtualized cells until implemented and tested. Preserve useful VoiceOver traversal when rows are recycled.

Choose TextKit behavior appropriate to the minimum deployment target and test it; do not mix layout engines casually or assume a versioned API is available on all supported systems.

Use a native `NSTextView`-based composer for selection, input methods, undo/redo, dictation integration where permitted, spelling behavior, and proper keyboard handling. Keep the source text as the editing model; do not rewrite the whole attributed text on each keystroke and destroy marked text or selection.

Cap composer undo history and account for retained large edits. Clear undo content on logout. Do not enable document autosave or silently persist spelling/input personalization through app-owned mechanisms. Document any system-managed input behavior that remains outside app control.

Input-method tests are mandatory: Japanese and Chinese composition, Czech diacritics, emoji/grapheme deletion, combining marks, Arabic/Hebrew mixed with Latin text, multiline paste, and keyboard shortcuts while a completion menu is open. Treat Enter as composition confirmation when appropriate, not Send.

No display-link-driven redraw loop for ordinary text chat. No perpetual timeline timer or full-window animation while idle. Relative-time labels update at their next meaningful boundary and only when visible. Coalesce benign UI updates without delaying explicit user actions.

## 14. Markdown, attachments, images, and untrusted content

### Text formatting

Implement a documented safe native subset: plain paragraphs, emphasis, strong text, inline code, fenced code blocks, block quotes, lists, links, mention highlighting, and basic message attachments. Tables and unsupported constructs may receive a readable plain-text/monospaced fallback; do not silently lose content or claim complete Markdown parity.

Start by evaluating Foundation's Markdown/AttributedString capabilities for that subset. Add a small tested Swift parser for required gaps only when needed. No HTML importer, JavaScript syntax highlighter, or web renderer. Inspect transitive implementations before adding a package advertised as a “Swift Markdown library.”

Bound nesting, token count, input length, parser work, code highlighting, and output attributed spans. Parse once per content revision off the main actor where safe. Cache only useful bounded render results. A giant message should collapse into a readable preview with an explicit expand action, not freeze the entire channel.

Distinguish display text from destination URLs. Open links only on explicit action with a safe scheme policy. Never execute a custom scheme or local file path merely because it appeared in a post. Do not attach server credentials to external links, avatars, or image URLs.

### Image pipeline

Request server thumbnails/previews where supported and appropriate. Downsample with Image I/O to display-sized pixel dimensions before retaining decoded image data. Respect orientation, backing scale, and source metadata limits. Do not decode a 40-megapixel image merely to show a small avatar.

Budget compressed and decoded images separately. Estimate decoded cost using actual row bytes and pixel height, and include additional retained representations. A 2048-by-2048 four-byte pixel buffer alone is 16 MiB; multiple copies are additional cost.

Use an explicit cost-tracked LRU or equivalent with deterministic eviction. `NSCache` may be used as an opportunistic secondary mechanism, but its documented cost/count limits are not strict resource caps. Do not rely on them as your only memory-budget enforcement. [S12]

Set decode concurrency, source-pixel, compressed-size, decoded-size, and outstanding-request limits. Cancel or deprioritize off-screen work. Release cell image references, task results, and layer contents when no longer needed. Do not keep every avatar in an unbounded global dictionary.

Animated previews are paused by default or limited to explicit interaction/visibility, with decoded-frame limits. No automatic video playback or full original-image download. Third-party inline images and URL previews are not fetched directly without a privacy-aware policy; prefer trusted server-provided metadata and explicit user actions.

### Files

Upload user-selected files directly with bounded streaming. Build multipart bodies as streams rather than concatenating the whole file into Data. Handle stream recreation/retries deliberately, content length, cancellation, and partial failure without hidden disk staging. Test whether Foundation behavior meets this requirement for the chosen transport path.

Keep uploaded server file IDs in pending-send state until attached to a confirmed post. Do not present an uploaded-but-unposted file as a sent message. Document orphaned-upload behavior supported by the server; do not invent a cleanup endpoint.

For explicit downloads, stream to the user-selected destination. Account for partial outputs and remove/retain them only according to a documented cancellation policy. Avoid path traversal, unsafe filenames, overwrite surprises, and automatic executable opening. Never place credentials in saved filenames or public share URLs.

In-app previews use the bounded image pipeline and its content cache, never an ad hoc file. Opening a downloaded file in another application is an explicit handoff outside MatterMac's boundary. Do not secretly materialize a temporary file to feed Quick Look.

## 15. Resource budgets and backpressure

All values below are initial engineering budgets, adjustable only through measured evidence and documented product tradeoffs. They are not promises that the unbuilt app already meets them.

Define the policy centrally as `ResourceBudget`, inject it into sessions and workers, and expose debug counters. Count limits alone are insufficient when items vary in size. Approximate heap-cost accounting is useful for eviction, but whole-process measurement remains necessary.

| Resource | Initial policy |
|---|---|
| Active timeline records | About 300 retained posts, additionally constrained by an 8 MiB estimated content budget |
| All retained post content | 2,000 posts or 16 MiB estimated cost, whichever is reached first; includes thread/search retention |
| Decoded images | 32 MiB total, lazily used, not preallocated |
| Compressed image data | 8 MiB total, with a smaller per-object limit where practical |
| Text/layout caches | 8 MiB total plus a count limit |
| Draft and pending text | 4 MiB total and at most 100 drafts plus pending operations; never silently LRU-evicted |
| Pasted-image pending data | 8 MiB total; large local files use streaming handles instead |
| Profiles/channel/member details | 8 MiB estimated detail budget; compact sidebar rows are also bounded/paginated |
| Normal API requests | At most 6 concurrent per server and 10 globally; reserve capacity for interactive actions |
| Attachment transfers | At most 2 concurrent globally, using bounded chunks |
| Image decoding | At most 2 active jobs globally |
| WebSocket message | Initial 2 MiB receive ceiling, reviewed against real supported-server payloads |
| Pending realtime mailbox | 512 items or 2 MiB, whichever comes first |
| Diagnostic ring | 256 KiB, redacted, in RAM only |
| Connected server sessions | 3 by default; shared global budgets, not a full independent budget per server |

Numbers for overlapping caches must not be double-allocated blindly. Reserve shared memory for transient decoding, received responses, and visible text objects. Global limits apply across windows, open threads, and server sessions.

When a legitimate server payload exceeds a client cap, fail visibly and provide a safe limited presentation or explicit alternative. Do not enter an endless reconnect loop against the same oversized event. Never silently truncate a message being sent.

Cache pressure policy: discard off-screen decoded images first, then derived layouts and speculative results, then inactive history windows; keep the currently visible content and in-session unsent work within their own budgets. At critical pressure, cancel speculative tasks and reduce retained windows. Do not depend on a pressure notification to begin normal eviction.

Every queue must specify capacity, item cost, producer behavior, consumer ownership, cancellation, and full-queue behavior. An actor is not automatically a bounded queue. An unbounded AsyncStream or thousands of tasks awaiting an actor can still exhaust memory.

For coalescible UI state, a latest-value channel is acceptable. For durable events, either process with backpressure or signal state invalidation and reconcile. If using bounded AsyncStream buffering, handle dropped-yield results explicitly; ignoring them is not reliable delivery.

Time-based expiry must not require scanning all entries every second. Prefer access-based expiration, a single scheduled expiry mechanism, or incremental pruning with bounded work.

## 16. Performance acceptance targets

Establish a reproducible reference profile: a physical Apple silicon Mac, release build, one connected server, one normal-sized window, 60 Hz refresh unless otherwise specified, no debugger, no profiler for primary timing runs, and a documented fixture corpus. Record RAM size, chip, OS, build flags, and server/network conditions.

| Metric | Proposed initial acceptance target |
|---|---|
| Text-only app archive, one architecture | At most 15 MiB compressed |
| Installed app bundle, one architecture | At most 40 MiB |
| Optional universal archive/bundle | Report separately; do not compare it to a single-architecture artifact |
| Logged-in idle physical footprint | At most 70 MiB after settling, without retained heavy previews |
| Typical active conversation footprint | At most 140 MiB under the defined mixed-text/thumbnail workload |
| Media-heavy bounded stress workload | At most 220 MiB peak under the documented test, followed by a stable lower plateau |
| Launch to usable connection screen | p95 below 800 ms, excluding first-run OS security checks and network login |
| Switching to a retained channel | p95 below 80 ms |
| Input responsiveness | p95 key-to-visible-update below 16 ms on the reference setup |
| Scrolling | No persistent frame hitches; meet a 16.7 ms frame budget at 60 Hz and report 120 Hz separately |
| Idle CPU | Below 0.5% of one logical core on average over a settled five-minute window, including liveness work |
| App-managed content persistence | Only Keychain sign-ins and the bounded, encrypted content cache (§7); explicit exports and OS-managed artifacts are reported separately |
| Long-running resource behavior | No continuing growth in retained objects, tasks, queues, or cache cost after repeated workload cycles reach steady state |

These targets are not correctness shortcuts. If a target is missed, provide the measurement, dominant contributors, investigated changes, and the tradeoff. Do not silently change the test corpus, suppress accessibility, disable TLS, omit images from an image benchmark, or remove a feature to manufacture a pass.

Measure memory using a named, consistent metric such as physical footprint and report RSS/allocations separately. Count the main app and any app-owned helper process. Explain system rendering resources and shared-memory limitations rather than adding incomparable numbers. The architecture should not need a custom helper process.

Use Instruments Time Profiler, Allocations, Leaks, memory graphs, hangs/hitches tools, and SwiftUI performance tooling where available. Instrument logical phases with content-free development signposts: decode, state merge, row layout, channel switch, send confirmation, and image downsample. Apple's SwiftUI tooling can expose excessive or long-running updates; use it to diagnose rather than guess. [S14]

A stable allocator plateau is not proof of a leak; investigate retained ownership and task/callback counts. Conversely, low idle footprint after clearing every useful cache is not proof of good active performance.

## 17. Large-account and background behavior

Do not preload every team member, channel history, custom emoji image, or profile. Fetch what navigation requires; use pagination, search, compact sidebar representations, and an explicit resource policy for extremely large memberships. Users must be able to reach data beyond an in-memory page limit.

Use one shared byte budget across servers, with the active session prioritized. Connecting another server should not triple image caches. Disconnecting a session must release its observers, socket, token, and data.

Closing the main window may leave the application running only according to standard, clearly documented macOS behavior. Distinguish window close from Command-Q. When no window is visible, reduce UI work, release avoidable layout/preview resources, and keep only necessary session/network state. Do not add a hidden login item, daemon, or always-running agent.

No synthetic presence activity to appear online. Send typing/presence activity only under the documented protocol and actual user interaction, with throttling. Respect server Do Not Disturb and notification settings where supported.

On wake or path changes, schedule one bounded recovery attempt and back off appropriately. Do not treat a path-monitor callback as proof that the Mattermost server is reachable. Do not busy-poll while offline.

## 18. Security model

Create a threat model covering hostile servers, malicious posts/media, compromised networks, mistaken server URLs, malicious redirects, multiple accounts, auth callbacks, file operations, external links, compromised dependencies, and accidental diagnostic leakage.

Trust the server for authoritative permissions, not arbitrary code execution. Treat posts, attachment names, plugin props, profile text, links, and emoji metadata as untrusted input. Apply size/depth limits and safe rendering even when the server is normally trusted.

Authenticate API and file requests only to the appropriate scoped service. Do not forward bearer credentials across origin, scheme, or unapproved redirect boundaries. Handle signed object-storage URLs through an explicitly separate unauthenticated request policy where the server legitimately provides them.

Do not log login payloads, tokens, cookies, post bodies, filenames, search strings, sensitive paths, or full server error responses. Sanitization must cover nested API errors and debug string interpolation, not only one logger function.

Purge channel content and cancel pending actions when membership is revoked. Remove sensitive rows, images, search hits, and thread views as well as the sidebar item. A stale UI reference must not preserve access indefinitely after the app learns of revocation. Do not claim remote erasure of content that was explicitly copied or downloaded.

Do not execute plugin-supplied scripts or make direct requests to arbitrary action URLs. Native support for interactive messages must use a verified Mattermost-mediated action flow and explicit user activation, or be marked unsupported.

Use CryptoKit/Security system facilities only for needed protocol operations such as PKCE randomness/hashing; do not design custom cryptography. A bearer-authenticated HTTPS client is not an end-to-end-encrypted messenger.

Use least-privilege app entitlements and sandboxing where compatible with the verified networking/auth/file behavior. User-selected file access must not become broad disk access. If a sandbox exception is genuinely required, document it instead of silently disabling protections.

## 19. Notifications, links, settings, and integration limits

In strict mode, ordinary notification behavior is in-app badges and optional sounds. After an explicit Notification Center opt-in, use `UNUserNotificationCenter`, respect authorization and Focus settings, and avoid rich content by default. Do not promise background push delivery after process exit; no MatterMac push backend exists.

Support Mattermost permalinks with the correct server base path. For links to another server, prompt for the target account context rather than silently transmitting the active session token. A custom MatterMac URL handler, if introduced, must use an owned scheme and validate every parameter; do not hijack another app's registered scheme.

The quick switcher, temporary appearance choice, text size, compactness, sound preference, and optional notification setting stay in memory. Server-side user settings are authoritative only for the server features they describe. Quitting resets purely local settings under this specification.

Provide a small About/Compatibility panel showing the app version, verified server version/capabilities, active session identity, native unsupported features, and a link/action to the project's documentation when configured. Do not display fabricated release information.

No plugin marketplace inside MatterMac. No silent update checks, update daemon, or custom updater in v1. Use explicit release downloads initially. A future updater is a separate dependency/security/storage decision, not permission to introduce a large non-Swift framework silently.

## 20. Calls and web-plugin compatibility: honest boundaries

Mattermost Calls involves its own plugin and WebRTC/media infrastructure; REST posts and a WebSocket connection are not a working call engine. The official deployment material describes the media path and optional dedicated RTCD service. [S13]

Native audio/video is not in messaging v1 under the strict Swift-only, small-footprint implementation constraint. Do not present a disabled mic icon as “voice implemented.” Do not route users into a separate MatterMac meeting service.

For later work, first research the installed Calls plugin version, its signaling/authentication, media compatibility, codecs, echo cancellation, device routing, screen capture, reconnection, and licensing. Determine whether a suitable Swift implementation meets the actual constraints. `AVAudioEngine` or `AVFoundation` alone is not evidence that the full Mattermost WebRTC protocol is implemented.

If a non-Swift WebRTC dependency is the practical solution, document its binary/RAM contribution and request an explicit scope change before adding it. Do not hide it behind a Swift API and continue claiming the runtime implementation is entirely Swift. An all-Swift custom media stack would require its own implementation and interoperability plan, not a casual dependency swap.

Likewise, webapp plugins are not automatically portable to AppKit. Render safe, understood text/attachment content and provide an explicit external handoff for unsupported interactions. A browser handoff is a limitation, not feature parity.

## 21. Testing strategy

Use Swift Testing and/or XCTest according to the selected toolchain; use XCTest UI automation for the macOS app where suitable. Keep test-only tools in Swift. Inject clocks, randomness, ID generation, transport, and event sources so recovery tests do not depend on real sleeps or production accounts.

### Unit and component tests

Cover URL/subpath normalization, endpoint construction, credential scoping, redirection, timestamps, unknown/missing JSON fields, PostList ordering, typed IDs, error decoding, rate limiting, response limits, pagination gaps, state transitions, draft bounds, LRU cost accounting, eviction, and stale-generation rejection.

Test Markdown nesting/input limits, dangerous URL schemes, mentions, emoji/grapheme handling, row-height invalidation, grouping changes, and budget behavior for oversized content.

### Protocol and recovery tests

Replay deterministic event fixtures: initial login, event during snapshot, event before send response, send response before echo, duplicate event, edit after deletion, old snapshot after edit, reaction replay, membership revocation, expired token, sequence gap, resume rejection, server restart, malformed payload, and event overflow.

Test reconnect storms, sleep/wake, old sockets delivering late callbacks, sign-out during upload, channel switch during a slow history response, OAuth cancellation, callback replay, and account change during decode.

Test lost POST responses and deduplication limits without claiming permanent exactly-once delivery. Assertions must verify both no falsely confirmed send and no hidden loss of pending text.

### UI/native tests

Verify multilingual composition, normal selection/copy, menu shortcuts, completion-vs-send behavior, focus retention, long code blocks, dynamic image heights, thread-panel resize, retained-channel switching, long scrolling, dark/light switching, keyboard-only use, VoiceOver, and reduced motion.

Verify that adding a post, reaction, or typing indicator does not reload the whole timeline or allocate an unbounded set of new text views. Exercise repeated channel and server switching and assert released ownership.

### Privacy and file-system tests

In an isolated test account/container, audit application-controlled writes during connect, login, browsing, scrolling, image preview, search, draft creation, reconnect, logout, and quit. Inspect caches, preferences, saved application state, temporary files, Keychain interactions, and developer logs with appropriate tools.

Use conspicuous synthetic canary strings in tests, never real secrets, and search observed app-controlled outputs for them. Separate system-owned artifacts from application writes and explicitly document the limitation. A passing directory check alone is not proof that swap or external system services retain nothing.

Verify explicit download/export exceptions separately. Ensure ordinary preview does not create a temporary file. Verify that tokens survive only in the dedicated Keychain item, relaunch revalidates the expected account, and Sign Out removes its saved sign-in, cached content and cache key. Verify that cache files are encrypted and stay within `ResourceBudget.diskCache`. Re-launch must not restore session-only drafts.

### Integration tests

Use an owner-authorized Mattermost test deployment with two normal test users and known permissions. The official web/desktop client is the interoperability peer, not a product dependency. Do not use bots as proof of ordinary user-client behavior.

Prove bidirectional messages, edits, deletions, threads, reactions, uploads, downloads, unread behavior, reconnect catch-up, and permission changes. Test a subpath deployment and at least two release lines where available. Test SSO only with a properly configured authorized identity environment; report it unverified otherwise.

Never run automated mutation/load tests against an unrelated production server. Credentials come from an authorized local test input or secure CI mechanism, never checked-in fixtures or command-line arguments containing live tokens.

## 22. Benchmark corpus and reporting

Build a deterministic development fixture generator with seeded inputs. Stream or generate pages on demand so the test harness does not preload the very dataset the app is meant to avoid retaining.

Use a large-account scenario with thousands of channel summaries and a history of at least 100,000 posts reachable through paginated fixtures or a test server. Include long messages, Unicode, malformed optional fields, code blocks, replies, deletions, reactions, wide images, large dimensions, and many different authors.

Define and report these scenarios separately: launch; settled login; active text; repeated channel switching; deep scrolling; search; image-heavy scrolling; two/three servers; long thread; file upload/download; slow server; offline recovery; and a multi-hour soak.

For the soak, repeat a fixed workload cycle and report current/peak physical footprint, retained post/cache costs, live tasks, active text views, network queue depth, socket count, file descriptors, and CPU. Compare repeated cycles after warm-up, not only the first and last screenshots.

Run microbenchmarks for parse/layout/cache/reducer changes and end-to-end benchmarks for user-visible latency. Store development reports only when explicitly running the tooling. Real user message contents must not appear in reports.

Publish the exact command, commit, toolchain, hardware, dataset seed, server version, run count, warm-up, sample distribution, and failures. Report p50/p95 where relevant. Do not call a single lucky run a p95 benchmark.

## 23. Build size, packaging, and open-source delivery

Default to ordinary optimized release builds with debug symbols produced separately. Compare size-oriented and speed-oriented Swift optimization settings on representative workloads; do not blindly turn on aggressive inlining or globally unsafe compiler settings.

Use system fonts, SF Symbols where licensed/available, small assets, and dead-code stripping through supported build settings. Keep test fixtures, sample media, screenshots, and benchmark tools out of the app bundle. Do not delete required Swift runtime/back-deployment support merely to reduce measured size.

Report executable size, resources, embedded frameworks/libraries, single-architecture app size, compressed download, and optional universal package separately. Inspect the actual shipped bundle and linked dependencies to verify that no web engine or unexpected binary framework is embedded.

Produce Apple silicon and Intel artifacts when supported; offer a universal build only as an explicitly measured additional artifact. Distinguish cross-build success, translated execution, and native execution on real hardware.

Prepare normal Developer ID signing, hardened runtime, and notarization using Apple's supported distribution workflow when authorized credentials are available. Keep signing secrets out of source control. A successful unsigned local build is not a notarized release, and an uploaded notarization request is not an accepted result. [S15]

Use a minimal appropriate entitlement set. Test installation/launch in a clean account and behavior on the minimum supported macOS release. Do not direct users to disable system security globally.

Use MIT for newly written project code unless the repository already has a user-selected compatible license. Preserve notices for any reused assets/code and audit transitive licenses. Use MatterMac branding; describe it as an independent Mattermost-compatible client and do not imply official endorsement or ownership of Mattermost's marks. This specification does not establish trademark clearance for the name.

Supply a README with setup/build/test/run commands, privacy behavior, capability matrix, known limitations, contribution rules, and security reporting. Keep release notes factual. Do not claim “faster than the official client” without a fair, documented comparative benchmark.

## 24. Implementation milestones and proof gates

### Milestone 0 — Runnable native foundation

Inspect the repository and preserve unrelated changes. Establish the workspace, local Swift package targets, strict concurrency configuration, app shell, first-launch screen, and test harness. Add a virtualized fixture timeline and real native composer, explicitly labeled development-only.

Compile and run the app, verify basic input/selection/scrolling, confirm minimum-OS API usage, and record a release baseline. Create `AGENTS.md` with durable rules and commands. Do not spend the whole milestone on a generic architecture framework.

Proof gate: a buildable native `.app`, no web engine, a working composer/timeline, and initial automated tests. Fixture success is not live Mattermost success.

### Milestone 1 — Real two-user messaging

Implement server URL handling, one supported authentication method, identity validation, team/channel loading, recent history, actual POST sending, and realtime receiving.

Proof gate: User A in MatterMac and User B in the official client exchange real messages in an authorized server channel. Both see the same canonical posts. Restart MatterMac, authenticate again, and retrieve the sent messages from the server; no local history database is involved. Verify one DM as well as a team channel.

### Milestone 2 — Correct state and bounded operation

Implement pagination, variable-height anchoring, scoped state, session-only drafts, pending-send states, deduplication/reconciliation, reconnect/resume/fallback, edits/deletes, reactions, basic threads, unread behavior, and budget enforcement.

Proof gate: automated event-race and lost-response tests pass; scrolling deep into history and visiting many channels does not grow retained state without limit; offline drafts survive within the running process and are not falsely promised across restarts.

### Milestone 3 — Usable native messaging product

Implement safe Markdown, uploads/downloads, bounded images, server search, profiles, quick switcher, useful native menus, multiple server sessions, capability-aware controls, and accessibility/native input requirements.

Add password/MFA and permitted PAT coverage plus a validated browser-based login flow for a supported configured server, or mark the specific auth capability incomplete. Do not delay all product work when an external IdP test environment is unavailable.

Proof gate: the native messaging checklist passes on supported test environments; unsupported plugin/call features are accurately labeled; ordinary app use persists only the specified Keychain sign-ins and the bounded, encrypted content cache.

### Milestone 4 — Hardening and release candidate

Run security/redirect/account-isolation tests, filesystem audits, input/accessibility checks, large-account benchmarks, and a multi-hour soak. Inspect dependencies and artifacts, fix significant leaks/hitches, produce packages, and run signing/notarization only with authorized credentials.

Proof gate: publish actual test outcomes and resource measurements, explain misses, identify unverified environments, and provide reproducible build/run instructions. Do not promote “implemented but untested” to supported.

### Later milestone — Explicitly approved extensions

Calls/media, arbitrary plugin support, local content storage, an updater, or a non-Swift dependency require separate scope decisions because they change this specification's core constraints. Do not add them opportunistically while finishing text chat.

## 25. Agent execution rules

Read this specification completely before making structural changes. Inspect Git status, current source, build configuration, and existing tests. Preserve unrelated user work. Do not reset or delete work merely because it differs from the proposed layout.

Make reasonable small decisions and record significant tradeoffs in `docs/decisions/`. Do not repeatedly ask the user to select filenames, dependency-injection styles, or icon variants. Ask only when an actual authorization, secret, destructive operation, or product-constraint change requires a decision.

Compile and run focused tests after meaningful changes. Read current SDK/compiler diagnostics and official documentation rather than repeatedly applying guessed APIs. Keep the app runnable while adding capability slices.

No fake implementations that return success. No TODO-only crates/targets treated as complete. No bot account masquerading as normal-user integration. No “secure” labels on unaudited custom authentication. No benchmark values invented from estimates.

Do not disable assertions, tests, compiler concurrency checking, permission handling, or privacy policy to get a green build. Fix the cause or document a genuine toolchain/platform limitation.

Use actual available environments. A Linux environment can edit Swift and run some portable tests, but cannot verify the native macOS UI or sign/notarize a macOS app. State exactly what ran and what needs a macOS environment. Continue useful implementation/test work instead of fabricating success.

Live server actions require an authorized test environment. Do not search the filesystem for another app's credentials, run load tests on a discovered server, create unrequested OAuth registrations, or send unsolicited messages.

At every milestone or session boundary, update `docs/progress.md` with implemented behavior, changed modules, exact commands executed, outcomes, measured resource data, known defects, capability gaps, and the next concrete task. This is a development artifact, not runtime user-data storage.

Do not stop after a plan. Begin with the runnable application foundation, then immediately pursue the real two-user messaging slice. If the work spans agent sessions, leave a working checkpoint and enough precise context for continuation; do not claim unfinished milestones are complete.

## 26. Final acceptance checklist

Before declaring messaging v1 complete, verify all of the following:

1. MatterMac is a real native macOS `.app` with Swift-owned runtime code and no embedded browser or replacement backend.
2. Authorized normal users exchange messages with an official Mattermost client through the real server.
3. Auth, origin handling, TLS, MFA/SSO scope, and permission errors behave as documented; unverified auth methods are not advertised.
4. Teams/channels/DMs, history, sends, edits/deletes, threads, reactions, unread state, search, and attachments work at the declared support level.
5. The native composer handles tested input methods, selection, shortcuts, and accessibility without data loss.
6. Timelines recycle views, retain only bounded windows, preserve scroll anchors, and do not grow with total account history.
7. Pending text is never silently evicted; uncertain sends are not falsely confirmed; quitting does not promise draft recovery.
8. Automatic persistence is limited to the specified Keychain sign-ins and the encrypted content cache in the audited application paths; explicit external actions and OS limitations are disclosed.
9. Memory, size, startup, CPU, and long-session results are measured and published against the specified workload; misses are explained.
10. Account switching, logout, revocation, reconnect, sleep/wake, and late async callbacks do not leak or corrupt session state.
11. Calls, web plugins, and other unimplemented capabilities have honest boundaries instead of fake native support.
12. The repository builds reproducibly, contains no credentials, includes tests and documentation, and distinguishes unsigned builds from verified signed/notarized releases.

**Central invariant:** Using MatterMac for longer, opening more channels, or encountering a slow server must not cause application-controlled caches, queues, task counts, or retained views to grow without a defined bound. Reaching a bound must not silently destroy unsent work or turn unknown state into false certainty.

---

## 27. Primary references for the implementing agent

These references were checked while preparing the specification on September 24, 2026. They are starting points, not a frozen support contract. Verify the exact SDK and Mattermost server/plugin versions you implement. Moving source branches may describe capabilities that are absent from a deployed release. Most requirements above are project decisions; references support the specific external API/framework details called out in the text.

**[S1] Mattermost REST/WebSocket API introduction and authentication.**  
`https://docs.mattermost.com/api/reference/mattermost-api`  
`https://developers.mattermost.com/integrate/reference/rest-api/`

**[S2] Mattermost API user/authentication endpoint definitions.**  
`https://github.com/mattermost/mattermost/blob/master/api/v4/source/users.yaml`

**[S3] Mattermost personal access token configuration and permissions.**  
`https://developers.mattermost.com/integrate/reference/personal-access-token/`

**[S4] Mattermost v11 changelog, including versioned OAuth/PKCE/discovery changes.**  
`https://docs.mattermost.com/product-overview/mattermost-v11-changelog`

**[S5] Apple URLSessionConfiguration and ephemeral sessions.**  
`https://developer.apple.com/documentation/foundation/urlsessionconfiguration`  
`https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral`

**[S6] Apple URLSessionWebSocketTask; Mattermost WebSocket wire introduction.**  
`https://developer.apple.com/documentation/foundation/urlsessionwebsockettask`  
`https://github.com/mattermost/mattermost/blob/master/api/v4/source/introduction.yaml`

**[S7] Mattermost official WebSocket client implementation and recovery behavior.**  
`https://github.com/mattermost/mattermost/blob/master/webapp/platform/client/src/websocket.ts`

**[S8] Swift concurrency language/toolchain behavior and migration guidance.**  
`https://www.swift.org/blog/swift-6.2-released/`  
`https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/`

**[S9] Mattermost post/history endpoint definitions and since-mode limitations.**  
`https://github.com/mattermost/mattermost/blob/master/api/v4/source/posts.yaml`

**[S10] Mattermost server post-creation/deduplication implementation.**  
`https://github.com/mattermost/mattermost/blob/master/server/channels/app/post.go`

**[S11] Apple AppKit table view reuse and delegate behavior.**  
`https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TableView/TableViewOverview/TableViewOverview.html`  
`https://developer.apple.com/documentation/appkit/nstableviewdelegate`

**[S12] Apple NSCache cost limits and caching guidance.**  
`https://developer.apple.com/documentation/foundation/nscache/totalcostlimit`  
`https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/CachingandPurgeableMemory.html`

**[S13] Mattermost Calls and RTCD architecture.**  
`https://docs.mattermost.com/deployment-guide/calls/calls-deployment-guide`  
`https://github.com/mattermost/rtcd`  
`https://github.com/mattermost/mattermost-plugin-calls`

**[S14] Apple SwiftUI performance diagnosis.**  
`https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance`  
`https://developer.apple.com/videos/play/wwdc2025/306/`

**[S15] Apple software distribution guidance.**  
`https://developer.apple.com/distribute/`

**Additional system authentication reference.**  
`https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession`
