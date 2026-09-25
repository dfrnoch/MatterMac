# MatterMac progress

## 2026-09-24 — recover Claude session and integrate the native application

Recovered the previous implementation checkpoint.
The parent stopped at the usage limit before integrating six module copies in
`/tmp/mmwork`. All repository files were untracked and the repository had no
commits; no user work was reset, deleted, or committed. See decision 0009.

### Implemented in this continuation

- Recovered HTTP transport/client, realtime transport/client, Markdown parser,
  AppKit timeline, native composer, and Xcode app/workspace from their owned paths.
  Preserved the parent's newer core, tests, and shell.
- Completed the missing table adapter and connected reusable timeline/composer
  panes to channel/thread snapshots, session drafts, sending, edits, deletions,
  reactions, paging, and existing search/quick-switcher panels.
- Shared layout caches across panes/sessions. Added immediate draft accounting,
  quit/sign-out handling, real service composition, and system lifecycle hooks.
- Added authenticated user ID to the realtime factory and wired service shutdown
  at session teardown and after transient discovery/authentication clients.
- Fixed same-origin/subpath redirects losing the bearer header; cross-origin and
  subpath escape redirects remain rejected. Fixed cancellation of transmitted
  writes being reported as ordinary cancellation rather than unknown outcome.
- Fixed rejected paste reporting success and IME commits bypassing the text budget.
  Fixed the Swift 6.4 compiler crash in a typed-throws test closure without disabling
  tests or concurrency checking. Removed compiler warnings in recovered Swift code.
- Refused send admission after session shutdown and restored draft accounting when
  admission fails. Rejected stale thread snapshots after navigation; cleared visible
  channel data when it disappears from sidebar membership.
- Restored an explicit normalized-origin review step before connection.
- Corrected the reopen UI test to target the actual app next to its runner. Multiple
  recovered apps share the same bundle ID, so `open -b` could choose a different
  copy. SwiftUI's native reopening behavior passed; no custom reopen workaround
  was retained.
- Added README, MIT license, recovery decision, and this continuation record.

### Environment and verification

Executed on Apple M1 Pro, 16 GiB RAM, MacBookPro18,3, macOS 27.0 (26A428),
Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27 SDK.
The deployment target remains macOS 14; execution on macOS 14 and native Intel
hardware has **not** been verified.

Commands run from the repository root:

```sh
# Starting checkpoint: 45 core tests passed.
swift test --package-path Packages/MatterMacKit

# After integration and fixes: 156 non-live package tests passed.
# The additional live test is disabled unless MM_LIVE_TESTS=1.
swift test --package-path Packages/MatterMacKit
swift test --package-path Packages/MatterMacKit --filter TimelineIntegrationTests

# Local, repository-owned development servers; credentials never printed.
set -a
. ./.local/test-server.env
set +a
MM_LIVE_TESTS=1 swift test --package-path Packages/MatterMacKit --filter LiveMessagingTests

xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac \
  -configuration Debug -derivedDataPath /tmp/mattermac-recovered-build build
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac \
  -configuration Release -derivedDataPath /tmp/mattermac-recovered-build build
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMacUITests \
  -configuration Debug -derivedDataPath /tmp/mattermac-ui-build test
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMacUITests \
  -configuration Debug -derivedDataPath /tmp/mattermac-ui-build \
  -only-testing:MatterMacUITests/FirstLaunchUITests/testReopenEvent test
```

Debug and universal Release builds succeeded. Swift package tests emitted no
compiler warnings. Xcode emits its tool-generated warning that App Intents
metadata extraction was skipped because this app has no AppIntents dependency;
UI automation also emitted internal QoS warnings. Neither was suppressed.

The first UI run passed six checks and failed reopening due to the ambiguous bundle
ID. The corrected exact-path reopen check passed using native SwiftUI behavior.
The final full UI run passed all seven checks (see below).

Live test: one parameterized test passed for all three deployments in 3.120 s:

| Deployment | Server | Verified with normal users alice and bob |
| --- | --- | --- |
| `http://localhost:8065` | 11.11.1 | Bidirectional channel and DM posts, fetch, edit, reaction, delete, matching WebSocket events |
| `http://localhost:8066/company/chat` | 11.11.1 | Same checks with the deployment subpath |
| `http://localhost:8067` | 10.11.24 | Same checks on the earlier release line |

The live tests delete only their own synthetic posts and log out their test
sessions. Both peers use native REST/WebSocket clients. This is **not** proof of
interoperability with an official web/desktop UI, authenticated app GUI behavior,
SSO, or the full specification's Milestone 1 proof gate.

The native timeline regression uses an offscreen NSWindow and verifies real cell
rendering, incremental insert/edit/remove, stale-generation rejection, and content
teardown. Composer tests simulate NSTextInputClient calls; they are not real
Japanese/Chinese input-method operator tests.

The Release app was launched and its native first-launch screen and invalid-URL
error inspected through accessibility and a screenshot. No browser engine is used.

### Artifact inspection and measurements

`lipo -info` confirms arm64 and x86_64 slices. `codesign -dv --entitlements -`
confirms local ad-hoc signing, hardened runtime, and only sandbox, outgoing network,
and user-selected read/write entitlements for Release. `otool -L` shows Apple
system frameworks/Swift libraries and no WebKit or JavaScriptCore. No third-party
runtime dependency was added. No Developer ID signature or notarization was run.

Final bundle/zip sizes and the full UI result appear in the final checkpoint below.
No physical-footprint, startup p95, scrolling latency, five-minute idle CPU, or soak
benchmark is claimed. There is no commit identifier yet; all work remains uncommitted.

### Known gaps and next concrete work

This is a recovered, buildable development checkpoint, **not messaging v1 complete**.

1. Run an authenticated GUI exchange with an official web-client peer, including
   channel switching with drafts and pending sends, reconnect, restart/relogin,
   and a DM. The live protocol tests above do not replace this gate.
2. Finish UI integration for uploads/downloads, image demand/cache delivery,
   autocomplete providers, profiles, compatibility/menu flows, and session notices.
   Attachment actions currently explain the limitation; no fake success is returned.
   Exercise membership revocation with unsent work and expose its recovery notice
   before claiming that user flow complete.
3. Add the bounded development fixture timeline/benchmark harness. Run real IMEs,
   VoiceOver/keyboard checks, filesystem audits, resource measurements and soak.
4. Browser SSO, Calls/media, and arbitrary web plugins remain unsupported. No
   signing/notarization credentials are configured. Minimum-OS and native Intel
   execution, full endpoint matrix, and release hardening remain unverified.

Next task: the authenticated native-GUI/official-web-peer exchange and draft/send
navigation regression, before expanding media support or declaring a milestone.

### Final checkpoint result

- Final full `MatterMacUITests` run: **7 tests passed**, 0 failures. This includes
  close/reopen via Window menu/Command-0 and reopening the exact app through `open`.
- Final universal Release rebuild: **BUILD SUCCEEDED**.
- Copied the ad-hoc signed app to ignored `build/MatterMac.app` with `ditto`.
  `codesign --verify --strict build/MatterMac.app` passed.
- Universal executable: **13,299,504 bytes**. Sum of bundle file sizes:
  **13,404,678 bytes** (12.784 MiB). Universal zip:
  **3,881,632 bytes** (3.702 MiB), created with
  `ditto -c -k --keepParent build/MatterMac.app build/MatterMac-universal.zip`.
  These are universal development-build artifacts, not a single-architecture
  release archive or notarized distribution. No runtime benchmark was inferred
  from artifact size.
