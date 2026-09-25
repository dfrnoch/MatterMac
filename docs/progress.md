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

### Sidebar accessibility and recovered visual tour

Channel/DM rows now expose a button role, selected state and a default activation
action. The signed-in accessibility audit no longer reports their unknown roles.
The member-list test explicitly requires the channel button and matches the
member's `@bob` label, avoiding the newly accessible DM button. The first recheck
caught that ambiguous test selector; the corrected member-list recheck passed.
The active-window visual tour also passed through search and Settings.

- `xcodebuild … -only-testing:MatterMacUITests/AccessibilityAuditUITests/testSignedInMainWindow
  -only-testing:MatterMacUITests/LiveMemberListUITests
  -only-testing:MatterMacUITests/LiveVisualTourUITests test`: audit and tour passed;
  member test failed on its ambiguous selector (`/tmp/mm-sidebar-accessibility.log`).
- `xcodebuild … -only-testing:MatterMacUITests/LiveMemberListUITests test` after the
  selector correction: **1 passed**, `/tmp/mm-sidebar-member-recheck.log`.
- Remaining audit reports include contrast, SwiftUI container labels and native
  menu actions; no blanket accessibility pass is claimed.

### Recovered rendering milestone integrated

Integrated the recovered rendering branch (`8284c31`, `be2f1e5`; main equivalents
`0f8b0a3`, `585dd52`). Task markers, native TextKit tables, quote/code decorations,
and attachment cards now share the same measurement and display path. Attachment
images remain explicit safe links; no third-party image fetch was added. Copy
Text retains image links and unsupported-action notices. See decision 0027.

`swift test --package-path Packages/MatterMacKit` on the integrated main branch:
**361 tests reported, all passed**, zero compiler warnings (UI 134, Core 129,
API 53, Models 18, Realtime 27; opt-in live/Keychain/demo checks were not enabled).
Evidence: `/tmp/mm-rendering-integrated.log`. Performance measurements and the
other two recovered feature branches remain in progress.

### Recovered daily-use features and asynchronous isolation

Integrated custom emoji (inline/reactions/picker/completion), command completion,
own-profile editing and picture updates, and file search/preview/navigation. The
recovered branches include focused fixture and live tests against all three local
servers; the final combined live verification is still pending. Native rendering
measurements and their limits are recorded in `docs/benchmarks.md`.

Hardening after integration fixed canceled searches returning into reopened
queries, overlapping pagination skipping pages, and revoked file results retaining
an open preview or accepting a delayed response. Search invalidation now covers
all result kinds. Duplicate server emoji pages stop instead of paging forever.
Encoded forward/backslash dot traversal is rejected before both direct HTTP
requests and redirects; the real loopback regression failed before the fix and
all 22 transport tests passed afterward (`/tmp/mm-encoded-traversal-after.log`).

The first combined package/Keychain run exposed a thread-test race: its revision
assertion overlapped the independent startup refresh. It now waits for that
refresh. Investigation also found two production bugs: an event during a totals
request was lost, and switching teams could publish the previous team's totals.
One bounded refresh task now coalesces pending changes and checks the team after
the response. Followed-thread pages and follow-state reads reject stale team
responses too. Gated regressions fail on the old totals implementation and pass
with the fix; a separate gated page test checks a team switch.

`swift test --package-path Packages/MatterMacKit --filter CoreTests`: **142 tests,
all passed**, zero compiler warnings (`/tmp/mm-core-hardening.log`). Totals failure
reproduction: `/tmp/mm-thread-refresh-before.log`. Full combined package, app,
live and sustained-use checks are still in progress; no production-readiness or
completed privacy-audit claim is made by this milestone.

### Integrated verification and actual official-client exchange

The floating composer now overlays the full timeline, with bounded bottom insets
that preserve scroll anchors and exclude occluded rows from read tracking. Native
toolbar material is enabled. An attempted header background extension was rejected
because it expanded content under the sidebar; it is not part of the change.
See decision 0028. Increased contrast for the login captions, status/footer and
date separators addresses specific earlier audit reports; final audit pending.

Further gated regressions fixed membership responses restoring revoked access,
autocomplete clicks overwriting marked text, queued commands executing after pane
disposal, and profile popovers retaining their content after session detachment.

- `MM_LIVE_TESTS=1 MM_KEYCHAIN_TESTS=1 swift test --package-path Packages/MatterMacKit`
  with local credentials sourced from the ignored environment: **396 tests
  reported, all passed** (UI 147, Core 143, API 61, Models 18, Realtime 27),
  no Swift compiler warnings. `/tmp/mm-integrated-live-full.log`. Benchmark,
  optional fixture screenshots and demo seeding retain their separate opt-ins.
- `xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac -configuration
  Release -derivedDataPath build build`: passed (`/tmp/mm-release-build.log`).
  Universal arm64/x86_64 bundle: 28,024 KiB allocated; `codesign --verify --deep
  --strict` passed for the local ad-hoc signature. This is not Developer ID signing,
  notarization, or an Intel execution test. `otool -L` shows system frameworks and
  system Swift runtime libraries; no embedded web engine or third-party runtime.
  Xcode still emits its AppIntents metadata-extraction warning (no dependency).
- `OfficialClientInteropUITests/testOfficialPeerChannelAndDMAfterRestart`: actual
  Debug app as Alice, official Mattermost 11.11.1 web UI as Bob in an isolated
  headless browser context. Both exchanged a unique synthetic message and reply
  in Interop and their DM. MatterMac terminated, relaunched with isolated sign-ins,
  authenticated again and fetched both canonical conversations: **1 passed in
  62.587 s**, `/tmp/mm-official-interop2.log`. Browser-side screenshot:
  `/tmp/mm-official-dm.png`. This closes the basic official-peer messaging/restart
  gate, not complete official-client feature parity. Four clearly marked QA posts
  remain in the repository-owned test server. The harness requires an explicit
  `TEST_RUNNER_MM_WEB_INTEROP_MARKER` and a coordinated web peer; normal runs skip it.
  First attempt failed on XCTest's automatic text-view hit point; clicking the
  observed composer's center exercised the normal mouse path and succeeded.

The full syscall filesystem trace cannot run without administrator access:
`fs_usage` requires root and `sudo -n` requires a password. No permission prompt was
made. A scoped before/after app-storage inspection is being collected with the
long-run sampler; it will not be represented as a full privacy audit.

### Thread preference availability and final UI tour

Changing collapsed-thread preferences now republishes followed-thread availability
and counters, and late totals/pages check that the feature is still enabled. The
new regression toggles both directions; `swift test … --filter
'ThreadsTests|NotificationPreferencesTests'` passed (20 Core tests, plus 2 disabled
opt-in live cases reported by other targets), zero compiler warnings:
`/tmp/mm-crt-availability.log`.

