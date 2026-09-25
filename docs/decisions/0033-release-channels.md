# 0033 — Nightly and production release channels

Date: 2026-09-25. Status: accepted at the user's request ("add a release pipeline
that will bump versions and create a github release with the dmg, Nightly and
production. nightly version should look like this: Mattermac
1.0.0-nightly.20260923.45").

- `MARKETING_VERSION` in `Shared.xcconfig` is the next production version and
  the only version in the repository. It was set to `1.0.0` to match the
  requested example; it was 0.1.0.
- Nightly labels are SemVer pre-releases of that version:
  `<version>-nightly.<UTC date>.<build>`. They sort before the production
  release they lead to.
- The build number is the Release workflow's run number. It is monotonic across
  both channels without committing it. `CFBundleShortVersionString` stays numeric
  because macOS and update tools expect `MAJOR.MINOR.PATCH`. The label lives in
  `MatterMacVersionLabel` and in the DMG, release and volume names.
- Only production releases commit to `main`. They release the current version,
  then bump to the chosen next version, so each release's tag points at the
  commit that was built. Nightlies do not create commits.
- Signing, notarization and DMG creation moved from `sign.yml` into the reusable
  `build-dmg.yml`, so the release channels and the manual test build cannot drift
  apart. The added checks confirm that the built Info.plist carries the injected
  versions.
- The versioning tool is Swift (`Tools/ReleaseVersion.swift`), like the other
  development tools. Workflow shell is limited to glue.