- Latest package run: 156 non-live tests passed, one opt-in live test disabled.
  The separately enabled live test passed all three deployment arguments.
- No commits made. No credentials copied into sources, documentation, or artifacts.

## 2026-09-24 — Continued implementation: draft ownership, DMs, completion

Implemented the next navigation/send regression slice and connected user/channel
completion to the existing bounded native popup.

- Drafts retain their edited-post ID and UTF-16 selection across channel/thread
  navigation. Resuming an edit cannot accidentally turn it into a new message.
- Draft admission is pinned through the actor handoff. Accepted sends clear only
  their own draft; rejection restores accounting atomically even at the memory cap.
  Pane replacement cannot duplicate the text or overwrite an in-flight edit.
  Explicit sign-out blocks late saves and restoration. See decision 0010.
- Sending has its own bounded task, separate from history/actions and coalesced
  visibility reporting. Navigation generations reject stale pre-admission work.
  Draft providers are weak, so the view model does not retain hidden native panes.
- Direct-message resolution now returns the channel before UI navigation starts.
  The common selection path clears the previous header/thread and receives the
  matching history, instead of potentially dropping the first DM snapshot.
- `@user`/special mentions and `~channel` suggestions use the Core session provider.
  The existing composer handles debounce, cancellation, eight-result bounds,
  selection and Return-to-accept. Superseded/session-ended results are discarded.
  Emoji autocomplete is still unimplemented.

### Verification

- `swift test --package-path Packages/MatterMacKit`: **163 non-live tests passed**;
  two opt-in live tests skipped. Counts reported by target include the skipped tests:
  UI 71, realtime 25, models 1, Core 48, API 20. No Swift compiler warnings.
- New deterministic native tests cover edit/selection restoration, success/rejection
  across pane replacement, history/send concurrency, pending text after navigation,
  real completion-provider keyboard acceptance, DM/thread transition and late teardown.
  The edit admission test has both success and failure arguments. Core tests exercise
  full-budget rollback and rejection after explicit sign-out.
- With `.local/test-server.env` sourced into the environment (never printed),
  `MM_LIVE_TESTS=1 swift test --package-path Packages/MatterMacKit --filter
  'LiveMessagingTests|LiveConversationTests'`: both tests passed all three deployment
  arguments. Latest native suite: **4.805 s**; protocol suite: **2.822 s**.
- Native integration uses the production login model, service/realtime factories,
  `MainWindowView` in native `NSHostingController` windows, AppKit text insertion and
  Return commands. It verifies login, draft/caret restoration, Alice's channel send
  and edit, Bob's reply into the open thread, DM navigation/send, received timeline
  rows, cleanup of test posts and session shutdown. Credentials stay in environment
  and in-memory login fields; passwords are cleared after authentication.
- Servers: Mattermost 11.11.1 at localhost:8065, 11.11.1 under
  localhost:8066/company/chat, and 10.11.24 at localhost:8067. These are repository-owned
  normal-user test sessions. Both native peers are MatterMac. This is automated
  native-window/controller integration, **not official web-client interoperability,
  a manual authenticated walkthrough, or a real IME/VoiceOver assessment**.
- `xcodebuild ... -scheme MatterMacUITests -configuration Debug -derivedDataPath
  /tmp/mattermac-ui-build test`: **7 tests passed**, no failures, 56.544 s.
- `xcodebuild ... -scheme MatterMac -configuration Release -derivedDataPath
  /tmp/mattermac-recovered-build build`: **BUILD SUCCEEDED**, arm64 + x86_64.
  Updated ignored `build/MatterMac.app` and `build/MatterMac-universal.zip`.
  `codesign --verify --strict build/MatterMac.app` passed (local ad-hoc signature).
  Executable: **13,360,544 bytes**; bundle files: **13,465,718 bytes**;
  zip: **3,899,175 bytes**. No performance or notarization claim.

### Observed framework warning

Live native tests emit an NSTableView reentrancy warning while SwiftUI updates the
sidebar. An LLDB conditional breakpoint at NSLog captured
`NSTableRowHeightData._cacheRowSpansInRange` → `NSTableView.endUpdates` →
`SwiftUI.OutlineListCoordinator.diffRows/update`; no MatterMac timeline delegate or
mutation is on that stack. Temporary timeline instrumentation was removed after
tracing. The warning is **not suppressed or claimed resolved**; track it on this
macOS 27/Xcode 27 build and check supported OS versions before release. Xcode also
emits its existing AppIntents metadata-extraction warning for the app without an
AppIntents dependency. Neither is a Swift compiler warning.

### Remaining work / next concrete task

Next implementation slice: connect explicit attachment upload/download to the native
composer/file panels, including shared pasted-data/transfer bounds and navigation-safe
ownership. Images, profiles, session-recovery notices (especially revoked membership
with unsent text), capability/menu flows, and emoji completion remain incomplete.
The official-client peer exchange, reconnect/restart/relogin GUI scenarios, real IMEs,
VoiceOver, privacy audit, performance/soak and minimum-OS checks remain release gates.
SSO, Calls and arbitrary web plugins remain unsupported. No commits were made.

## 2026-09-24 — Browser SSO implementation

Implemented the server-advertised desktop browser handoff with native
`ASWebAuthenticationSession`: OpenID Connect, SAML, Google, Microsoft/Office365 and
GitLab routes. Custom OpenID/SAML/GitLab button labels are bounded and preserved.
A read-only probe of the user-provided **10.11.9** deployment confirmed that its
custom Keycloak integration advertises the **GitLab** route, not OpenID, and that
the route redirects to its Keycloak authorization endpoint. No production server
configuration, OAuth app registration, credentials, or permissions were changed.

The real app discovered that server, selected Browser SSO by default (password
login disabled), displayed its configured provider label, and started the browser
session. The user then completed Keycloak authentication and reported **“Signed
in successfully”** in MatterMac. This verifies that deployment’s complete login
flow by user confirmation; MFA variants, all providers and all browsers are not
claimed tested. The signed-in session was left open; no production message actions
were performed during this check.

The callback is nonce/server/subpath/port bound, size/deadline bounded and single
use. Code exchange refuses every HTTP redirect, ignores cookies, decodes only
needed user fields and verifies identity through `/users/me`. Cancellation closes
the browser session; late/rejected login results are revoked best-effort. Session
credentials remain in RAM. No global `mattermost:` handler was registered; see
[decision 0011](decisions/0011-scoped-desktop-sso.md) for the scoped callback contract
and limitations. The browser privacy boundary and unverified organization setup are
shown in the login UI.

### Verification

- `MM_BROWSER_TESTS=1 swift test --package-path Packages/MatterMacKit`: passed all
  **170 enabled tests**; two opt-in live tests skipped in this run. Swift Testing
  reports 172 including those skipped entries, across five test targets. No Swift
  compiler warnings. New checks cover five routes, hostile/replayed callbacks,
  cancellation/expiry, custom labels, identity mismatch cleanup and refused
  same-origin redirects on exchange.
- The explicitly enabled system-browser fixture uses a real
  `ASWebAuthenticationSession`, a Swift-owned local HTTP server, and a completion
  page emulating Mattermost's JavaScript custom-scheme navigation. It passed the
  callback, code exchange, `/me`, cookie rejection and cleanup path on macOS 27
  (**2.182 s** in the full run). Mattermost Desktop was installed. This is a local
  protocol fixture, not an actual IdP login. An initial test through LoginModel
  failed because the package runner has no key window; the adapter test supplies
  its presentation anchor directly. The actual app subsequently opened its browser
  session through LoginModel.
