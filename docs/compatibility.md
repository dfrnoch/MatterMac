# Compatibility

This is an implementation and evidence summary, not a feature-parity promise.
Server permissions, configuration, reverse proxies, and identity providers can
change which paths are available.

## Verified environments

The recorded local development environment uses Xcode 27.0, Apple Swift 6.4, and
macOS 27 on Apple silicon. Release builds contain arm64 and x86_64 slices. The
macOS 14 deployment target and Intel slice have not been execution-tested on that
OS or hardware. Local builds are ad-hoc signed, not Developer ID signed or notarized.

| Mattermost deployment | Evidence |
| --- | --- |
| 11.11.1 at origin root | Live REST/WebSocket peer and native conversation/attachment checks. |
| 11.11.1 at `/company/chat` | Same checks with URL-subpath preservation. |
| 10.11.24 at origin root | Same checks on the 10.11 release line. |

Live REST/WebSocket checks exercise bidirectional channel and DM messages, edits,
reactions, and deletions. Native SwiftUI/AppKit checks exercise login, draft
navigation, sending, edits, replies, DMs, selected-file/pasted-image upload,
download, and thumbnail display. Both peers are native clients; communication
with an official web or desktop client remains an unverified release gate.
Exact commands and dated outcomes are in [progress.md](progress.md).

## Authentication and endpoint coverage

All REST paths below are relative to the configured server's `/api/v4` prefix,
including any reverse-proxy subpath. This groups implemented routes; it does not
claim that every endpoint has a live test on every server configuration.

| Area | Implemented routes or behavior | Limits |
| --- | --- | --- |
| Discovery | `GET /system/ping`, `GET /config/client?format=old` | Missing capabilities stay unknown; no TLS bypass. |
| Password/PAT | `POST /users/login`, `GET /users/me`, `POST /users/logout` | Login methods and MFA depend on server policy; PATs are not remotely revoked by local sign-out. |
| Browser SSO | Server-advertised OpenID, SAML, Google, Microsoft or GitLab route; `POST /users/login/desktop_token`; identity verification | Uses system authentication presentation and a scoped callback. A local browser fixture passes; broad IdP interoperability is not verified. |
| Saved sign-ins | Keychain bearer credentials, `/users/me` revalidation | Expired or mismatched identities are removed; temporary connection failures retain the saved entry for retry. |
| Teams/channels | Own teams and memberships, channel metadata/membership/stats, DM creation, join/leave, channel search and view state | Available actions remain subject to server permissions; broader permission UI is incomplete. |
| Posts/threads | Channel pages, unread anchors, post/thread retrieval, create/patch/delete, batched retrieval | Basic threads implemented; not full collapsed-thread workflow parity. |
| Reactions/search | Add/remove reactions; team post search | Emoji completion and advanced search UI remain incomplete. |
| Users | Batched users/statuses, autocomplete, profile images | Bounded results; not a full administrative directory. |
| Files/images | `/files`, file/info/thumbnail/preview retrieval, image requests | Explicit uploads/downloads and bounded in-memory previews. Uploaded-but-unposted files can remain on the server. |
| Realtime | `/websocket`, authentication, event reconciliation and reconnect | Unknown send outcomes remain visible; no exactly-once delivery guarantee. |

SSO success depends on the server's advertised route and desktop-token support,
not just the provider brand. Custom provider labels are preserved. A deployment
check does not establish support for every configuration of that identity provider.

## Unsupported and unfinished

Calls, screen sharing, arbitrary web plugins, Boards, Playbooks dashboards,
enterprise administration, and custom theme CSS are outside native v1 scope.
There are no durable offline drafts or notifications after the app quits.

The compatibility panel, emoji completion, and broader permission controls still
need UI integration. VoiceOver and real IME coverage, minimum-OS execution, full
privacy/filesystem audits, and performance acceptance measurements are incomplete.
Existing SwiftUI sidebar reentrancy and AppIntents metadata-extraction warnings
are recorded in the progress log; neither is claimed resolved here.
