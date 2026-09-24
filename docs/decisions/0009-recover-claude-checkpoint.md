# Recover and integrate the interrupted Claude checkpoint

Date: 2026-09-24

The previous implementation session stopped at its usage limit
before merging six module copies under `/tmp/mmwork/{api,realtime,markup,timeline,composer,xcode}`.
The repository had no commits; all existing files were untracked.

Recover only those modules' owned paths. Keep the newer core and SwiftUI shell in
the repository. Do not copy stale shell files, scratch projects, credentials,
build products, or placeholder core tests over the parent work.

Connect the existing controllers and service protocols directly. One reusable
AppKit conversation controller owns a timeline and composer for each visible
channel/thread; layout caches are shared across sessions. Attachment controls
report that integration is incomplete. No extra package or runtime was added.

The realtime factory now receives the authenticated user ID because the real event
decoder needs it to interpret account-scoped events. Network services expose
explicit shutdown, used after discovery/login and at session teardown.

The recovered transport cancellation test used a typed-throws Task closure that
crashed Swift 6.4 during IR generation. An ordinary `throws` closure preserves the
test and avoids both that crash and the macOS 15 typed-closure runtime requirement.

This is a working development checkpoint, not completion of the specification's
milestone gates. See `../progress.md` for commands, results, and remaining work.
