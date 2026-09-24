# 0021 — Teammate names, opt-in notifications and UI-test account isolation

Date: 2026-09-25. Status: implemented.

**Names.** Display names now resolve like the official client: a licensed, locked
`TeammateNameDisplay` wins, then the user's `display_settings/name_format`
preference, then the server's `TeammateNameDisplay` default. Before this change the
server default was ignored, so deployments configured for full names showed
usernames everywhere. DM rows in the sidebar show the partner's picture and presence.

**Notifications.** SPEC §19 allows in-app badges and, after explicit opt-in,
Notification Center. Core publishes a bounded (newest 8) stream of content-free
alerts for mentions and direct/group messages from others: sender and conversation
name, never message text. Alerts are suppressed during Do Not Disturb, for muted
DMs, and for the conversation that is visible in the active app. An unknown sender
is resolved with one `POST /users/ids` before alerting. The opt-in and sound setting
are in memory only and reset on quit. Authorization is requested only when the user
enables notifications. Notification user info holds only the slot, account and
channel identifiers needed to open the conversation. Sign-out withdraws that
account's delivered notifications (up to 64 tracked per account). The Dock badge
shows the unread mention count across connected sessions.

**UI tests.** XCUITest launches the real app, which shares the bundle ID and signing
with developer builds, so it restored the developer's saved Keychain sign-ins. The
first-launch tests therefore failed, and they connected to a real server. The
Debug-only `-MatterMacUITesting YES` argument now disables the account store
entirely. Every UI test passes it. The opt-in live member-list UI test signs in to
the local fixture only.