The integrated XCUITest run passed **12 executed + 1 deliberately skipped official
peer test**, zero failures (`/tmp/mm-final-uitests.log`, result bundle dated
2026.09.25_02-51-18). The official-peer test passed separately as recorded above.
The visual tour captures actual-app channel/thread/search/settings states under
`/tmp/mm-final-tour`. Small footer/status contrast reports no longer appeared;
date/login/title/placeholder and native group/menu audit reports remain, so this
is not a clean accessibility audit. The search capture exposed clipped outer pane
edges; that layout defect is under investigation before the sustained run.

### Notifications, real reconnect gaps and sustained-run preparation

Followed-thread replies now honor the server's `posted.followers` eligibility
signal, including `desktop_threads` and channel overrides, without a follow cache
or per-reply API lookup. Focused decoding/policy/session coverage passed (40 tests),
and live checks on v11 subpath/v10 verified `desktop_threads=all` includes the
follower while `mention` does not; preferences restored and test posts deleted.
Evidence: `/tmp/mm-followed-notifications2.log`, `/tmp/mm-followed-live.log`.

Unknown-sender alerts previously spawned one untracked task per post. They now use
one tracked worker and a ResourceBudget cap of 32 pending alerts / 256 KiB,
including the in-flight event. Focus/read/membership/preferences are checked again
after lookup. Revocation, archival, edit and deletion purge pending content;
shutdown/auth loss cancel and clear it. The worker holds only IDs across await
and cannot remove the next entry if its own event was purged. **19 focused tests
passed**, zero warnings (`/tmp/mm-alert-invalidations2.log`). Overflow drops alerts,
never drafts or pending sends.

`LiveReconnectTests` closes a real production URLSession socket, refuses at least
one reconnect, then permits a new connection. On each of the three local servers,
Alice missed Bob's new post, edit and deletion while disconnected, then reconciled
all three; draft text and selection survived. Normal app shutdown cleared the
unsent ledger. **3 endpoint cases passed in 25.175 s**, zero warnings, synthetic
posts deleted and Bob logged out (`/tmp/mm-live-reconnect.log`). This tests socket
recovery, not physical Mac sleep/wake or a server outage.

The actual-app soak harness and standalone Swift sampler are in `docs/soak.md`.
The corrected smoke passed **5 complete profile/image/thread/search cycles in
165.011 s**. Debug-only preliminary samples: peak 112.20 MiB, last 92.02 MiB,
45 descriptors. These are not optimized or long-session acceptance results.
Early attempts exposed brittle XCTest assertions: native image windows were
visible although `app.windows.count` did not increase; search rows were not exposed
as XCUI buttons. The harness now checks visible viewer controls/results instead.
The scoped storage snapshot saw a preference plist mtime change, but did not have
before-values to attribute it; autosave behavior is being investigated, not yet
classified as an app-content persistence finding.

### Read-state ordering and stricter scene checks

Gated regressions reproduced three read-state races: changing channels during a
view request lost the next mark, a cancelled response undid explicit Mark Unread,
and a reply arriving during a thread mark never received its own mark. The keyed
workers now retain one deferred-evaluation bit each and reject cancelled responses;
a failed request alone cannot create a retry loop. Twelve focused Core tests passed
in `/tmp/mm-read-races-after.log` before integration.

A separate regression reproduced an older view event clearing counts for a newer
already-received post. The shared local-view update now preserves counts until the
view timestamp reaches the channel's latest post. The test failed before the guard
and passed after it; the combined read/thread run passed **11 Core tests**, plus one
disabled opt-in live case reported separately, with no compiler warnings
(`/tmp/mm-stale-view-before.log`, `/tmp/mm-stale-view-after.log`).

Removing `ApplePersistenceIgnoreState` from an actual-app launch check exposed a
windowless launch. The first `defaultLaunchBehavior(.presented)` change did not fix
existing empty restoration state: **2 failures in 9 UI tests** were retained in
`/tmp/mm-launch-layout-ui.log`. A stronger startup regression and native split-view
state checks are in progress; this failure must pass before the long soak.
The scoped actual-app metadata comparison after login/search/settings reported no
changes to either native split geometry key, but the attempted XCTest edge drag did
not resize the window, so it does not establish resize persistence behavior
(`/tmp/mm-layout-persistence2.csv`).

### Integrated hardening candidate

- Fresh launch and close/quit/relaunch now explicitly open the unique main scene
  once, without restoring geometry. The no-persistence-override regression passed,
  as did the existing close/reopen paths. A process-lifetime native split observer
  clears autosave names before resize; a native fixture and five standalone scene
  phases passed. This does not replace minimum-OS execution.
- The sampler's first geometry comparison mistakenly split a **single comma-containing
  preference key** into two keys. Its earlier `changed=0` results did not measure the
  actual native key. Commit `6baf5e1` corrects this and its self-test; the subsequent
  actual-app login/thread/search/settings capture reported `changed=0, valid=1` for
  the correct key in both roots (`/tmp/mm-layout-persistence4.csv`). Three XCTest
  edge/corner drag attempts did not resize the app; those unreliable gestures are
  not retained as a passing resize test. Native programmatic resizing and pane
  geometry are covered separately.
- The actual 1100-point window's 276-point sidebar reproduced a nested split that
  extended to 1116.5 points. Replacing the inner split with a horizontal stack and
  divider fixes the overflow; the outer sidebar remains resizable. Tests cover
  760/976/1000/1100 widths and draft restoration. The actual search close-button
  margin assertion passed, and the captured layout no longer clips its right edge.
  Category heading contrast also improved. Final UI recapture is pending below.
- Cancelled/replaced server discovery no longer reopens login or surfaces old
  errors. Eight noncooperative success/failure scenarios reproduced before the fix
  and passed afterward. One owned Connect probe is cancelled on Cancel/disappear.
- Superseded history successes and failures now check cancellation and the current
  load generation. Three gated cases reproduced nine failed assertions before the
  fix and passed afterward; 50 focused tests passed. Initial live reconnect checks
  intermittently timed out before loading history, including one isolated run;
  this exact live failure has not been conclusively attributed to the deterministic
  race. A subsequent isolated three-endpoint run passed in 29.392 seconds.

The first integrated run exposed two test-fixture errors as well: the fake read
endpoint returned a timestamp of one millisecond after the epoch, and conversation
fixtures created controllers before initial sidebar loading completed. The latter
let the initial empty snapshot retire the controller before the test started; it
was not evidence of a production unsent-image ledger loss. Corrected readiness
ordering passed 30 repeated image-recovery cases and the related combined suite.

`MM_LIVE_TESTS=1 MM_KEYCHAIN_TESTS=1 swift test --package-path Packages/MatterMacKit`
now reports **417 tests, no failures**: UI 151, Core 158, realtime 29, models 18,
API 61 (`/tmp/mm-hardening-full2.log`). Separate opt-in browser-SSO, benchmark,
process-restart, visual-capture and seed cases remain skipped in this command.
No Swift compiler or SwiftUI runtime warnings appeared. The unmodified universal
Release build succeeded (`/tmp/mm-release-final.log`); strict deep signature
verification passed, architectures are arm64+x86_64, and dependencies are Apple
frameworks/Swift libraries. Allocated bundle size: 28,180 KiB. This is ad-hoc local
signing, not Developer ID/notarization. The standard AppIntents metadata-extraction
warning remains. Final actual-app UI and sustained-run results follow separately.