- Existing live normal-user tests, with `.local/test-server.env` sourced without
  printing credentials: `MM_LIVE_TESTS=1 swift test --package-path
  Packages/MatterMacKit --filter 'LiveMessagingTests|LiveConversationTests'` passed
  all three deployments (11.11.1 root/subpath and 10.11.24). Native conversation
  test **7.861 s**, protocol test **3.093 s**. These are password-auth regressions.
- `xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMacUITests
  -configuration Debug -derivedDataPath /tmp/mattermac-ui-build test`: **7 passed**,
  **57.034 s**. These first-launch UI tests do not test an IdP.
- Release universal build succeeded, arm64 + x86_64; updated ignored
  `build/MatterMac.app` and `build/MatterMac-universal.zip`.
  `codesign --verify --strict build/MatterMac.app` passed with local ad-hoc signing.
  Executable **13,724,304 bytes**, bundle files **13,829,478 bytes**, zip
  **4,000,352 bytes**. Existing AppIntents metadata-extraction warning remains;
  no Developer ID/notarization, minimum-OS or performance claim.

### Next concrete task

The requested Keycloak flow is implemented and confirmed working on the supplied
10.11.9 server. Next: connect explicit attachment upload/download to the native
composer/file panels, with shared data/transfer bounds and navigation-safe ownership.
Other provider/OS/browser combinations, Calls, plugins and prior release gates remain
unverified or incomplete as previously recorded. No commits were made.

## 2026-09-24 — Native attachment upload/download integration

Connected the paperclip's native NSOpenPanel and existing file paste/drop callbacks
to the streaming sender. Selection reads metadata only; uploads begin on Send.
Selected sources live in account/channel/thread drafts and survive navigation.
Source metadata is charged to the shared unsent-work ledger, including attachment-only
drafts, then moves with the existing pinned reservation into the pending queue.
Selection count/path bounds come from ResourceBudget; server file-size and disabled
attachment policies are checked before clearing input. Failed admission keeps text
and selected files. Existing-post editing does not add attachments.

Added NSSavePanel downloads from timeline attachment actions with safe suggested
names, an in-pane Cancel Download control, and bounded session task ownership.
Navigation, sign-out and known membership revocation cancel affected transfers.
Downloads stream to the explicitly chosen location, never automatically open files,
and preserve existing destination contents on failure/cancellation. The sandbox
fallback now uses exclusive creation rather than truncating an existing destination.

Selected uploads capture identity/size/nanosecond mtime and recheck after admission;
changed files fail before sending. Security-scoped access covers selection or the
transfer without persisted bookmarks or an app-owned staging copy. Pending uploads
show file counts and per-file progress. Confirmed uploaded IDs are reused on retry.
Ambiguous upload responses now become outcome unknown instead of silently retrying
on reconnect. Discard on a queued/uploading item cancels before posting, releases
its reservation and permits the next queued send to run. A POST already in flight
cannot be represented as cancelled. Orphaned server uploads are not deleted through
an invented endpoint. See [decision 0012](decisions/0012-explicit-file-transfers.md).

### Verification

- `swift test --package-path Packages/MatterMacKit`: **176 enabled tests passed**;
  three opt-in browser/live entries skipped (Swift Testing reports 179 including
  them across five targets). No Swift compiler warnings. New native-controller tests
  exercise attachment-only draft navigation, pending ownership after a failed post,
  selection bounds and cancellation of late metadata work.
- Core tests cover ambiguous uploads, preservation/reuse of confirmed file IDs,
  explicit upload discard followed by the next queued message, and cancellation of
  downloads after membership revocation. Loopback API tests reject same-size replaced
  upload sources before network activity and verify that forbidden/cancelled
  downloads preserve an existing file and remove partial output; the cancellation
  check waits until partial bytes have actually been written.
- With ignored `.local/test-server.env` sourced without displaying credentials:
  `MM_LIVE_TESTS=1 swift test --package-path Packages/MatterMacKit --filter
  'LiveConversationTests|LiveMessagingTests'` passed all three deployments
  (11.11.1 root, 11.11.1 subpath, 10.11.24). The extended native test selects a real
  fixture file, navigates away/back, sends it, sees the attachment through the other
  account, and downloads identical bytes. Native test **5.492 s**, existing messaging
  regression **2.884 s**. These use repository-owned local accounts and native peers,
  not an official-client interoperability check or the user's production server.
- The production signed-in app was left running. App-launching XCUITests were not
  rerun because they share that app's bundle identity and terminate it. Native
  controller/transport integration ran in separate package test processes; a manual
  save/open-panel, sandbox and VoiceOver walkthrough remains a release gate.
- `xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac -configuration
  Release -derivedDataPath /tmp/mattermac-recovered-build build`: **BUILD SUCCEEDED**,
  arm64 + x86_64. Refreshed ignored `build/MatterMac.app` and
  `build/MatterMac-universal.zip`; `codesign --verify --strict` passed (local ad-hoc).
  Executable **13,886,720 bytes**, bundle files **13,991,894 bytes**, zip
  **4,056,185 bytes**. Existing AppIntents metadata-extraction warning remains;
  no Developer ID, notarization, minimum-OS or performance claim.
- Release optimization initially hit a Swift 6.4 CopyPropagation ownership compiler
  crash in the nested download Task callback. Moving the async download body into
  a method resolved it; no optimizer flags, warning suppression or unsafe concurrency
  escape hatches were added.

### Next concrete task

Implement pasted-image uploads through a bounded in-memory source shared across
composer/draft/pending ownership, then connect the existing image demand/cache
pipeline for previews. Pasted images currently receive an explicit unavailable
message; no temporary-file workaround was added. Other capability/notice, Calls,
plugin, accessibility, filesystem-audit and performance gates remain as recorded.
No production messages were sent during this session. No commits were made.

## 2026-09-24 — Pasted images and native preview loading

Implemented PNG/TIFF clipboard attachments through the existing draft, pending-send
and raw-body upload path. Image bytes stay in memory; no upload staging file or
conversion helper is introduced. One process-wide 8 MiB admission ledger follows
shared source ownership through draft copies, pending operations and active
transfers. Refused pastes preserve prior work and report failure to AppKit. Source
ownership remains alive until the HTTP operation returns, including cancellation.

Connected visible-row avatar and attachment thumbnail demand to the shared image
pipeline. Requests coalesce by account/resource/display size, encoded responses and
source dimensions are bounded, and Image I/O downsamples only the first frame.
Fetch admission precedes encoded-data retention. Decoded ownership covers cache
entries, outstanding results and displayed rows, so cache eviction cannot free a
charge still held by a cell. Offscreen demand and queued decode work cancel;
navigation, sign-out and known access revocation clear displayed images and purge
cancelled account work. No third-party image URLs or full originals are fetched
for automatic previews. See [decision 0013](decisions/0013-memory-image-ownership.md).

### Verification

- `swift test --package-path Packages/MatterMacKit`: **182 enabled tests passed**;
  three browser/live entries skipped (185 reported across five targets). No Swift
  compiler warnings. New tests exercise real PNG pasteboard input, shared admission
  across channel drafts, retained upload-source ownership after draft/pending
  release, decoded ownership after cache purge, dimension/encoded-size limits,
  late cancelled responses and prompt cancellation of queued gate waiters.
