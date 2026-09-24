# Security policy

MatterMac is a development project. There is no supported stable release line or
security response-time commitment yet, and no independent security audit has
been completed. Fixes currently target the latest development revision.

## Reporting a vulnerability

Use GitHub's [private vulnerability report form](https://github.com/dfrnoch/MatterMac/security/advisories/new).
Private vulnerability reporting is enabled for this repository. If you cannot
access the form, open a public issue asking for help reaching a private reporting
route, without vulnerability details or an exploit. Do not assume an ordinary
GitHub issue is private.

In a private report, include the affected commit, macOS version, a synthetic
reproduction, expected and observed behavior, and impact. Never send passwords,
bearer tokens, Keychain exports, private messages, or a live account. Redact server
addresses and identifiers unless a synthetic example cannot reproduce the issue.

## Security boundaries

MatterMac connects directly to an existing Mattermost server. It does not host a
backend, relax server permissions, or provide end-to-end encryption. The server
and identity provider retain authority over accounts, sessions, and content.

Verified bearer credentials and account identifiers are saved locally in macOS
Keychain; passwords are not saved. Saved identity is revalidated on launch. Quit
preserves sign-ins; explicit Sign Out removes the saved entry. A personal access
token remains valid on the server until revoked there. Server-session logout can
fail during an outage, so local sign-out is not proof of remote revocation.

Application-managed conversation content remains in bounded memory except for
explicit user copies, downloads, and exports. This is not a guarantee against OS
swap, system diagnostics, browser storage, clipboard managers, or forensic traces.
API networking is ephemeral, with no shared cookies or URL cache, and credentials
must never follow a cross-origin redirect.

Current limits and verification evidence are in
[compatibility](docs/compatibility.md) and [progress](docs/progress.md). Developer
ID signing, notarization, a full filesystem audit, and minimum-OS execution remain
unverified. Do not publish sensitive production data to demonstrate those gaps.
