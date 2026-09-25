# 0015 — Persist verified sign-ins in macOS Keychain

> Superseded in part by [0031](0031-on-device-content-cache.md) (2026-09-25): sign-ins are no longer the only application persistence; the encrypted content cache is the other.

Date: 2026-09-24. Status: accepted at the user's explicit request.

The user reported that relaunch required login and requested account details in
Keychain. This overrides the original session-only rule for account credentials;
message content, drafts, images, navigation and preferences remain memory-only.

Use Security.framework's generic-password item in the local login Keychain. A
single versioned value holds canonical server endpoints, expected user IDs, bearer
tokens and their session/PAT kind. Account count is bounded by connectedSessions
(default three); encoded data is bounded to 32 KiB by ResourceBudget. The fixed
service/account query never enumerates unrelated items. Default macOS access
control applies; synchronizable is false. No passwords, cookies, plaintext index,
Keychain access-group sharing or external dependency is introduced. Development
HTTP loopback launches use a separate item from production HTTPS accounts.

All authentication methods converge on the verified-login path before saving.
Startup discovers each saved endpoint and checks `/users/me` against its expected
account. Invalid/expired credentials and identity mismatches are removed without
sending logout under an unexpected identity. Transient failures keep the sign-in
and offer retry. Keychain failures are reported without exposing error bodies or
credentials. Explicit Sign Out must delete the local saved account before cleanup;
it does not claim success if Keychain deletion fails. PATs are only discarded
locally. Quit closes requests, sockets and stores without revoking server sessions.

Use the standard macOS login Keychain rather than opting into the data-protection
Keychain, which has different entitlement/signing requirements. macOS may request
Keychain access when the application signature changes; we do not relax item ACLs
to avoid system prompts. Developer ID signing and notarization remain outstanding.
See Apple's [macOS Keychain guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
and [SecItem update/delete documentation](https://developer.apple.com/documentation/security/updating-and-deleting-keychain-items).

Checks use synthetic credentials and unique test services, never the user's saved
accounts. They cover save/quit/restore/sign-out, session versus PAT handling,
identity mismatch, expiry, offline retry, runtime authentication loss, bounded
account replacement/removal and persistence across two processes. An isolated
ad-hoc signed sandboxed probe compiled the actual KeychainAccounts source and used
the app's unchanged sandbox entitlements to write, exit, read and remove a fixture.
The user's app and production Keycloak session were not restarted or inspected.
Existing builds saved nothing, so the user must sign in once in the updated build.