- Loopback API tests verify exact in-memory PNG POST bytes, bearer authentication,
  Content-Length, absence of cookies, and rejection of a 307 upload redirect.
  These extend the existing changed-file and failed-download preservation tests.
- With ignored `.local/test-server.env` sourced without displaying credentials:
  `MM_LIVE_TESTS=1 swift test --package-path Packages/MatterMacKit --filter
  LiveConversationTests` passed **all three deployments** (11.11.1 root, 11.11.1
  subpath, 10.11.24), **5.227 s**. The native test pastes an image beside a selected
  file, navigates away/back, sends both, renders the receiving row's server
  thumbnail, downloads byte-identical originals and verifies pasted-data release.
  The existing live REST/WebSocket messaging regression also passed all three,
  **2.887 s**, in the preceding combined run.
- Live-test failures exposed fixture assumptions: attachment ID order is not
  stable; thumbnails can differ from original dimensions (these servers returned
  a 100-pixel thumbnail for a 32-pixel source); and the test's bare SwiftUI hosting
  root had a zero-height timeline. The fixture now uses the app's 760×500 minimum
  size, visible windows and a layout/display pass. An edit check also now waits for
  sender completion because the peer's WebSocket event may precede its REST reply.
  Temporary layout probes were removed. No production code workaround was needed.
- The existing macOS 27 SwiftUI sidebar NSTableView reentrancy warning remains
  observable in native live tests; the earlier trace above applies. It is not
  suppressed or claimed resolved. Browser/XCUITest relaunch tests were not run;
  the user's signed-in production process was preserved and no production message
  was sent. Local fixtures clean up their posts and explicit download files.
- `xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac -configuration
  Release -derivedDataPath /tmp/mattermac-recovered-build build`: **BUILD SUCCEEDED**
  for arm64 and x86_64, including the final upload-owner lifetime change. Existing
  AppIntents metadata-extraction warning only; no Swift compiler warnings.
  Refreshed ignored `build/MatterMac.app` and `build/MatterMac-universal.zip`.
  `codesign --verify --strict` passed (local ad-hoc); `lipo -archs` reports both
  architectures. Executable **14,057,264 bytes**, bundle files **14,162,438 bytes**,
  zip **4,112,670 bytes**. No Developer ID/notarization or performance claim.

### Next concrete task

Connect the remaining session notices and server capability restrictions to the
native shell, including clear recovery actions for expired/revoked access. Emoji
completion, broader accessibility/IME checks, filesystem and image-heavy memory
measurements, minimum-OS validation, Calls and plugin limitations remain as
recorded. PNG round trips were exercised; the TIFF attachment path is implemented
but has not had a separate live-server round trip. No commits were made.

## 2026-09-24 — Session recovery and attachment capability controls

Connected session notices to the native shell. Expired sessions and unexpected
identity changes show a persistent recovery banner; revoked access and operation
failures have dismissible notices. The Session menu keeps Copy Unsent Text and
Sign Out available after a notice is dismissed. Copy is explicit, account-scoped,
and text-only. Sign In Again uses the existing unsent-work discard confirmation,
then rediscovers the same server/subpath and its SSO options. It creates no new
credential until the user signs in. Other server sessions remain available through
Cancel. The UI warns that interrupted sends may already exist on the server.

Fixed the underlying ownership and lifecycle paths instead of only adding a banner:
known authentication loss cancels session work, invalidates late responses, closes
the service/socket and clears received content without releasing unconfirmed-work
reservations. It blocks new sends and reconnect attempts, and late socket statuses
cannot clear the authentication-required state. No logout request is attempted
under an unexpected/ended identity. A 403 remains an operation permission failure.
Revoked-channel sends remain in the queue, retaining text and selected-image
charges. Late cancelled upload results cannot proceed to posting. Cleared native
panes cannot overwrite retained drafts or reload them during late callbacks. Image
and layout caches are purged on access loss/removal; explicit shutdown also clears
the draft store. See [decision 0014](decisions/0014-session-recovery.md).

Authenticated configuration now reaches channel and thread composer controls.
Disabled or unconfirmed file-attachment support disables selection and is checked
before send admission. Configuration changes preserve existing selections. The
shell explains that restriction and archived/read-only channels. This is not a
claim of complete per-role permission discovery.

### Verification

- `swift test --package-path Packages/MatterMacKit`: **190 enabled tests passed**;
  three opt-in browser/live entries skipped (193 reported across five targets).
  No Swift compiler warnings. Eight new tests cover authenticated 401 handling,
  identity changes, a cancellation-ignoring upload after membership revocation,
  revoked-channel navigation and draft retention, session recovery/clipboard copy,
  live configuration changes, and return to an exact subpath/SSO login form.
- The recovery routing test runs a loopback HTTP fixture returning an authenticated
  401, then performs real discovery again and verifies the GitLab SSO option and
  preserved subpath. It verifies no logout is sent after the credential is ended.
  A deterministic actor-turn test also proves that queued, not-yet-started work
  cannot execute after authentication ends; execution checks both activity and
  cancellation before entering its operation.
  The clipboard check uses a uniquely named test pasteboard, leaving the user's
  general clipboard untouched. No real IdP was invoked by these tests.
- A final focused `ConversationIntegrationTests` rerun checks the last routing/UI
  changes. Tests also verify that unknown/disabled attachment configuration refuses
  new inputs while retaining selected images, and that permission failures preserve
  an otherwise active account.
- `MM_LIVE_TESTS=1 swift test --package-path Packages/MatterMacKit --filter
  'LiveConversationTests|LiveMessagingTests'`, using the ignored environment file:
  **all three deployments passed** (11.11.1 root, 11.11.1 subpath, 10.11.24).
  Native login/drafts/messages/edits/threads/DMs/file and image round trips:
  **5.612 s**. Existing REST/WebSocket messaging regression: **3.021 s**.
  These are repository-owned accounts and native peers, not official-client
  interoperability evidence. The earlier SwiftUI sidebar NSTableView reentrancy
  warning remains observable and is not suppressed or claimed fixed.
- The user's signed-in production app was left running. No production messages,
  browser sign-ins, app-launching XCUITests or user-credential changes were performed.
  Modal discard confirmation/VoiceOver and a full filesystem/footprint audit remain
  release checks.

- Final `xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac
  -configuration Release -derivedDataPath /tmp/mattermac-recovered-build build`:
  **BUILD SUCCEEDED**, arm64 + x86_64. Refreshed ignored `build/MatterMac.app`
  and `build/MatterMac-universal.zip`; `codesign --verify --strict` passed with
  local ad-hoc signing. Executable **14,321,424 bytes**, bundle files
  **14,426,598 bytes**, zip **4,174,949 bytes**. The existing AppIntents metadata
  warning remains; no Swift compiler warnings, Developer ID/notarization or
  performance claim.

### Next concrete task

Add a bounded per-item unsent-work recovery view so drafts and pending sends for
inaccessible channels can be copied/discarded individually, including an explicit
export path for pasted images. Current recovery copies text and requires confirmed
sign-out to discard inaccessible drafts; it does not migrate work automatically
into a newly authenticated account. Emoji completion, the compatibility panel,
broader permission controls, accessibility/IME, minimum-OS and performance gates
remain incomplete. No commits were made.

