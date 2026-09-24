# Contributing to MatterMac

MatterMac is under active development. Keep changes focused and describe the
problem, resulting behavior, and checks actually run. The [specification](SPEC.md)
contains implementation targets; the [progress record](docs/progress.md) records
completed checks and remaining gaps. Follow [AGENTS.md](AGENTS.md) for repository
rules and verified toolchain details.

## Build and test

Use Xcode 27.0 / Apple Swift 6.4, the currently verified local toolchain. The
Swift package declares tools version 6.2; older toolchains have not been verified.
From the repository root:

```sh
swift build --package-path Packages/MatterMacKit
swift test --package-path Packages/MatterMacKit
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac \
  -configuration Release -derivedDataPath build build
```

Run focused tests while changing code, then the full package suite before review.
The GitHub Actions workflow uses the `xcode-27` preview runner and records the
actual toolchain before package tests and a universal Release build. The first
hosted run is pending; local results do not establish that CI has passed.
Keychain tests are opt-in and use synthetic credentials in isolated test items:

```sh
MM_KEYCHAIN_TESTS=1 swift test --package-path Packages/MatterMacKit \
  --filter KeychainSignInTests
```

Native package integration checks are distinct from the app's XCUITest scheme.
XCUITests launch an application with the production bundle ID, so run them only
in a separate test login/session with no real MatterMac session to disrupt:

```sh
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMacUITests \
  -configuration Debug -derivedDataPath build test
```

## Local Mattermost servers

The development-only Docker Compose setup publishes loopback ports. It uses
amd64 Mattermost images; the recorded Apple silicon runs used OrbStack/Rosetta.
These fixtures include development credentials and are not a production template.

```sh
docker compose -f Tests/Integration/Server/compose.yaml \
  --profile esr --profile subpath up -d
Tests/Integration/Server/bootstrap.sh mm11 mm11sub mm10
```

This creates test users and writes generated passwords to the ignored
`.local/test-server.env`. Do not print, attach, or commit that file. Run live
checks against these fixtures only:

```sh
set -a
. ./.local/test-server.env
set +a
MM_LIVE_TESTS=1 swift test --package-path Packages/MatterMacKit \
  --filter 'LiveMessagingTests|LiveConversationTests'
```

The fixtures cover ports 8065 (11.11.1), 8066 (11.11.1 at `/company/chat`), and
8067 (10.11.24). Stop them when finished with
`docker compose -f Tests/Integration/Server/compose.yaml --profile esr --profile subpath stop`.

## Before opening a pull request

- Keep runtime code and tests in Swift, using Apple frameworks and no external
  runtime dependencies. Preserve strict concurrency checking without suppression.
- Keep account scopes, cancellation, stale-result checks, and `ResourceBudget`
  limits intact. Refuse new unsent work at capacity; do not evict existing drafts.
- Use ephemeral networking and bearer headers. Do not introduce disk caches,
  automatic logs, cookies, persisted content, or password storage. Keychain
  verified sign-ins and explicit user exports/downloads are the persistence exceptions.
- Add a regression check for meaningful behavior changes. Report skipped checks,
  unsupported capabilities, and observed warnings honestly.
- Update `docs/progress.md` with reproducible commands and results. Record
  significant tradeoffs in `docs/decisions/`; use portable paths and synthetic data.
- Inspect the diff for credentials, private deployment names, account details,
  user content, build outputs, and personal workstation paths before publishing.

For ordinary bugs, use a minimal synthetic reproduction and include the commit,
macOS/Xcode version, and server version when relevant. For vulnerabilities, follow
[SECURITY.md](SECURITY.md) instead of publishing sensitive details in an issue.