The final actual-app suite passed **13 enabled tests + 2 opt-in skips**, zero
failures, in 188.853 seconds (`/tmp/mm-hardening-uitests.log`). It includes the
ordinary launch regression and explicit search-field/value/right-margin checks;
visual attachments are exported under `/tmp/mm-hardening-tour`. The accessibility
audit still reports native/date/title/placeholder findings, so its reporting test
passing is not accessibility certification. Two further isolated reconnect runs
passed all three endpoints each (29.335 s and 23.256 s), in addition to the latest
combined run: `/tmp/mm-reconnect-final-1.log`, `/tmp/mm-reconnect-final-2.log`.
The live test now distinguishes initial-history from live-edge deadlines and
reports only scalar state flags on an initial-history timeout.

Runtime candidate: `5af680b`; later changes through this checkpoint are test and
documentation only. Host: Apple M1 Pro, 16 GiB RAM, MacBookPro18,3, macOS 27.0.
The optimized test variant's two-hour active workload plus settling/five-minute
idle sampling is the remaining local sustained-run gate; no duration result is
claimed before it completes.

### Additional lifecycle review during the sustained run

Hosted CI for `47f3a3c` passed (run `36083607466`), including the package tests and
universal app build. Its fixture fix gives directory and navigation readiness
separate deadlines; a shared deadline could expire while hosted actor work was
still completing and then skip the navigation wait entirely.

Read-only review found Notification Center retention gaps: the oldest tracked ID
was forgotten without withdrawing its delivered alert, and quit did not withdraw
delivered alerts. `47a2431` removes pending/delivered alerts on eviction, sign-out,
disable and shutdown; delayed add completions re-remove invalidated requests.
Authorization results are generation-checked so disabling or quitting while the
permission request is pending cannot re-enable notifications. Focused tests cover
the 65th alert, account isolation, delayed callbacks and shutdown/authorization
races. Test targets compile without warnings; execution is deferred until the
exclusive UI soak completes. This change is outside the running soak's binary;
the final app must be rebuilt and validated after integration.

`741ec98` fixes sender ownership: a retry-wait item could still be labeled sending,
so revoking its channel cancelled the single sender even when it was processing
a different channel. Cancellation now checks the executing pending ID. Explicit
retry also cancels its older automatic timer, preventing that timer from marking
an active POST queued and allowing an unsafe discard. Gated regressions compile;
execution remains queued behind the soak. `ec571c3` additionally scopes notification
clicks to a random in-memory app-instance identity, rejecting notifications retained
by macOS after a previous process ended. Forced termination cannot run cleanup;
documentation now makes that OS retention limit explicit.

Hosted CI for `ec571c3` passed package tests (including the new sender and
notification regressions) and the universal build: run `36085096911`. Local
live/Keychain checks and the final artifact rebuild remain queued after the soak.

The ongoing baseline showed sustained footprint drift, prompting content-free
`vmmap -summary`, `leaks --noContent --forkCorpse` and `heap --noContent --forkCorpse -s`
inspection. The leak scan found 1,792 unreachable allocations totaling 63,968 bytes,
mostly native menu configuration objects; that small total did not explain the
drift. The heap snapshot found **810 `TimelineRowView` instances**, while there was
only one conversation/timeline/composer controller and five message cells. The
custom row class declared a reuse identifier but never assigned it, unlike sibling
cells. `2d3e831` supplies it in the initializer. Its effect on the actual app still
requires the patched workload comparison.

The first reuse fixture failed hosted CI: it synchronously requested and retained
80 temporary offscreen rows. The SDK explicitly limits the lifetime of temporary
`rowView(atRow:makeIfNecessary:)` results to the current run-loop cycle. `7f61b9d`
corrects the fixture to observe displayed rows, yield between reloads and retain
only weak references, without raising its eight-row allocation bound. Local
red/green execution is deferred until the exclusive baseline ends. Profiling
interruptions will be included with the final timing evidence; the original
running binary has not been replaced by these fixes.

The displayed-row fixture also failed with 80 cumulative allocations. A further
SDK check established that `reloadData` explicitly drops all known views, so that
total allocation expectation was invalid even when rows are released correctly.
`4f9c3fe` instead scrolls one 100-post snapshot and checks weakly tracked **live**
rows remain within two observed viewports. It is still pending runtime red/green
verification; passing compilation alone is not evidence that the reuse fix works.

The full baseline completed **252 cycles in 7,223.092 active seconds**, with zero
workflow assertions. Its sampled peak was **154.91 MiB**, idle median **79.75 MiB**,
and consecutive half-hour medians **104.33 / 114.20 / 125.64 / 136.34 MiB**. These
miss the proposed memory targets and demonstrate sustained growth. Final heap
inspection found 1,458 timeline rows versus 810 earlier, with one controller of
each major kind. The full measurements, profiler interruptions and storage scope
are recorded in [soak.md](soak.md). Correct geometry-key comparisons stayed
unchanged/valid in both roots.

After releasing the exclusive lane, local red/green verification of
`scrollingKeepsNativeRowRetentionBounded` failed 18 assertions without the identifier
(live rows 33–220 against a 22-row bound), then passed in 0.928 seconds with it
restored. Hosted CI `36089048119` also passed for `4f9c3fe`.

The subsequent combined live/Keychain package run exposed a DM navigation timeout
(`/tmp/mm-release-candidate-package.log`). An isolated rerun passed, but inspection
found a real race: an older sidebar snapshot could clear a newly created DM's
selection and retire its composer. A deterministic retained-snapshot test failed
three assertions before `bd0d4d3`; the fix revalidates current membership and team
eligibility before clearing selection, then rechecks lifecycle and selection after
the actor hop. Four focused cases passed, including team switching and actual
revocation. No timeout was increased. An explicit serial combined run separately
exposed the rapid category-toggle save race (`/tmp/mm-release-candidate-serial.log`);
its correction and final combined rerun follow below.

`b94c7df` fixes rapid category toggles with the existing bounded pending-value map
and a single worker per category. Later clicks replace the desired value; each
write re-reads the server category, and a later failure restores the last confirmed
server value. The gated regression failed 11 assertions before the fix, then all
19 focused Core tests passed, covering success, refusal and cancellation.

The normal combined command (without serializing the tests), with
`MM_LIVE_TESTS=1 MM_KEYCHAIN_TESTS=1`, now passes **428 reported tests**: UI 159,
Core 161, realtime 29, models 18, API 61. Separate opt-in cases remain skipped as
described above. `/tmp/mm-final-integrated-package.log` contains no Swift compiler
or SwiftUI runtime warnings. The final runtime candidate is `b94c7df`; the
unmodified Release build, actual-app UI suite and patched soak are the remaining
artifact checks at this checkpoint.

### Final artifact and explicit remaining gates