## 2026-09-24 — persist sign-ins in Keychain and restore on launch

The user explicitly requested saved account access after discovering that relaunch
required another login. This changes the original no-Keychain requirement for
verified sign-ins only; AGENTS.md, SPEC.md, README and the app disclosures now
reflect that exception. See [decision 0015](decisions/0015-keychain-sign-ins.md).

Implemented a native Security.framework Keychain store for canonical server URL,
expected user ID, verified bearer token and session/PAT kind. Password, PAT and SSO
login completion share the save path. The local, non-synchronizing item is bounded
to three accounts and 32 KiB through ResourceBudget; development loopback runs use
a separate service. No user content, password, preference or cookie is persisted.

Launch revalidates saved identity before creating each session. Quit preserves
server sessions; explicit Sign Out deletes the saved account first. Revoked,
expired or changed identities remove their saved credentials. Temporary network
failures preserve them and offer retry. Storage failures appear in the UI and
failed deletion prevents a false successful sign-out. The lifecycle test caught an
existing unnecessary logout call for PATs; shutdown now performs server logout
only for session credentials. Restoring accounts keeps its progress view until
all bounded attempts complete.

### Verification

- `MM_KEYCHAIN_TESTS=1 swift test --package-path Packages/MatterMacKit`:
  **193 enabled tests passed**, 197 reported across five targets including four
  skipped opt-in browser/live/process entries. No Swift compiler warnings.
  New Keychain checks cover session and PAT login/quit/restore/sign-out, expiry,
  identity mismatch, offline retry, runtime authentication loss, account limits,
  replacement, and removing one account while retaining another. They use actual
  macOS Keychain items with synthetic credentials and unique test service names.
- `MM_KEYCHAIN_TESTS=1 MM_KEYCHAIN_PROCESS_PHASE=write` then `...=read`, using the
  same unique `MM_KEYCHAIN_TEST_SERVICE`, with `swift test --skip-build
  --package-path Packages/MatterMacKit --filter KeychainSignInTests.processRestart`:
  both invocations passed (**0.024 s**, **0.025 s**). The second independent process
  recovered the first process's synthetic record, verified it and removed it.
- Compiled the actual KeychainAccounts.swift plus the built MatterMacModels object
  into an isolated Swift probe at `/tmp/mattermac-keychain-smoke/KeychainSmoke.app`.
  Ad-hoc signed it with the unchanged production MatterMac.entitlements, under a
  distinct test bundle ID. Separate sandboxed write and read/remove executions
  both passed. This verifies native Keychain access across process termination
  with the app's sandbox policy, without launching or replacing the user's app.
- Final focused Keychain lifecycle rerun after the progress-view adjustment passed
  all three enabled test functions (six parameterized scenarios) in **0.214 s**.
- The production Keycloak login was not repeated, and no production credentials
  were inspected. Existing builds saved no credential to migrate: one sign-in in
  the updated build is required. Server expiry/revocation can still require SSO.
  Developer ID upgrade behavior, Keychain-lock UI prompts, minimum-OS execution,
  and a full filesystem audit remain unverified; system access controls are not
  bypassed or relaxed. No user application was terminated or restarted.

- Final Release workspace build succeeded for **arm64 + x86_64**. Updated
  `build/MatterMac.app` and `build/MatterMac-universal.zip`; strict code-signature
  verification passed (local ad-hoc signing). Executable **14,605,232 bytes**,
  bundle files **14,710,406 bytes**, ZIP **4,250,243 bytes**. Only the existing
  AppIntents metadata-extraction warning remains; no Swift compiler warnings.

### Next concrete task

Verify the user's first sign-in and ordinary relaunch with the updated build.
Continue the existing unsent-work recovery view afterward; persistent drafts and
message caches remain out of scope. No commits were made.

## 2026-09-24 — individual unsent-work recovery

Continued implementation with three user-requested parallel agents: Core recovery
and admission, native recovery UI, and independent UI integration checks. Root
implemented explicit pasted-image export, reviewed integration and handled the
release build. Ownership was separated by module; no user work was reset and no
production app, Keycloak session, message or credential was inspected or changed.

Review Unsent Work is available in the Session menu and access/authentication
recovery notices. The sheet lists account-scoped drafts and unconfirmed sends,
including inaccessible channels. Each item supports copy and confirmed local
discard; pasted images can be exported through a native save panel. Selected local
files remain at their original locations. Submitting drafts and in-flight sends
are read-only; unknown outcomes stay explicitly unconfirmed. Channel/thread ID
suffixes distinguish unavailable destinations without retaining received history.

Revision and scope checks reject stale deletion, including recreated drafts and
pending sends that changed state. Discarding a visible draft cancels pre-admission
send/selection work and clears its composer, so late callbacks do not resurrect it.
Closing the sheet clears retained snapshots. Image references share the existing
budget lease, which remains charged through export and any still-running request.

The existing 100-item ResourceBudget now applies to drafts plus pending operations
across all sessions. Tiny drafts previously bypassed the count cap; new work is
now refused without evicting existing content. Conversion and rollback preserve
admission atomically. See [decision 0016](decisions/0016-unsent-work-recovery.md).

### Verification

- Focused Core/ledger plus initial UI recovery check: **12 tests passed**, no Swift
  compiler warnings (`/tmp/mattermac-unsent-core-tests.log`).
- Final UI recovery integration check: **six tests passed** in **0.354 s**, no Swift
  compiler warnings (`/tmp/mattermac-unsent-ui-tests-final.log`). Covers stale
  deletion refusal, current composer clear, canceled pre-admission sends,
  ended-session image ownership, submitting edits, snapshot dismissal, and native
  NSHostingView layout. This is not a full visual or VoiceOver audit.
- Final native responder undo/redo count-cap regression passed with the other six
  UI recovery tests (**seven total**, **0.597 s**, no compiler warnings). Refusal
  happens before changing the undo stack; freeing a slot makes the same action
  available again. Evidence: `/tmp/mattermac-unsent-ui-undo-tests.log`.
- `MM_KEYCHAIN_TESTS=1 swift test --package-path Packages/MatterMacKit`:
  **204 enabled tests passed**, 208 reported across five targets including four
  skipped browser/live/process entries. No Swift compiler warnings. The added API
  export check verifies successful replacement, canceled export, failed commit,
  unsupported file-backed source, partial cleanup and retention of the source.
  Evidence: `/tmp/mattermac-unsent-full-tests.log`.
- `MM_LIVE_TESTS=1 swift test --skip-build --package-path Packages/MatterMacKit
  --filter 'LiveConversationTests|LiveMessagingTests'`, with the ignored local
  credentials file sourced: both tests passed on all three local deployments
  (11.11.1 root, 11.11.1 subpath and 10.11.24). Native conversation/attachment checks
  **5.665 s**; REST/WebSocket peer checks **3.405 s**. Existing SwiftUI sidebar
  NSTableView reentrancy warnings remain observable and are not claimed fixed.
  Evidence: `/tmp/mattermac-unsent-live-tests.log`. No real IdP was invoked.
- Final Release workspace build succeeded for **arm64 + x86_64**. Strict code-sign
  verification and ZIP integrity check passed. Updated `build/MatterMac.app` and
  `build/MatterMac-universal.zip`: executable **15,224,912 bytes**, bundle files
  **15,330,086 bytes**, ZIP **4,391,283 bytes**. Existing AppIntents metadata warning
  remains; no Swift compiler warnings, Developer ID signing or notarization claim.
  Evidence: `/tmp/mattermac-unsent-release.log`.

