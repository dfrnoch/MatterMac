# 0011 — Scoped system-browser desktop SSO

2026-09-24. Implement Mattermost's desktop-token handoff in
`ASWebAuthenticationSession`, with the ephemeral-browser preference. The requested
10.11 server cannot provide the newer public-client OAuth + PKCE flow; no client
secret, OAuth registration, embedded browser, or mobile bearer-in-URL flow is added.

Discover the enabled OpenID, SAML, Google, Office365 and GitLab routes. Preserve
bounded custom provider labels: a Keycloak deployment may expose its integration
through the GitLab route, so inferring the route from the identity product is wrong.

The system session listens for `mattermost:` only while handling this initiated
login. MatterMac does **not** register that scheme in Info.plist or Launch Services,
and cannot receive another application's ordinary URL opens. This is a scoped
callback contract, not ownership of Mattermost's scheme (SPEC §8). Apple documents
session-specific routing even when another app registers the same callback scheme.
The local macOS test captures the JavaScript callback with Mattermost Desktop
installed; it does not prove all browser/OS/IdP combinations.

Bind the callback to a cryptographically random 256-bit client nonce, exact server
host/port/base path, and a three-minute deadline; enforce an 8 KiB callback bound,
unique/allowlisted parameters and single consumption. One browser attempt may be
active globally. Exchange the short-lived server code exactly once over the normal
ephemeral transport, refusing even same-origin redirects on that POST. Ignore
response cookies and extra user fields, then verify the bearer with `/users/me`.
Cancellation and rejected admission revoke a returned session on a best-effort
basis; an ambiguous exchange whose response is lost cannot be revoked locally.
Passwords, tokens, browser URLs, callback codes and IdP error bodies are not logged.

The server contract is version-dependent and not a supported third-party OAuth API.
The login UI cautions that organization configurations require verification. The
user confirmed successful Keycloak completion on their 10.11.9 deployment through
the custom GitLab route. Minimum macOS 14 and other browser/provider combinations
remain test gates. Browser/OS/IdP storage is outside app-owned session-only state.

Evidence and rerun commands are in `docs/progress.md`. Sources:

- [Apple ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/)
- [Mattermost 10.11.9 OAuth handoff](https://github.com/mattermost/mattermost/blob/v10.11.9/server/channels/web/oauth.go)
- [Mattermost 10.11.9 desktop callback](https://github.com/mattermost/mattermost/blob/v10.11.9/webapp/channels/src/components/desktop_auth_token.tsx)
- [Repository source research](../research/auth.md#7-browser-and-sso-options-for-a-third-party-native-client)