The unmodified universal Release build at runtime `b94c7df` succeeded
(`/tmp/mm-final-release-build.log`). Strict deep signature verification and ZIP
integrity passed; both arm64/x86_64 slices link Apple frameworks/Swift libraries.
The only build warning is the standard skipped AppIntents metadata extraction.
Hosted CI **36092699575** passed package tests and the universal build for this
runtime. Local packaging is ad-hoc signing, not Developer ID or notarization.

- App: `build/Distribution/MatterMac.app` (28,224 KiB allocated).
- Archive: `build/MatterMac-universal.zip` (7,833,723 bytes).
- SHA-256: `614eb46ccce4dc6f5a407654a79e4ce4e9303805bbbe6fb9a22fd0a91f252aac`.
- Local source/toolchain/signing metadata: `build/Distribution/BUILD-INFO.txt`.

The final actual-app UI rerun was **blocked**, not passed. macOS automatically
locked before launch (`CGSSessionScreenIsLocked=Yes`); XCUITest failed to activate
the Debug app, reporting Running Background. The owned test process was stopped
(`/tmp/mm-final-candidate-uitests.log`). No unlock or authentication bypass was
attempted and the sleeping user was not asked to intervene. Consequently the
prepared patched 15-minute app soak was not launched. The earlier 13-enabled-test
UI pass remains evidence for runtime `5af680b`, not this final binary.

A narrower native AppKit check works behind the locked screen: the row-retention
fixture passed **1,000 cycles in 45.014 seconds**, keeping the same two-viewport
live-row bound with no issues or warnings (`/tmp/mm-row-retention-1000.log`). Only
the test loop count changed temporarily; the original 20-cycle source was restored
and the worktree is clean. This does not establish the patched app's whole-process
memory plateau. The two-hour baseline's memory misses remain recorded, not waived.

Next concrete task: from an unlocked desktop, rerun the final actual-app suite and
the patched sustained workload in [soak.md](soak.md), comparing row counts and
footprint. Remaining release gates also include minimum-OS/Intel execution, real
IME/VoiceOver coverage, a full filesystem audit, startup/input latency, broad IdP
validation, and Developer ID/notarization. The built local candidate should not be
described as a certified production release.

## 2026-09-25 — morning UI corrections and sidebar polish

- Removed the table's click-selection paint while retaining keyboard selection,
  message actions, and pointer hover feedback.
- Corrected reaction emoji drawing to use the same top-origin text layout as its
  measured bounds. The light/dark bitmap regression failed before the change
  (heart ink 9 pt above the pill, center displaced 12.5 pt) and passes afterward.
- Let the main conversation extend behind the toolbar; native top content insets
  keep its initial message visible. Added horizontal space around DM presence.
- Added a native behind-window sidebar material, hid the List's opaque scroll
  background, and kept that material active when the window loses focus.
- Added a curved rail/channel divider and a padded Liquid Glass profile capsule
  with a larger avatar and session gear menu. Raised the sidebar minimum when the
  rail is present so account text does not wrap into single-word fragments.
  Visual reference: https://github.com/SakuraCordApp/SakuraCord and the user's
  screenshot. Reused MatterMac's glass helper; no SakuraCord code or private
  WindowServer blur APIs were imported.
- On macOS 26+, the toolbar title has a narrow AppKit drag region calling
  `NSWindow.performDrag(with:)`. Its ungrouped principal placement keeps the title
  readable and the action controls at the trailing edge. Earlier macOS versions
  retain their existing native title. No timeline-wide dragging was enabled.

Verification: `swift build --package-path Packages/MatterMacKit` and Debug app
build passed. The focused `ConversationIntegrationTests|TimelineInteractionTests|
MessageActionsTests|SidebarShellTests|ReactionPickerTests` run passed 43 tests in
17.307 s. The follow-up layout run passed 22 tests in 16.902 s after eliminating
an empty toolbar item's ambiguous-size warning. Final opt-in
`MM_GLASS_SNAPSHOTS=/tmp/mm-polish-glass ... --filter captureFloatingChrome`
passed; reviewed actual light/dark native window captures, including the rail,
profile capsule, trailing toolbar controls, and messages blurred under the header.
The fixture now asserts positive top insets and actual toolbar underlap.
The existing SidebarShell sheet test still emits AppKit's reentrant-table-delegate
runtime warning; no Swift compiler warnings were introduced.

Drag verification limitation: XCUITest reported zero movement for both the chat
header and a control drag of the untouched sign-in window. Direct automation did
not establish movement either. Therefore actual pointer-driven window movement
is not claimed as verified. Some live-tour screenshots also failed on the second
monitor. Temporary diagnostic changes to the live tour were restored; no failing
or skipped checks were hidden in committed test code. Next manual check: drag the
conversation title in the packaged app on the user's normal desktop.

Final universal Release build passed (`/tmp/mm-polish-release-verified.log`),
with only Xcode's existing skipped-AppIntents-metadata tool warning. Staged
`build/Distribution/MatterMac.app`; `codesign --verify --deep --strict` passed and
`lipo -archs` reported `x86_64 arm64`. Refreshed `build/MatterMac-universal.zip`,
SHA-256 `17f11bea7be43d83d16c0e620f9d4abd5da6338223018a8036b585728e177d2a`.
The running `/Applications/MatterMac.app` was not replaced or terminated.

## 2026-09-25 — float the account pill over the channel list

Removed the reserved sidebar footer and its horizontal divider. The account
capsule now overlays the channel List, so rows scroll behind its glass. Scroll
content bottom margins let the final row clear the capsule. Healthy connections
show no redundant “Connected as” line; connecting/disconnected notices and the
Reconnect action remain available as a separate floating notice when needed.

`swift test --package-path Packages/MatterMacKit --filter
'SidebarShellTests|ConversationIntegrationTests.captureFloatingChrome'` with
`MM_GLASS_SNAPSHOTS=/tmp/mm-floating-profile` passed three tests in 15.728 s.
Expanded the visual fixture to 30 channels and drove its fake realtime connection
to connected; the follow-up capture passed in 6.565 s. Inspected light/dark native
captures: no footer strip, no connected label, channel rows extend beneath the
account capsule. The pre-existing AppKit reentrant table delegate runtime warning
remains in the sidebar sheet test.

Universal Release build passed (`/tmp/mm-floating-profile-release.log`), with only
the existing skipped-AppIntents metadata warning. Refreshed
`build/Distribution/MatterMac.app` and verified its signature. Updated ZIP SHA-256:
`c656b8d9441c3ca0bec9cdcd0f2f13813b22066672e0db67cb0aadfc1aff1157`.

## 2026-09-25 — jump-to-latest pill and team name in the title bar

Replaced the timeline's plain push button with `JumpToLatestPill`: a 30 pt
Liquid Glass capsule (`NSGlassEffectView`; menu-material capsule before macOS 26)
with a soft shadow, a semibold title and a leading arrow. New messages lead with
a white arrow on an accent disc instead of tinting the surface: with the
Graphite accent a tinted glass surface put white text on light gray in light
mode. The content is still a borderless `NSButton` for VoiceOver and keyboard
access.