### Limits and next concrete task

The new undo guard fixes count admission into an empty composer through native
Undo/Redo actions. The review also identified an older, broader issue: nonempty
undo/redo growth bypasses the byte-admission check inside shouldChangeText. If
another draft consumes that headroom, a restored edit can fail DraftStore.save and
remain only in the visible composer. Fix this next with coherent undo reservation
or preflight; do not merely reject halfway through an NSTextView undo group. The
new per-item recovery feature does not claim to resolve this existing byte-growth
case, durable drafts, or cross-account migration. The existing SwiftUI sidebar
reentrancy warning also remains a follow-up. Modal save/confirmation interaction,
VoiceOver, minimum-macOS execution and broader performance/privacy audits are still
release gates. No commits were made.

## 2026-09-24 — bounded undo and initial public repository preparation

Completed the next unsent-work item with parallel implementation, documentation,
and repository/bootstrap review. Native undo/redo now admits a complete group
against the shared UTF-8 budget, rolls back refused growth without consuming
history, and publishes admitted text once. This resolves the broader byte-growth
gap recorded above. See [decision 0017](decisions/0017-bounded-native-undo.md).

Prepared a public README, contribution guide, security policy, architecture and
compatibility summaries. Removed private conversation references and workstation
paths, repaired stale documentation references, and retained the existing MIT
license. Recovered the original Swift icon generator and reproduced all ten
committed PNG assets byte-for-byte; see [asset provenance](assets.md).

Added GitHub Actions package tests and a universal Release build using the official
`xcode-27` preview runner, a pinned checkout action, read-only permissions and no
persisted checkout credentials. The hosted workflow has not run yet. Local
actionlint 1.7.12 validation passed with an explicit additional runner label.
GitHub private vulnerability reporting is enabled on the public repository.

Expanded credential/build exclusions and checked the candidate public file set
with Gitleaks 8.30.1. The only initial finding was the public Swift protocol name
`MattermostDiscoveryService`; a narrowly scoped exact-identifier allowance keeps
all default secret detectors enabled. The subsequent scan found no secrets.
Scanner tools were downloaded to temporary storage and their archives checked
against the publishers' SHA-256 checksums; they are not repository dependencies.

Local server provisioning now passes generated passwords only through the ignored
environment file into a development-only Swift HTTP helper, never `mmctl` process
arguments. It uses ephemeral loopback networking, rejects redirects, bounds
responses, verifies expected roles, and closes its administrator session. Existing
accounts are preserved. Fresh and repeated bootstrap passed on isolated 11.11.1,
11.11.1 subpath, and 10.11.24 deployments: four verified users with expected roles,
teams and channels on each; repeated setup preserved account identities and
credentials. Temporary test projects, volumes and credentials were removed;
the original three fixtures remained running. Swift 6 typechecking, shell syntax,
unknown-service and missing-environment failure checks also passed.

### Verification

- Focused undo/recovery/Core suite: **77 tests passed**, including two new native
  AppKit regressions. Evidence: `/tmp/mattermac-undo-focused.log`.
- `MM_KEYCHAIN_TESTS=1 swift test --package-path Packages/MatterMacKit`:
  **206 enabled tests passed**, 210 reported including four opt-in skips. No Swift
  compiler warnings. Evidence: `/tmp/mattermac-opensource-full-tests.log`.
- `MM_LIVE_TESTS=1 swift test --skip-build --package-path Packages/MatterMacKit
  --filter 'LiveConversationTests|LiveMessagingTests'`: both tests passed against
  all three original local fixtures. Native conversation checks **6.001 s**;
  REST/WebSocket checks **2.878 s**. Evidence:
  `/tmp/mattermac-opensource-live-tests.log`.
- Release workspace build succeeded; strict code-signature verification and ZIP
  integrity checks passed. `lipo -archs` confirms **arm64 + x86_64**. This host's
  `lipo -verify_arch` rejected the invocation, so CI asserts the architecture list
  instead. Updated `build/MatterMac.app` and `build/MatterMac-universal.zip`:
  executable **15,244,992 bytes**, bundle files **15,350,166 bytes**, ZIP
  **4,394,303 bytes**. Evidence: `/tmp/mattermac-opensource-release.log`.
- Exported the staged index to a fresh temporary directory: **226 files**, with
  no ignored credentials or build artifacts. The default package suite and a
  clean universal Release workspace build both passed from that export; strict
  signature and architecture checks passed too. Only the existing AppIntents
  metadata warning appeared in the build. Evidence:
  `/tmp/mattermac-public-clean-tests.log` and
  `/tmp/mattermac-public-clean-release.log`. The staged-file secret scan, actionlint,
  whitespace check, and all **31 local Markdown links** passed.

### Remaining gates and next task

The existing SwiftUI sidebar reentrancy and AppIntents metadata warnings remain.
No production application or credential was inspected or restarted. Hosted CI,
minimum-OS and Intel execution, real IMEs/VoiceOver, broader privacy/performance
audits, Developer ID signing and notarization remain unverified. The next
publication step is the initial commit and push, followed by inspecting the first
hosted CI run. No commit or push was made during this preparation.

## 2026-09-24 — commit convention

Pushed the initial implementation as commit `0660fbc` on `main`. Added a
Conventional Commits rule to `AGENTS.md` for future commits, with type, optional
scope, and an imperative summary. This documentation-only change does not alter
the application; package and app checks from the initial-publication section
above remain the latest execution evidence. The next task is to inspect the first
hosted CI run and address any reported failure.

## 2026-09-24 — profiles, channel details, commands, emoji, and a realtime crash fix

Implemented the missing "usable product" pieces from SPEC §3/§4, with a parallel
agent handling system emoji. See decisions
[0018](decisions/0018-static-system-emoji.md) and
[0019](decisions/0019-people-channel-details-and-commands.md).

- **Profiles:** cards open from avatars, author names, `@mentions`, member rows and
  a "View Profile" message menu item. They show picture, presence (refreshed on
  open), position, local time with offset, name/nickname, custom status with expiry,
  email when the server exposes it, and Send Message. Your own card offers Set
  Status. `User` now decodes `email`, the effective `timezone` and
  `props.customStatus` (bounded).
- **Channel details:** a trailing pane (⇧⌘I, toolbar ⓘ, member-count button, or the
  sidebar row menu) with purpose/header, pinned and member counts, Favorite and Mute
  toggles, Copy Channel Link, Leave Channel… (confirmed), and paged members with
  presence, filter, profiles and DM actions, capped at 600 rows. `~channel`
  mentions open member channels; the old "Mention navigation is not available yet"
  error is gone.
- **Status:** a sidebar account bar shows your picture, presence and custom status,
  with a menu for Online/Away/Do Not Disturb/Offline, unsent-work review, About and
  Sign Out. The signed-in user's presence is now polled like DM partners'.
- **Slash commands:** `/…` text runs through `POST /commands/execute` and is no
  longer posted literally. The reply appears above the conversation; unknown
  commands and lost responses keep the draft with an explanation.
- **Menus/toolbar:** there was previously no way to open the ⌘K quick switcher,
  ⌘F search or the About/Compatibility panel at all. A new Go menu (Quick Switcher
  ⌘K, Search Messages ⌘F, Show Channel Info ⇧⌘I, Close Thread), toolbar buttons and
  About MatterMac now reach them. The window title/subtitle carries the channel name
  and header. The compatibility panel no longer claims SSO is unsupported.
