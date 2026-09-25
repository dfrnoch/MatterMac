# Releasing

MatterMac is distributed as a signed, notarized and stapled DMG attached to a
GitHub release. `.github/workflows/release.yml` publishes both channels. It builds
with the reusable `.github/workflows/build-dmg.yml`, which also backs the manual
**Notarized DMG** test build (`sign.yml`).

## Versions

| Item | Source | Example |
| --- | --- | --- |
| Next production version | `MARKETING_VERSION` in `Apps/MatterMac/Configuration/Shared.xcconfig` | `1.0.0` |
| Build number (`CFBundleVersion`) | the Release workflow's run number | `45` |
| Nightly label | `<version>-nightly.<UTC yyyymmdd>.<build>` | `1.0.0-nightly.20260923.45` |
| Production label and tag | `<version>`, tag `v<version>` | `1.0.0`, `v1.0.0` |

`CFBundleShortVersionString` stays numeric (`1.0.0`), as macOS expects. The full
label is in the Info.plist key `MatterMacVersionLabel`, which Help ▸ About shows
("Version 1.0.0-nightly.20260923.45 (45)"). Local builds show
`<version>-dev` with build number 1. `Tools/ReleaseVersion.swift` reads, computes
and bumps versions; CI runs it with `swift`.

```sh
swift Tools/ReleaseVersion.swift current            # 1.0.0
swift Tools/ReleaseVersion.swift nightly 45 20260923 # 1.0.0-nightly.20260923.45
swift Tools/ReleaseVersion.swift next minor          # 1.1.0
swift Tools/ReleaseVersion.swift set 1.1.0           # rewrites Shared.xcconfig
```

## Nightly

- **Schedule:** 02:17 UTC every day. A scheduled run is skipped when `main` still
  points at the newest nightly tag's commit. **Run workflow** with channel
  `nightly` always builds.
- **Release:** a GitHub pre-release, never marked latest, titled
  `MatterMac <label>`. It carries `MatterMac-<label>.dmg` and its `.sha256`, with
  release notes listing the commits since the previous nightly.
- **Pruning:** only the newest 14 nightly releases are kept; older ones are
  deleted together with their tags.

## Production

1. Make sure `main` is green and `MARKETING_VERSION` is the version to ship.
2. **Actions ▸ Release ▸ Run workflow** with:
   - channel `production`;
   - optionally `version`, to ship a different `MAJOR.MINOR.PATCH`;
   - `next` (patch, minor or major) for the development version afterwards.
3. The workflow fails before building if the tag already exists. It then:
   - builds and notarizes the DMG;
   - creates the release `v<version>` at the built commit, marked latest, with the
     commits since the previous production release as notes;
   - commits `chore(release): start <next> after <version>` to `main` as
     `github-actions[bot]`.

The final push needs `contents: write` for `GITHUB_TOKEN`. If branch protection
requires pull requests, allow GitHub Actions to push, or change `MARKETING_VERSION`
by pull request after the release; the release itself is already published.
Commits pushed with `GITHUB_TOKEN` do not trigger CI.

## In-app updates

Every release also carries the files MatterMac itself updates from (decision 0034):

- **`MatterMac-<label>.zip`:** the notarized, stapled app, packed with `ditto`.
- **`update.json`:** `schema`, `label`, `build`, `channel`, `zip`, `zipSHA256`,
  `zipSize`, `dmg` and `minimumSystemVersion`. The app compares only `build`.

Stable-channel users see production releases; the Nightly channel sees nightlies
and production releases, whichever build is newer.

To exercise updates locally with Debug builds, serve a GitHub-shaped
`releases.json` and pass `-MatterMacUpdateFeed <url>` to the older build. Add
`-MatterMacUpdateAutoInstall YES` to install without clicking the banner.
Debug builds accept updates signed by the team's Apple Development certificate.
Release builds require Developer ID and notarization.

## Signing

The bundle ID is `dev.frnoch.mattermac`. Debug builds use Apple Development
signing. Release builds use David Frnoch's Developer ID (team `ZJ37A69485`).

To build without that certificate, append this ad-hoc override to the
`xcodebuild` command; pull-request CI uses it:

```sh
CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=
```

`build-dmg.yml` does the following:

1. Builds the universal app.
2. Checks the version keys, the embedded update installer's signature, and the
   Developer ID signature.
3. Notarizes and staples the app, then a DMG with an Applications shortcut.
4. Checks that Apple's status is `Accepted` and that Gatekeeper accepts both.

The manual **Notarized DMG** workflow (`sign.yml`) makes the same DMG as a 7-day
artifact without publishing a release.

The move to this bundle ID gave the app a new sandbox container. Content caches
from older builds are not migrated; the server refills them. Keychain service names
are unchanged, but sign-ins created by an older ad-hoc build may not be readable;
sign in again if needed.

## Secrets

The Release workflow passes these repository secrets to the reusable build with
`secrets: inherit`:

- `DEVELOPER_ID_CERTIFICATE_BASE64`: the exported Developer ID identity, as
  base64-encoded PKCS#12.
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`: the PKCS#12 export password.
- `APPLE_ID`: the developer Apple Account email.
- `APPLE_APP_SPECIFIC_PASSWORD`: a dedicated app-specific password for
  notarization.

The workflow validates the notarization credentials, keeps them and the signing
identity in a temporary runner Keychain, and deletes that Keychain afterwards.
Never store the account's normal password in GitHub. See
[GitHub's certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
and [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