The team name (with the server name beneath it when several servers are signed
in) moved from a row above the channel list into the title bar, beside the
traffic lights, as a menu with a chevron. The menu holds the former `+` menu
items. In the full-size-content window a `.navigation` item landed in the detail
column, so it is an `.automatic` item declared by the sidebar, sized to the
column width minus 154 pt (decision 0030). Long names truncate and the sidebar
toggle stays in the column. This was checked with a temporary "GeekBoy -
Technology Community Server" fixture name. A hit test at the title found the
toolbar item's hosting view, not the title bar.

New `jumpToLatestPillFollowsTheLiveEdge` (dark and light) checks title,
prominence, centering, the button action, and hiding at the live edge;
`MM_SNAPSHOT_DIR` captures only its own window. Calling `performClick` on the
pill's button in that test made the parallel UI-test process exit early with
status 0 and no summary, so the test invokes the action directly and asserts
target/action. `swift test --package-path Packages/MatterMacKit` passed
(`/tmp/mattermac-jump-title-tests.log`), and the UI-support target alone passed
161 tests (`/tmp/mattermac-jump-title-uitests.log`). Debug workspace build passed
with only the existing AppIntents metadata warning
(`/tmp/mattermac-jump-title-build.log`). Not checked in the packaged app against
a live server; the Distribution build was not refreshed.

### Sidebar edge and in-window media viewer (same session)

The channel list is clipped at its top edge, and the macOS 26 top scroll edge
effect is hidden. Rows no longer scroll on under the traffic lights, where they
were blurred. `captureFloatingChrome` now also scrolls the channel list.

Image attachments open in `MediaViewerController`, an in-window viewer over the
whole window, including the title bar (decision 0030). The design was studied
from SakuraCord's GPL-3.0 viewer; no code was copied. It shows:

- the author avatar and name, date, file name and "n of m" at the top left;
- a glass group with Copy Image, Save… and Actual Size/Fit, plus a separate Close
  button, at the top right;
- previous/next buttons and arrow keys for a message's images;
- double-click, pinch and ⌘+/⌘-/⌘0 zoom, with drag to pan;
- Escape, Space, ⌘W or a click outside the image to close.

The timeline thumbnail (the same leased `Decoded`) stands in while the preview
loads. `ImageViewerWindow.swift` was removed; file search uses the same viewer.
Video and other files still go through Save only; playback is not implemented.

New `mediaViewerCoversTheWindowAndMovesBetweenAMessagesImages` checks:

- the overlay is on the frame view and first responder;
- the author, time and three-image content are set;
- → loads the next preview;
- zoom toggles;
- Escape removes the overlay and releases its leases.

Captures from it were inspected (`MM_SNAPSHOT_DIR`). Full
`swift test --package-path Packages/MatterMacKit` passed; the UI-support target
ran 162 tests (`/tmp/mattermac-viewer-tests.log`). The Debug workspace build
passed with only the existing AppIntents warning
(`/tmp/mattermac-viewer-build.log`). None of this was checked in the packaged
app against a live server, and the Distribution build was not refreshed.

Next: check the viewer and title placement in the real app window with a local
test server. Then decide whether to stream video through the app transport.

## 2026-09-25 — on-device content cache (user request)

The user rejected the session-only rule: "I want cache, images, profiles and
anything that is good to be loaded fast should be cached on device, recent chats
too." Implemented `ContentCache` (decision 0031; SPEC §2/§7, AGENTS.md,
architecture updated).

- **Models:** `Codable` added to models (synthesized), with validating decoders for
  `SafeLink` and `SidebarCategoryID`.
- **ContentCache (MatterMacCore/Persistence):**
  - per-account AES-GCM files; kind and name are authenticated;
  - digest names;
  - two LRUs, bounded by `ResourceBudget.diskCache`;
  - index rebuilt from disk;
  - excluded from backups.
- **Keys:** `KeychainCacheKeys` (MatterMacPlatform) stores one random 256-bit key
  per account in the login Keychain.
- **ImagePipeline:** reads compressed bytes from disk before the network; writes
  them only after a successful decode; proxied images are excluded.
- **ServerSession:**
  - restores the directory, selected team and last channel before the first
    request;
  - seeds empty channel windows from cache (`HistoryWindow.isCached`);
  - cached windows never mark channels read, keep the unread-line jump for the
    server page, reload on the next open, and are never written back;
  - writes are coalesced (4 s) and at quit (`persistCache()`);
  - membership loss removes the channel's cached posts.
- **UI:**
  - the sidebar selects `restoredChannel`;
  - Sign Out, server-ended sessions and saved sign-ins rejected at restore erase
    the account's cache and key;
  - Settings ▸ Accounts has a Cache section (size, Clear Cache);
  - the privacy texts are updated.

Tests:

- New `ContentCacheTests` (4) cover:
  - encryption with no plaintext or names on disk;
  - relaunch index;
  - authenticated names;
  - tamper deletion;
  - the wrong key;
  - account removal and later writes being no-ops;
  - LRU bounds and the per-object limit;
  - Clear Cache;
  - pipeline disk hits across relaunch at another size, and proxied images never
    being cached.
- New `SessionCacheTests`: on a relaunch with the channel list and posts held back,
  the sidebar, profiles and last channel come from cache. The cached window shows
  the five cached posts and does not mark the unread channel read. The server page
  (six posts) then replaces it and the channel is marked read. This test found
  that a replaced cached window needs an explicit read re-evaluation; fixed.
- New opt-in `KeychainCacheKeysTests` (`MM_KEYCHAIN_TESTS=1`): real login-Keychain
  round trip under a throwaway service. Passed.
- `swift test --package-path Packages/MatterMacKit` passed (Core 166, UI-support
  162; `/tmp/mattermac-cache-tests.log`). The Debug workspace build passed with
  only the existing AppIntents warning (`/tmp/mattermac-cache-build.log`).

Not verified: the packaged app against a live server (launch speed, and the cache
directory contents in the container). `FirstLaunchUITests` disclosure text was
updated but not run; XCUITests drive the shared desktop. The Distribution build
was not refreshed.

Next: run the Debug app against the local test servers (development cache
directory). Measure cold and warm launch-to-sidebar and channel-open times, and
inspect `~/Library/Containers/org.mattermac.MatterMac/Data/Library/Caches`.

## 2026-09-25 — the account turned "away" while the user was at the Mac

Cause: MatterMac never sent `user_update_active_status`. The plumbing existed
(`SessionViewModel.userActivity()` → `ServerSession.reportUserActivity` →
`MattermostRealtimeClient`, throttled to 60 s), but nothing called it. The server
turns an account away `UserStatusAwayTimeout` (default 300 s) after the last
connect, post, manual status change or activity report
(docs/research/websocket.md §7, which predicted this).

Fix: new `UserActivityMonitor` and `UserActivityPolicy` (MatterMacPlatform).