- **Emoji (agent):** system emoji render in messages and reaction chips, `:`
  completion works, and a keyboard-navigable reaction picker replaces the text alert.
  The table is generated from pinned, checksum-verified emoji-datasource 6.1.1 and
  Mattermost v11.11.1 inputs (`Tools/GenerateEmojiCatalog.swift`, docs/assets.md).
- **Crash fix:** `MattermostRealtimeClient.livenessTick` wrote
  `socket?.outstandingPing = sendAction(…)`, and `sendAction` reads `socket`. That is
  a runtime exclusivity violation on the first periodic ping, about 30 s after
  connecting. Exclusivity is enforced in Release too, so connected sessions were
  expected to abort; earlier live tests finished before the first tick.
  `LivenessTests` reproduces the abort ("Fatal access conflict detected") without
  the fix and passes with it.
- **Test fix:** `openingDirectMessageResetsThreadAndPublishesMatchingHistory` read
  the draft through the reused pane's current key. It failed once in six full runs
  when SwiftUI had already retargeted the pane to the DM. It now checks the
  channel's key; the product behaviour was already correct.

### Verification

- `MM_KEYCHAIN_TESTS=1 swift test --package-path Packages/MatterMacKit`:
  **241 tests reported, all passed** (UI 99, API 26, models 10, Core 78, realtime
  28, including opt-in skips); no Swift compiler warnings. Evidence:
  `/tmp/mattermac-people-full-tests.log`. The UI target also passed 5 consecutive
  reruns before the test fix above.
- New tests: `PeopleTests` (6), `SlashCommandTests` (2), `UserWireTests` (2),
  `LivenessTests` (1), plus the agent's `EmojiCatalogTests` (9),
  `EmojiCompletionTests` (3) and `ReactionPickerTests` (6).
- With the ignored credentials file sourced, `MM_LIVE_TESTS=1 swift test
  --skip-build --package-path Packages/MatterMacKit --filter
  'LiveConversationTests|LiveMessagingTests|LivePeopleTests|LivePeopleUITests'`:
  all passed. `LivePeopleTests` covers `/users/usernames`, channel member pages,
  status set/restore, favorite save/delete, mute set/restore, `/away`, `/online` and
  unknown-command `404 api.command.execute_command.not_found.app_error` on 11.11.1
  root, 11.11.1 subpath and 10.11.24. `LivePeopleUITests` drives the native shell
  on 11.11.1 and 10.11.24: details, members, the profile card, and `/away`,
  `/online` and an unknown command typed into the AppKit composer. Every server
  setting change is restored. Evidence: `/tmp/mattermac-people-live-tests.log`.
  Both peers are native clients; this is not official web-client interoperability.
- `MM_SNAPSHOT_DIR=<dir>` optionally captures only the test's own windows with
  `screencapture -l`. Reviewed at 1100×720: account bar, member presence, command
  reply banner, channel pane and profile card render correctly. `cacheDisplay`
  snapshots omit SwiftUI layers and are not used.
- Release workspace build: **BUILD SUCCEEDED**, arm64 + x86_64, strict signature
  verification passed; only the existing AppIntents metadata warning. Executable
  **18,258,976 bytes**, up from 15,244,992; the emoji table accounts for about
  135 KB, and the rest (mostly new SwiftUI views) has not been attributed yet.
  Evidence: `/tmp/mattermac-people-release.log`.
- `xcodebuild … -scheme MatterMacUITests … test`: **6 of 7 fail** with "server URL
  field missing". The same 6 fail on a clean worktree of HEAD `1e5fe7c`, so this
  predates this session; not investigated yet. Evidence:
  `/tmp/mattermac-people-uitests.log`.

### Open issues and next concrete task

1. Fix the pre-existing first-launch XCUITest failures (element lookup on the
   connect screen; the disclosure assertion also expects older text).
2. In the native snapshot window, the top ~48 pt of the detail column, directly
   below the toolbar, renders blurred (it affected the old header row and now the
   command/notice banners). `scrollEdgeEffectHidden` on the split view or detail did
   not change it. Check in the real `Window` scene, then fix or move banners.
3. Attribute the 3 MB executable growth.
4. Custom emoji, custom status editing, command dialogs/ephemeral posts,
   VoiceOver/keyboard audit of the new popovers and pane, and the official-client
   peer exchange remain open. Nothing was committed.

## 2026-09-25 — user-reported UI defects, names, notifications, custom status

The user ran the app against their real server and reported:
- low-quality images that could not be enlarged
- usernames instead of real names, and no DM pictures
- misaligned composer icons
- unreadable reactions
- links that could not be clicked
- a freeze when showing the member list

A parallel agent fixed the four AppKit timeline/composer defects; see
[decision 0020](decisions/0020-image-preview-rendition-and-viewer.md) and its test
list below. Names, notifications and UI-test isolation are in
[decision 0021](decisions/0021-names-notifications-and-ui-test-isolation.md).

- **Links, thumbnails, reactions not clickable:** the timeline's single table column
  stayed at AppKit's default 100 pt. Cells drew full-width content but only
  received clicks in the first 100 pt. The column now tracks the table width.
- **Reactions unreadable:** `withAlphaComponent(pressedAlpha)` replaced the palette
  colours' own transparency, which turned a 10% tint into an opaque pill in dark
  mode. Pressed state is now a transparency layer. Emoji metrics are shared between
  layout and drawing.
- **Images:** thumbnails use the server preview rendition at 360 pt × scale. Decode
  reservations are sized from image dimensions within the unchanged 32 MiB budget.
  Clicking opens an in-memory viewer (≤ 2048 px) with Save…; Escape/⌘W closes it.
- **Composer:** icon buttons have zero layout margins and one-line-field height,
  centred on a single line.
- **Names:** `TeammateNameDisplay`/`LockTeammateNameDisplay` are now applied.
  Previously only the personal preference was, so usernames showed by default. DM
  rows show the partner's avatar and presence.
- **Member list:** not reproduced. Offline stress tests passed at 760 and 1100 pt
  (150 long-named members with avatars, thread↔details swaps, binding writes,
  resizes, both popover paths). So did a new live XCUITest on the real app: sign-in,
  details pane, members, profile popover, menu responsiveness. Sampling during that
  run showed an idle main thread. The user reported a beach-ball freeze, not a
  crash. The member profile popover is now anchored to the clicked row. Next time,
  capture `sample MatterMac 5 -file /tmp/mattermac-hang.txt` while it is frozen.
- **UI tests were using real accounts:** XCUITest launches restored the developer's
  Keychain sign-ins (shared bundle ID/signing), which explains the 6 first-launch
  failures recorded yesterday, including on HEAD. Those runs connected to the
  developer's server, though they typed nothing. `-MatterMacUITesting YES` (Debug
  only) disables the account store.
- **New:** Dock mention badge; opt-in content-free notifications for mentions/DMs
  (account menu › Show Notifications, Play Sound), with click-to-open; Set Custom
  Status… with presets and "clear after" (`PUT`/`DELETE /users/{id}/status/custom`).
- The blur seen yesterday under the toolbar does not occur in the real `Window`
  scene (XCUITest screenshot); it was an artifact of hand-built test windows.

### Verification

