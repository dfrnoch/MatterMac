# AGENTS.md — working rules for MatterMac

MatterMac is a native macOS client for **existing** Mattermost servers. `SPEC.md` is
the implementation specification; read it before structural changes. This file lists
durable rules and commands that have actually been run in this repository.

## Hard rules (from SPEC.md §2, §7 — do not relax)

- All app-owned runtime code and tests are **Swift**. No Electron, WKWebView, JS,
  Rust/Go helpers, or non-Swift runtime hidden behind a Swift wrapper. Zero external
  runtime dependencies.
- **Persistence:** no database, `URLCache`, cookies,
  `UserDefaults`/`@AppStorage`/`@SceneStorage` user state, window restoration, or
  automatic logs. App-controlled persistence is: explicit downloads/exports, saved
  sign-ins in macOS Keychain (user request 2026-09-24: verified bearer token, kind,
  canonical endpoint and user ID; never passwords), and the on-device
  `ContentCache` (user request 2026-09-25: images, profiles, directory, last open
  channel, recent channels' latest posts). The cache is AES-GCM encrypted with a
  per-account Keychain key, bounded by `ResourceBudget.diskCache`, never holds
  drafts or pending sends, and cached windows never mark channels read. Quit keeps
  sign-ins and cache; Sign Out deletes both for that account. See SPEC §7 and
  decision 0031. The Settings "On This Mac" values (`LocalSettings`: notifications,
  previews, sound, Dock bounce, send behavior, text size, appearance) are saved in
  `UserDefaults.standard` under `MatterMac.*` keys (user request 2026-09-25, decision
  0032): typed, validated on load, injected via `AppEnvironment(settingsStorage:)`;
  tests and `-MatterMacUITesting` keep them in memory. Drafts stay session-only.
  Notifications and message previews are on by default; authorization is asked at
  most once per launch, after a sign-in, only while macOS reports `.notDetermined`.
- Networking: `URLSessionConfiguration.ephemeral` with `urlCache = nil`,
  `httpCookieStorage = nil`, `httpShouldSetCookies = false`,
  `urlCredentialStorage = nil`. Never `URLSession.shared`. Bearer header only; never
  tokens in URLs. Credentials never follow a cross-origin redirect.
- Every buffer, cache, queue, window, and task set is bounded by
  `MatterMacModels.ResourceBudget`. Unsent text (drafts + pending sends) is never
  evicted — refuse new input instead.
- Never log or display message text, tokens, filenames, search terms, or server error
  bodies. Diagnostics go only to `DiagnosticRing` (StaticString + numeric codes).
- No fake success. Unsupported features (SSO, Calls, plugins) are labeled honestly.
- Do not claim macOS execution, server interoperability, notarization, or benchmark
  numbers unless actually run; record evidence in `docs/progress.md`.

## Toolchain facts (verified 2026-09-24)

- Xcode 27.0 (27A266a), Apple Swift 6.4, MacOSX27.0 SDK, host macOS 27.0 on Apple M1 Pro.
- Deployment target **macOS 14.0**. Swift 6 language mode (complete strict concurrency).
- Package upcoming features: `ExistentialAny`, `InternalImportsByDefault` (write
  `any P`; use `public import X` only when a public declaration exposes X).
- `NonisolatedNonsendingByDefault` is **off** in the package: nonisolated `async`
  functions run off the caller's actor (verified by test). CPU-heavy entry points are
  still marked `@concurrent`. `MatterMacUI` uses `.defaultIsolation(MainActor.self)`.
- **Typed-throws function *types*** (stored closures `() throws(E) -> T`) require the
  macOS 15 runtime — do not store typed-throws closures; typed-throws *methods* are fine.
- Swift Testing `#expect(...)` cannot wrap a mutating call; assign to a local first.
- Optional-chained assignment that reads the same storage on the right-hand side
  (`dict[k]?.x = dict[k]?.x`) is an exclusivity violation at runtime.
- `OSAllocatedUnfairLock` (macOS 13+) for small shared state; `Synchronization.Mutex`
  is macOS 15+ only. Its `withLock` closure is untyped-throws: return a `Result`.
- Forbidden: `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, warning
  suppression.

## Layout

- `Packages/MatterMacKit` — targets `MatterMacModels` ← `MattermostAPI` ←
  `MattermostRealtime`; `MatterMacCore` (sessions, stores, budgets, reconciliation);
  `MatterMacPlatform` (AppKit adapters); `MatterMacUI` (SwiftUI shell, AppKit
  timeline/composer); `TestSupport` (test-only fakes, never linked into the app).
- `Apps/MatterMac` — app target (composition root only). `MatterMac.xcworkspace` at root.
- `Tests/Integration/Server` — development-only Docker Mattermost deployments.
- `docs/` — architecture, compatibility, asset provenance, decisions,
  **progress.md** (update every session), and protocol/platform research notes.
  Repository security and reporting guidance is in root `SECURITY.md`.

## Commands (verified)

```sh
# Package build and unit tests (from repo root)
swift build --package-path Packages/MatterMacKit
swift test  --package-path Packages/MatterMacKit                 # all package tests
swift test  --package-path Packages/MatterMacKit --filter CoreTests

# Local test servers (Docker/OrbStack; amd64 images under Rosetta)
docker compose -f Tests/Integration/Server/compose.yaml --profile esr --profile subpath up -d
Tests/Integration/Server/bootstrap.sh mm11 mm11sub mm10     # users alice/bob/carol, team qa
#   v11.11.1: http://localhost:8065   subpath: http://localhost:8066/company/chat   v10.11.24: http://localhost:8067
#   generated passwords: .local/test-server.env (git-ignored, mode 600) — never print or commit
```

Live tests are opt-in: `set -a; . ./.local/test-server.env; set +a; MM_LIVE_TESTS=1 swift test ...`.
Never pass live credentials on the command line or commit them.

## Working agreements

- Use Conventional Commits for every new commit: `type(scope): short imperative summary`
  (omit the scope when it adds nothing). Examples: `feat(sso): restore saved sign-ins`,
  `fix(composer): bound undo growth`, `docs: clarify local setup`.
- Compile and run focused tests after meaningful changes; keep zero warnings.
- Record significant tradeoffs in `docs/decisions/NNNN-title.md`.
- Update `docs/progress.md` with commands, outcomes, measurements, defects, and the
  next concrete task at each session boundary.
- Preserve unrelated user work; do not reset or delete it.

## Recovered app commands (verified 2026-09-24)

```sh
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac -configuration Debug -derivedDataPath build build
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac -configuration Release -derivedDataPath build build
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMacUITests -configuration Debug -derivedDataPath build test
```

The recovered app has a two-step URL flow: Continue normalizes the address, then
Connect probes it. Debug-only `-MatterMacAllowInsecureLoopback YES` permits the
local test servers. Live protocol coverage lives in `LiveMessagingTests` and
requires `MM_LIVE_TESTS=1` plus the environment file above. Both peers in that test
are native API clients, not an official web-client interoperability demonstration.
Use an exact `.app` path when testing reopen: recovered copies share the bundle ID.