- Every 15 s (5 s timer tolerance) it reads the system input idle time with
  `CGEventSource.secondsSinceLastEventType(.combinedSessionState, any input)`. No
  permission is needed. Any input on the Mac counts, like the Desktop App.
- Idle under 60 s reports active to every signed-in session.
- Idle of 300 s or more, screen sleep, system sleep or a session switch reports
  inactive once.
- It re-checks when MatterMac becomes active.
- The server ignores these reports for a manually chosen status (Away, DND,
  Offline), so they never override one.

Tests:

- `UserActivityTests` (3) cover the policy thresholds, the real idle reading, the
  monitor's transitions, and view model → realtime forwarding (none after detach).
- New opt-in `LiveActivityTests` on 11.11.1 root and 10.11.24: signed in as alice
  over MatterMac's socket, `last_activity_at` stayed unchanged for 2 s without a
  report. After one report it advanced and the status was `online`. **Passed**
  (`/tmp/mattermac-live-activity.log`).
- Full `swift test` passed (UI-support 167; `/tmp/mattermac-activity-tests.log`).
  The Debug build passed with only the AppIntents warning
  (`/tmp/mattermac-activity-build.log`).

Not run: a 5-minute real-time check in the packaged app.

## 2026-09-25 — README screenshots

`LiveSeedDemoTests` now attaches a drawn dashboard mockup ("Dashboard mockup v2")
and replaces the older flat placeholder on already seeded servers. New opt-in
`LiveReadmeScreenshotsTests` signs in as alice on the local 11.11.1 server. It
opens Design Demo, a thread and the image viewer, and captures only its own
full-size-content window, dark and light, under a volatile `en_US` locale. The
run passed. Four captures, downscaled to 1600 px, are committed in `docs/images`
(1.4 MB); provenance is in `docs/assets.md`. README gained the screenshots and
highlights, and its "What is saved" section now describes the content cache.

## 2026-09-25 — bundle identity and Developer ID signing

User requested `dev.frnoch.mattermac`, signing with their Apple account, and the
required GitHub keys. Updated the app/test bundle IDs and native soak sampler.
Debug uses Apple Development; Release uses Developer ID Application, team
`ZJ37A69485`, with secure timestamping. Existing Keychain service names are kept;
the new bundle ID has a fresh sandbox container (no cache migration).

Verified the David Frnoch account/team in Xcode Settings using computer use.
Exported only its existing Developer ID identity with Security.framework into an
encrypted PKCS#12 in memory, and piped it and a random export password directly to
`gh secret set` for `dfrnoch/MatterMac`. No private key or password was printed or
written to the repository. Verified both secret names with `gh secret list`.

Added the manual, main-only `Signed app` workflow: temporary runner Keychain,
universal Release build, Developer ID/team/bundle requirement verification,
signed ZIP artifact, and unconditional signing-material cleanup. PR CI remains
ad-hoc and never imports signing secrets. Notarization is not configured and the
artifact is explicitly documented as signed, not notarized.

Validation:
- `xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac -configuration
  Release -derivedDataPath build build` passed (`/tmp/mattermac-signing-release.log`).
- `codesign --verify --deep --strict` and an explicit Developer ID certificate,
  team and bundle-ID requirement passed for the resulting Release app.
- `codesign -dvv` reports Developer ID Application: David Frnoch (ZJ37A69485),
  hardened runtime, secure timestamp; `lipo -archs` reports x86_64 and arm64.
- Release entitlements are exactly App Sandbox, network client and user-selected
  read/write files; no get-task-allow.
- Both workflow files parse with Ruby YAML; embedded shell passes `bash -n`.
- Existing AppIntents metadata extraction warning remains; no Swift warnings.

Debug workspace build and strict signature verification also passed
(`/tmp/mattermac-signing-debug.log`), using the Apple Development identity.