- `MM_KEYCHAIN_TESTS=1 swift test --package-path Packages/MatterMacKit`: **253
  tests reported, all passed** (UI 105, API 26, models 10, Core 84, realtime 28); no
  Swift compiler warnings. Evidence: `/tmp/mattermac-fixes-full-tests.log`.
  New here: `ChannelInfoPaneTests`, `NameDisplayTests`, `IncomingAlertTests`,
  `CustomStatusTests`, plus the agent's `TimelineInteractionTests`,
  `ComposerLayoutTests` and pipeline/integration additions. `IncomingAlertTests`
  passed 5 consecutive runs after a test-only event-drain fix.
- Live (`MM_LIVE_TESTS=1`, credentials sourced from the ignored file):
  `LiveConversationTests`, `LiveMessagingTests`, `LivePeopleTests` (now also
  `TeammateNameDisplay` and custom status set/read/clear) and `LivePeopleUITests`
  all passed on the local deployments. Evidence: `/tmp/mattermac-fixes-live-tests.log`.
- `TEST_RUNNER_MM_LIVE_TESTS=1 TEST_RUNNER_MM_TEST_ALICE_PASSWORD=… xcodebuild …
  -scheme MatterMacUITests … test`: **8 tests, 0 failures** (7 first-launch plus
  the live member-list test). Evidence: `/tmp/mattermac-fixes-uitests.log`.
- Release build succeeded (arm64 + x86_64, strict signature verified, only the
  AppIntents metadata warning). Executable **19,110,144 bytes**.
  Evidence: `/tmp/mattermac-fixes-release.log`.

### Open issues and next task

1. Have the user retest the member list on their server; if it freezes, sample it.
2. Notification delivery and click-to-open were not exercised in a signed app with
   granted permission (the test host has no bundle); verify manually.
3. Custom emoji, command dialogs/ephemeral posts, VoiceOver audit, official-client
   peer exchange, and executable-size attribution remain open. Nothing committed.

## 2026-09-25 — parity push: glass UI, threads, search pane, parallel feature merges

The user asked to keep going until MatterMac can replace the official client (calls
excluded), to improve the UI with Liquid Glass, and to push regularly. Three
parallel agents worked in isolated git worktrees; the lead merged each branch into
`main`, resolved conflicts, reran the full suite and pushed. Decisions 0022–0024
record the agents' work.

- **Lead:**
  - Liquid Glass composer field and floating glass banners, onboarding cards, and
    shared `GlassStyle` helpers with material fallbacks before macOS 26.
  - Threads view for collapsed reply threads, with an unread badge. Open CRT threads
    are now marked read under the channel visibility policy; before, they never
    became read.
  - Trailing results pane for search, Recent Mentions, Saved and Pinned messages.
  - Pane-wide file drops, Markdown formatting shortcuts and Format menu, and channel
    rename/purpose/header editing.
  - Accessibility audit XCUITest with contrast and label fixes. Sidebar width fix.
- **Agent A (timeline):** hover action bar, pin/save, mark as unread with a read
  hold, in-app permalinks, who-reacted tooltips, link preview cards, edited
  indicators. Found and fixed `flagged_post` preferences being dropped.
- **Agent B (sidebar):** server sidebar categories with collapse, team rail and
  ⌘1–9, Browse Channels (⇧⌘L), Create Channel, New Message (⇧⌘K), Add Members,
  ⌥↑/↓ navigation, draft markers.
- **Agent C (notifications/settings):** alerts follow account and channel
  `notify_props` and mention keys, optional preview opt-in, in-app sound and Dock
  bounce, per-channel preference sheet, and a Settings window (⌘,) that separates
  in-memory local settings from explicit server settings. Found and fixed SwiftUI
  Settings tabs writing to UserDefaults.

### Verification

- `swift test --package-path Packages/MatterMacKit` after the final merge: **355
  tests, all passed, zero warnings** (UI 131, Core 128, API 52, Models 17,
  Realtime 27). Evidence: `/tmp/mm-merge-b.log`.
- `xcodebuild … -scheme MatterMacUITests … test` with live env via `TEST_RUNNER_*`:
  **12 tests, 0 failures**. This includes first launch, accessibility audit, the
  live member list, Settings and the visual tour. Evidence:
  `/tmp/mm-merged-uitests.log`.
- New live tests (`LiveThreadsTests`, `LivePostListsTests`, and the agents'
  `LiveInteractionTests`, `LiveSidebarTests`, `LiveNotificationPreferencesTests`)
  passed on the local deployments; each test restores or deletes what it changes.
  Agent B's channel-creation test can leave archived `mm-sidebar-*` channels.
- Known flakes: `testClosingWindowKeepsAppRunningAndWindowMenuReopensIt` failed once
  in a full run and passed twice alone. Some UI-target timing tests fail about 1 in
  6 runs under load, also on older commits (agent A measured this).

### Next

Custom emoji rendering, own-profile editing and picture upload, slash-command
autocomplete, file search, message-attachment polish, a large-account performance
pass, and a manual Notification Center check in a signed build.

## 2026-09-25 — recovered Claude session and continued parity work

Recovered the Claude conversation corresponding to external thread
`2869eabb-770a-4ce4-8999-4702ebdf0267` from local session
`dca76cd8-d2e6-4075-828b-4d7be73b4616`. Its last turn stopped at the usage limit.
Three interrupted worktrees still contained uncommitted changes; replacement
agents are continuing the original custom-emoji/command-completion,
profile/file-search, and rendering/performance tasks in those worktrees.
The original agent processes were not resumed.

The main checkout also retained a demo-content seed and unfinished live UI-test
changes. Sidebar channel accessibility labels include unread/mention state and
are combined elements, so the tests now query the element rather than assuming
it is a static text field. The visual tour covers seeded messages, a thread,
search and Settings; its multi-character search input now uses `typeText`.
Screenshots explicitly activate the app and capture only its window.

- `swift test --package-path Packages/MatterMacKit --filter LiveSeedDemoTests`:
  compiled without warnings; seed test skipped because `MM_SEED_DEMO` was unset.
  The seed is opt-in, targets only the repository-owned localhost server and
  leaves demo content there deliberately. Existing content is not re-created.
- Initial recovered visual-tour run reached all states through the thread, then
  failed on the incorrect `typeKey("release")` call; fixed before the next run.
- Full live XCUITest run (`TEST_RUNNER_MM_LIVE_TESTS=1`, password sourced from
  the ignored environment; `xcodebuild -workspace MatterMac.xcworkspace -scheme
  MatterMacUITests -configuration Debug -derivedDataPath build test`): **12 tests,
  zero failures**. Evidence: `/tmp/mm-recovered-uitests.log`. The audit remains
  a report, not a clean accessibility certification. Recovered feature branches
  are still in progress. Official-client interoperability, real IMEs, Notification Center,
  privacy audits, minimum-OS execution and the complete performance gates are
  still unverified; this recovery is not a replacement-readiness claim.

### Late command result after navigation

A delayed slash-command response wrote its feedback into whichever channel was
currently visible. The response now checks the composer generation, selected
channel, cancellation and detached-session state before presenting feedback;
completion still releases the original draft reservation. A gated regression
covers both staying and navigating, including preservation of the new draft.
`swift test --package-path Packages/MatterMacKit --filter
ConversationIntegrationTests/commandFeedbackStaysInItsConversation` failed on the
navigation case before the fix and passed both cases afterward, with zero
compiler warnings (`/tmp/mm-command-feedback-before.log`,
`/tmp/mm-command-feedback-after.log`).
