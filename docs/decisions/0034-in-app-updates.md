# 0034 — In-app updates without Sparkle

Date: 2026-09-25. Status: accepted at the user's request ("add auto update to the
app").

## Constraints

- Zero external dependencies, so no Sparkle.
- The app is sandboxed. A sandboxed process cannot replace its own bundle in
  `/Applications`.
- Other processes cannot read the app's container either; this was observed while
  testing (see below).

## Design

- **Feed.** Every GitHub release carries `update.json` and a ZIP of the notarized,
  stapled app (`release.yml`, `build-dmg.yml`). `GitHubUpdateFeed` lists the
  public releases through the unauthenticated API. It skips drafts (and
  prerelease builds on Stable), then picks the highest `build` above the running
  `CFBundleVersion`. Manifests are bounded and their file names and digests
  validated.
- **Preparation, in the sandboxed app.**
  - The ZIP is downloaded into the container Caches through an ephemeral,
    cache-free `URLSession`, bounded by the manifest size and 400 MiB.
  - Its SHA-256 is checked, and it is unpacked with `ditto`.
  - `UpdateSupport.validate` checks the unpacked app: bundle `dev.frnoch.mattermac`,
    a newer build, the minimum macOS, and the requirement "Developer ID of team
    ZJ37A69485, notarized".
  - Only then does the "Restart to Update" banner appear.
- **Installation, in the XPC service `MatterMacUpdateInstaller`.** The service is
  embedded, not sandboxed, and uses the hardened runtime. It:
  - accepts only connections from code satisfying the MatterMac team requirement;
  - receives the ZIP as an open `FileHandle`, because it cannot read the container;
  - copies the archive (bounded), re-checks the SHA-256, unpacks it, and repeats
    the validation;
  - verifies that the installed copy is the team's MatterMac;
  - swaps the bundle with `FileManager.replaceItemAt`;
  - spawns a detached `/bin/sh` that waits for the app's PID to exit, then runs
    `open -n` with the same arguments.
  
  The app then quits normally, which confirms unsent work.
- **Fallback.** A translocated or disk-image copy, or a failed install, shows the
  reason and offers the release's DMG in the browser.
- **Settings.** Automatic checks (default on) and the channel (default: Nightly
  for nightly builds, else Stable) are saved `LocalSettings`. Development `-dev`
  builds and UI tests have no updater unless `-MatterMacUpdateFeed` is given.

Shared checks live in the dependency-free `MatterMacUpdateSupport` target, linked
by both the app and the service, so the two cannot drift apart.

## Verified (2026-09-25)

These were tested on this Mac with two Debug builds (100 → 101), a local feed and
the real embedded service:

- download, checksum, unpacking and signature checks work inside the sandbox;
- the service runs unsandboxed (`sandbox_check` = 0);
- passing a path into the container failed with EPERM, so the design passes a
  `FileHandle` instead;
- a first version called `NSApp.terminate` from the task and deadlocked; quitting
  is now scheduled with `perform(_:with:afterDelay:)`;
- the final run swapped in build 101, and the old process exited and the new one
  started with the same arguments.

Not verified: a Developer ID, notarized release end to end from GitHub (needs
two published releases), apps owned by another user, and macOS 14/15.