GitHub validation of commit `db2bdd4`:
- [Signed app run 36126978154](https://github.com/dfrnoch/MatterMac/actions/runs/36126978154)
  passed every step, including import, build, identity requirement, artifact
  upload, and Keychain cleanup. Downloaded the ZIP into `build/github-signed`,
  extracted it and independently verified its strict signature and Developer ID,
  team and bundle requirement on this Mac. It is universal, hardened and timestamped.
- [Build and test run 36126968282](https://github.com/dfrnoch/MatterMac/actions/runs/36126968282)
  passed package tests and the ad-hoc universal app build.
- Local signed ZIP: `build/MatterMac-signed.zip`.

Next: configure notarization credentials and submit/staple a distribution build.
Notarization, clean-account installation, and migration from an old ad-hoc sign-in
are untested.

## 2026-09-25 — notarization and DMG distribution

User requested notarization to satisfy Gatekeeper and a DMG release artifact.
The manual `sign.yml` workflow now notarizes and staples the universal app, then
packages it with an Applications symlink into a signed UDZO DMG, notarizes and
staples the DMG, and uploads `MatterMac.dmg`. Both submissions require Apple's
`Accepted` result; both tickets and Gatekeeper assessments must pass before upload.
The job timeout is 60 minutes, with each notarization wait bounded to 20 minutes.

The user created the dedicated “MatterMac notarization” app-specific password in
Apple Account. Saved it directly from the browser into the repository Actions
secret `APPLE_APP_SPECIFIC_PASSWORD`, without printing it; also added `APPLE_ID`.
The existing Developer ID certificate secrets are reused. The workflow validates
and stores notarization credentials in its temporary Keychain, removed at exit.

Local packaging checks: copied the existing Developer ID app, added an
Applications symlink, built a DMG and verified its signature and image checksum.
The first `hdiutil create` check passed but macOS 27 emitted a deprecation warning;
the pipeline uses the native replacement `diskutil image create from` with UDZO.
Workflow YAML and embedded shell syntax checks passed. No runtime code changed.
The pre-existing Xcode project team overrides were left untouched.

[Notarized DMG run 36128025597](https://github.com/dfrnoch/MatterMac/actions/runs/36128025597)
passed for commit `2d2dfc7`, including credential validation and cleanup:
- App submission `79bfc653-c8d1-4ca0-bbfd-d939aea20171`: **Accepted**.
- DMG submission `f2ecce03-49f4-45c6-a67a-c8634b6db049`: **Accepted**.
- Downloaded artifact: `build/notarized/MatterMac.dmg`, 8,527,364 bytes.
- SHA-256: `d5225f90a73417d6d4a13e70b6f65b350edbbe0c03600e60e7e37709059621a7`.
- On this Mac, DMG strict signature verification and `stapler validate` passed;
  `spctl --assess --type open --context context:primary-signature --verbose`
  returned **accepted**, source **Notarized Developer ID**.
- Mounted read-only, verified the embedded app's strict signature and explicit
  bundle/team/Developer ID requirement, validated its stapled ticket and ran
  `spctl --assess --type execute --verbose`: **accepted**, source
  **Notarized Developer ID**. Confirmed x86_64 + arm64 and the `/Applications`
  shortcut, then unmounted and ejected the check volume. No app was launched.
- `diskutil image create from` packaging/signing check also passed locally.

Separate CI attempt 1 of run 36128013549 failed the existing
`SessionCacheTests.relaunchShowsCachedSidebarAndPostsBeforeTheServerAnswers`
profile assertion at line 71. The failed job was rerun without code changes;
[package tests and the universal ad-hoc build passed on attempt 2](https://github.com/dfrnoch/MatterMac/actions/runs/36128013549).
This intermittent test was not altered by the packaging task.

Next: clean-account drag-and-drop installation and first launch on macOS 14.
Do not distribute the earlier local packaging-check DMGs as notarized artifacts.

## 2026-09-25 — saved local settings, notifications on by default (user request)

The user asked for notifications and message previews to be on automatically and
reported that the notification switch was off again after reopening the app (the
"On This Mac" settings were memory-only). Decision 0032:

- `LocalSettings` saves notifications, previews, sound and sound name, Dock bounce,
  send behavior, text size and appearance through an injected
  `LocalSettingsStorage` (`UserDefaults.standard` from `AppComposition`, keys
  `MatterMac.*`). Loads are typed and validated; invalid values fall back to the
  defaults and loading writes nothing. Package tests and `-MatterMacUITesting`
  pass no storage; UI testing also starts with notifications off in memory.
- Defaults: notifications on, previews on; sound and Dock bounce stay on.
- `AppModel.refreshNotificationAuthorization()` runs after each sign-in (new or
  restored) and on app activation: it reads the macOS status and shows the
  permission request only while `.notDetermined`, at most once per launch, never
  without an account. Toggles show the saved choice; Settings says when macOS
  blocks notifications. Quit keeps the saved choice.
- Updated Settings header/privacy note, first-launch disclosure, About panel,
  README, compatibility table, SPEC §2/§7/§19 and AGENTS.md; the XCUITest string
  for the local-settings header was updated but XCUITests were not run.

Commands and results:
- `swift build --package-path Packages/MatterMacKit` (and `--build-tests`):
  succeeded, zero warnings.
- `swift test --package-path Packages/MatterMacKit`: exit 0; the five Swift
  Testing runs reported 177, 29, 18, 166 and 61 tests passed. New tests:
  `LocalSettingsPersistenceTests` (defaults, save/restore via a new environment,
  invalid values, memory-only mode), automatic-authorization tests in
  `SettingsAndAttentionTests`, and saved-choice/no-account checks in
  `NotificationLifecycleTests`. All use an in-memory storage and fake
  notification center; no real defaults domain or Notification Center was used.
- `xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac -configuration Debug -derivedDataPath build build`:
  **BUILD SUCCEEDED**, only the existing AppIntents metadata warning.

Not run: the app itself, XCUITests, and a real macOS permission prompt.
Next: in the running app, confirm the one-time permission request after sign-in,
and that the switch and a changed text size survive quit and relaunch.

## 2026-09-25 — UI polish batch (hover, title bar, sidebar, paging, Channel Info)

User-reported issues, each fixed and covered:

- **Scrolling to the top loaded page after page.** `captureAnchor()` anchored on
  the older-history gap row, which stays first after a prepend, so the viewport
  stayed at the top and re-triggered paging. It now anchors on the row after the
  gap. New `prependedOlderPageKeepsThePositionAndDoesNotRequestAgain` failed
  before the fix and passes after it.
- **Hover highlighted messages under the composer, the pill and toasts.** A new
  `isPointerOccluded` check hit-tests the window: only a pointer over the table
  itself hovers a row. New test: `overlaysAboveTheTimelineBlockTheHover`. The
  jump-to-latest pill's button now fills the whole capsule.
- **Square hover boxes inside rounded bars.** New `CapsuleHoverButton` (capsule
  hover and press highlight) for the message action bar and the media viewer.
  Snapshot inspected.
- **The profile pill covered the last sidebar row.** A spacer row at the end of
  the list replaces `contentMargins`. `captureFloatingChrome` now scrolls the list
  to the end; inspected.
- **Conversation title at the start of the top bar; controls no longer move.** On
  macOS 26, the title is a `.navigation` item in the detail column with a
  secondary line: presence or member count, archived, and the header as plain
  text rendered by the markup parser. An empty principal item keeps the controls
  trailing. `.primaryAction`/`.automatic` items and `ToolbarSpacer(.flexible)`
  alone packed the controls after the title. The accessory item that appeared and
  disappeared per channel is gone on macOS 26. Verified in full-size-content
  fixture windows. In a window without `.fullSizeContentView`, `.navigation` items
  sit next to the traffic lights; the real app uses full-size content.
- **Channel Info redesign** (subagent): see the entry above for details. Adds
  `InfoPaneComponents.swift` and `ChannelHeaderMarkup.swift`, and fixes an
  existing crash when a bot member row appeared.
- **Notifications on by default and local settings saved** (subagent): see the
  entry above and decision 0032.

Other improvements found while checking:

- **Composer placeholder.** It was never set; it now reads "Message #channel",
  "Message Name", "Reply in thread" or "This channel is read-only".
- **Recent reactions.** The quick reactions and the picker's "Frequently Used"
  row follow the account's recent reactions (`DirectoryStore.recentReactions`,
  kept in the content cache; custom emoji are skipped in the bar).
- **Activity reports are chained** so they reach the server in order. This was
  found as a flaky `UserActivityTests` run under load.

Full `swift test --package-path Packages/MatterMacKit` passed (UI-support 182;
`/tmp/mattermac-batch-tests.log`). The Debug build passed with only the
AppIntents warning (`/tmp/mattermac-batch-build.log`). Not verified in the
packaged app. An uncommitted `DEVELOPMENT_TEAM` edit in `project.pbxproj` comes
from Xcode, not this work.

## 2026-09-25 — release pipeline (nightly and production)

Added `.github/workflows/release.yml` (decision 0033, `docs/releasing.md`):

- nightly runs daily at 02:17 UTC and are skipped when `main` has not changed;
- manual runs choose nightly or production;
- nightly label `1.0.0-nightly.<yyyymmdd>.<run>`, published as a GitHub
  pre-release; the newest 14 are kept;
- production releases `v<MARKETING_VERSION>` as latest, then commits the next
  version to `main`.

Signing, notarization and the DMG moved into the reusable `build-dmg.yml`, which
now also checks the injected Info.plist versions. `sign.yml` calls it for
`-dev.<run>` artifacts. `Tools/ReleaseVersion.swift` computes and bumps versions.
`MARKETING_VERSION` went from 0.1.0 to 1.0.0. Help ▸ About shows
`MatterMacVersionLabel`.

Checked locally:

- `ReleaseVersion.swift` commands, including invalid input;
- the `prepare` step's shell under simulated schedule, production and override
  events, including the skip when a nightly tag points at `HEAD` (temporary tag
  removed afterwards);
- `actionlint` 1.7.12 on all workflows: clean (shellcheck not installed);
- a Debug build with injected versions, checked with `plutil` (1.0.0 / 45 /
  1.0.0-nightly.20260923.45) — the default local build shows `1.0.0-dev`;
- `swift test` passed (`/tmp/mattermac-release-tests.log`).

Not run: the workflows on GitHub. The first nightly or production run is the real
check of runner `swift`, `gh release` permissions and pushing to `main`.

## 2026-09-25 — in-app updates (decision 0034)

Added:

- `MatterMacUpdateSupport`: validation, archive install and relaunch, shared by
  the app and the helper;
- `MatterMacPlatform/Updates`: the GitHub feed, `update.json`, preparation, and
  the XPC client;
- `AppUpdater` with a banner, a Settings ▸ General ▸ Updates section, and
  **Check for Updates…**;
- the embedded unsandboxed XPC service `MatterMacUpdateInstaller`: a new Xcode
  target, embedded via "Embed XPC Services";
- release assets `MatterMac-<label>.zip` and `update.json`.

Tests and checks:

- `UpdateTests` (5): channel selection, drafts, and malformed manifests and feeds;
  checksum, signature and bundle checks; `installArchive` from an open file,
  including cleanup; the updater's states, banner and Later, install, quit,
  up-to-date and failure notices, and the default channel.
- `LocalSettingsPersistenceTests` cover the two new keys.
- The Settings snapshot was inspected.
- Local end to end with Debug builds 100 → 101: a local feed and the real embedded
  service. Findings, in order:
  - The container is unreadable by the helper (EPERM), so the app now passes a
    `FileHandle`.
  - A sandboxed write-access pre-check was wrong and was removed.
  - `NSApp.terminate` called from the task deadlocked `.terminateLater`, so the
    quit is now scheduled on the run loop.
  - Final run: build 101 swapped in with its signature verified, the old process
    exited, and a new process started with the same arguments.
- `swift test` (after the settings-test update) and the Debug and ad-hoc Release
  builds pass (`/tmp/mattermac-update-*.log`).

Not verified: a real GitHub Developer ID and notarized release end to end (needs
two published releases), and macOS 14/15.

## 2026-09-25 — first published nightly

The first Release run (36134978967) built and notarized the DMG, then failed while
writing release notes with exit 141. `git log | head` under `pipefail` gets
SIGPIPE when the history exceeds the limit. Fixed in `b3069bc` with
`git log --max-count` and no piping into `head`. Nightlies are now ordered by build
number, because a date sort picked the wrong tag for commits with the same
timestamp; verified by replaying the step locally. The artifact actions moved to
Node 24 (upload v7.0.1, download v8.0.1).

A clean checkout of the updater commit then failed to build: zero-context hunk
staging had placed the new package-product entries in `project.pbxproj` after the
`objects` dictionary. The commit was amended with the working copy (minus the
user's local `DEVELOPMENT_TEAM` lines) and then built from a fresh worktree (Release
ad-hoc and Debug) before `0e0a2e5` was pushed.

Release run 36138787071 (nightly) succeeded and published pre-release
**MatterMac 1.0.0-nightly.20260925.2** (build 2) with the DMG, its `.sha256`, the
app ZIP and `update.json`. Downloaded and checked on this Mac:

- the manifest's SHA-256 and size match the ZIP;
- Info.plist reads 1.0.0 / 2 / 1.0.0-nightly.20260925.2;
- the app satisfies the updater's requirement (Developer ID team ZJ37A69485,
  notarized);
- `spctl` accepts the app and the DMG as "Notarized Developer ID";
- the stapled ticket validates;
- the embedded `MatterMacUpdateInstaller` has a Developer ID signature, the
  hardened runtime and no sandbox entitlement.

Next: the first real in-app update is from this nightly to the next one; confirm
it on a copy installed in /Applications.

### Transparent title bar after using the media viewer (2026-09-25)

Report: the nightly downloaded from GitHub showed messages sharply behind the
toolbar, with no scroll edge effect, while local builds looked right. The build was
not the cause:

- a fresh copy of the same notarized nightly, a local Release build and
  Release-optimized package fixtures all showed the effect;
- the long-running instance still had a 1007×646 scroll area inset 72 pt from its
  window edges, found by a read-only Accessibility walk. That is the media viewer's
  stage.

`MediaViewerController.close()` removed the overlay in the fade-out completion
through `[weak self]`. `onClose` releases the controller synchronously (the pane
sets `imageViewer = nil`), so the completion found `self == nil`. The transparent
overlay then stayed in the window's frame view for good, still holding its last
image. Its stage `NSScrollView` lies under the title bar, so AppKit attached the
toolbar's `NSScrollPocket` to it instead of the timeline. Fixture dumps showed that
the pocket is a single view that AppKit moves to whichever scroll view is under the
title bar. It moves to `NSTitlebarBackgroundView` while Channel Info, Threads or
Search cover the detail column, and back afterwards.

Fix: the completion now captures the overlay strongly and always removes it and its
images. `mediaViewerCoversTheWindowAndMovesBetweenAMessagesImages` gained a case
where only the pane owns the viewer. That case failed on the old code (overlay still
attached, image retained) and passes now.

- `swift test --package-path Packages/MatterMacKit`: all suites pass.
- Debug `xcodebuild`: succeeds with no warnings.

SakuraCord (studied, not copied) has a SwiftUI timeline with an explicit
`.scrollEdgeEffectStyle(.soft, for: .top)`, so it never meets this AppKit
pocket-ownership case.

Next: publish a nightly with the fix. Until then, relaunching clears the leftover
overlay.

### Liquid Glass app icon (2026-09-25)

- Replaced `AppIcon.appiconset` and `Tools/GenerateAppIcon.swift` with an Icon
  Composer document, `Apps/MatterMac/Resources/AppIcon.icon`: two hand-written SVG
  layers (open ring, Swift-orange drop) on a blue gradient. Provenance is in
  `docs/assets.md`.
- `ictool` rendered the Default, Dark, ClearLight and TintedDark renditions, and
  all four were checked visually.
- The Debug `xcodebuild` succeeds with no warnings. The app bundle has a layered
  `AppIcon` in `Assets.car` and a generated `AppIcon.icns` fallback (checked with
  `sips`), and `CFBundleIconName` is `AppIcon`.

Follow-up the same day: the blue default was replaced at the user's request.

- Production and local builds use `AppIcon.icon`: white glass on Swift's orange-red
  gradient.
- Nightlies use the new `AppIconNightly.icon` (violet on near-black), selected by
  `MATTERMAC_APP_ICON` in `build-dmg.yml`.
- Release builds without signing ran with each icon name; both succeeded with no
  warnings. `CFBundleIconName` matched each name, and each `.icns` fallback was
  checked visually.

Redesign for alignment (user feedback: "it's not aligned"). The ring gap and the drop
now share one axis through the centre, tilted 38°. The drop is symmetric with
straight tangent sides, and its tip lies on the ring's centreline, in the middle of
the gap. Construction values are in `docs/assets.md`. Both icons were rendered with
`ictool` and checked visually (Default, Dark, ClearLight and TintedDark). The Debug
build succeeds with no warnings.
