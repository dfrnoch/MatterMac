# Architecture

MatterMac is a native macOS application backed by one local Swift package. The app
connects directly to existing Mattermost REST and WebSocket APIs. There is no
MatterMac backend or embedded browser interface, and no external runtime dependency.

## Module ownership

| Module | Responsibility |
| --- | --- |
| `MatterMacModels` | Validated identifiers and endpoints, domain values, capabilities, diagnostics, resource budgets. |
| `MattermostAPI` | Ephemeral HTTP transport, request admission and bounds, authentication, DTO decoding, explicit file transfers. |
| `MattermostRealtime` | WebSocket lifecycle, ordered events, liveness and reconnect. |
| `MatterMacCore` | Sessions, scoped stores, bounded history, drafts, send reconciliation, unsent-work accounting, images. |
| `MatterMacPlatform` | System authentication presentation and native Keychain storage. |
| `MatterMacUI` | Main-actor SwiftUI shell, AppKit timeline/composer, view models and user interaction. |
| `Apps/MatterMac` | Composition root, scenes, menus and application lifecycle. |
| `TestSupport` | Test-only fakes and fixtures; never linked into the app. |

Dependencies flow from Models through API/Realtime into Core; Platform depends on
Models/Core, and UI depends on Models/Core/Platform. The app composes concrete
services. `Package.swift` defines the exact dependency graph.

## State and lifetime

`AppModel` coordinates login and a bounded `SessionRegistry`. Each `ServerSession`
actor owns one server/account scope and its transport lifetime. Core stores hold
normalized data and expose bounded presentation snapshots. Epoch and generation
checks reject late results after navigation, cancellation, or authentication loss.
The UI uses main-actor observable models; networking, parsing, and image decoding
run off the main actor.

`ResourceBudget` centralizes ceilings. `UnsentWorkLedger` accounts for drafts,
pending sends, and pasted-image ownership across sessions. New unsent work is
refused when full; existing work is not evicted. Network failures preserve the
difference between a confirmed message, failed send, and unknown outcome.

Automatic application-managed persistence has two parts. `KeychainAccounts`
stores endpoint, user ID, bearer credential and kind in the local Keychain.
Startup checks `/users/me` against the saved identity. `ContentCache` (decision
0031) keeps these for fast launch, in the app's Caches directory:

- compressed image bytes;
- a directory snapshot, with the last open team and channel;
- the latest posts of recently opened channels.

It is AES-GCM encrypted under a per-account key held by `KeychainCacheKeys`, and
bounded by `ResourceBudget.diskCache`. `ImagePipeline` reads it before the network.
`ServerSession` restores the directory before its first request, and seeds empty
channel windows (`isCached`) until the server's page replaces them. Quit writes the
cache and preserves sign-ins. Sign Out removes both for that account. The "On This Mac" `LocalSettings` are
saved in `UserDefaults` through the injected `LocalSettingsStorage` (decision
0032). Drafts, pending sends and search stay in memory. Explicit exports and
downloads have separate user-selected destinations.

See [SPEC.md](../SPEC.md) for requirements, [decisions](decisions/) for significant
tradeoffs, [compatibility](compatibility.md) for implemented protocol scope, and
[progress](progress.md) for execution evidence. Requirements are not proof that a
release gate has been satisfied.

## Toolchain and UI details

The Swift package and app use Swift 6 strict concurrency. Nonisolated async methods
run off the caller's actor; CPU entry points also use `@concurrent`. The UI target
uses main-actor default isolation. TextKit 1 owns the plain-text composer explicitly,
and input-method composition is handled before send shortcuts. Undo/redo applies a
complete native group synchronously and rolls it back if the resulting draft cannot
fit the shared admission budget; intermediate edits are not published to the store.

Debug builds use the host architecture; Release builds produce both arm64 and
x86_64. The bundle ID is `dev.frnoch.mattermac`, using team `ZJ37A69485`: Apple
Development for Debug and Developer ID Application for Release. CI tests override
the identity to ad-hoc; the manual signing workflow imports the Developer ID from
GitHub secrets into a temporary Keychain. The three sandbox entitlements are outgoing
network, user-selected file access, and App Sandbox. Release does not inject
`get-task-allow`. The manual release workflow notarizes and staples both the app
and its signed DMG and verifies Gatekeeper acceptance. No updater is configured. Existing Keychain
service names are retained; changing the bundle ID creates a new sandbox container.
Asset source and reproduction are documented in [assets.md](assets.md).
