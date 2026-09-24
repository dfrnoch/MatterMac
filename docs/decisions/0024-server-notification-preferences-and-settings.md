# 0024 — Server notification preferences, in-app attention and a Settings window

Date: 2026-09-25. Status: implemented.

**Which posts notify.** Core now applies the account's `notify_props` and each
channel member's `notify_props`, following the official web client's desktop rules
(`actions/notification_actions`). Before this, every mention and direct message
alerted, including mentions in muted channels, and channel levels were ignored.
`NotificationPolicy` is a pure function with its own tests:

- Muted channels (`mark_unread = mention`) never notify, including mentions. This
  matches the official client and the server's push rule.
- A channel `desktop` other than `default` wins. `default` resolves to the account
  level. A group message whose channel is `default` notifies for every message even
  when the account level is "mentions" (official behavior). `none` silences
  everything, including direct messages.
- A mention is the server-computed `mentions` list, or a client-side,
  case-insensitive, whole-word match of `@username`, `mention_keys`, the first name
  when `first_name = true`, and @channel/@all/@here. The official client matches
  the first name case-sensitively; this matcher does not. Channel-wide mentions
  count when the account's `channel` is on and the channel's
  `ignore_channel_mentions` is not `on`. As on the server, `off` does not override
  the account setting.
- With collapsed reply threads, a reply in a channel notifies only when it mentions
  the user. A reply in a direct or group message notifies like any message there.
  MatterMac does not track followed threads or `desktop_threads`; that is a
  documented simplification.

**Keeping the account's properties intact.** `PUT /users/{id}/patch` replaces the
entire `notify_props` map. MatterMac therefore keeps the signed-in user's map
verbatim: at most 48 keys, each value at most 4 KB. It writes back the complete map
with only the edited keys changed. If decoding dropped anything, the map is marked
incomplete and can't be edited, so a truncated copy can never delete server data. A
sanitized `user_updated` copy without properties keeps the known ones. Channel
changes send only the keys that differ; the server merges them. A live test checks
this on all three local deployments and restores every value. Every setting shown
under "Server Settings" is an explicit server change. It is saved immediately
(Settings) or with Save (the channel sheet), and each screen says that the
official apps use the same value.

**Message previews.** Alerts carry no message text by default (SPEC §19). A separate
opt-in, "Show message preview", can be turned on only while Notification Center is
enabled. When on, Core adds up to 100 characters of whitespace-collapsed
`MessageDocument.plainText` to the alert, and the UI drops it again if the setting
changes in between. Both switches live in memory and reset on quit. The disclosure
next to them says that macOS may keep delivered notifications.

**In-app attention.** Following SPEC's strict-mode default of "in-app badges and
optional in-app sounds", MatterMac plays the selected `/System/Library/Sounds`
sound itself, with or without Notification Center. At most one sound plays per
0.9 s, and only one `NSSound` is retained. Notification Center banners are posted
silently so a sound never plays twice. The in-app sound respects the account's
server `desktop_sound` and Mattermost Do Not Disturb, but not macOS Focus, which
only filters Notification Center. While the app is inactive, mentions and direct
messages also request one informational Dock bounce. "Play sound" and "Bounce Dock
icon" default to on, like the official desktop app. Both are in memory only.

**Settings window.** The app adds a SwiftUI `Settings` scene with General,
Notifications, Appearance and Accounts tabs:

- Each tab keeps local settings ("On This Mac: kept in memory only; reset when
  MatterMac quits") separate from the active account's "Server Settings".
- Server sections are bound to the active session and show "Sign in to change
  server settings." without one.
- Local settings live in `LocalSettings`, owned by `AppEnvironment`: send key, text
  size (timeline font scale), light/dark override (`NSApp.appearance`), sound,
  preview and bounce.
- Server settings cover the account's desktop level, sound, keywords, and first-name
  and channel-wide triggers. They also cover the `display_settings` values
  `use_military_time`, `name_format` (disabled when locked) and
  `collapsed_reply_threads`. The last is editable only for `default_on`/
  `default_off`, and changing it drops channel windows and reloads the visible one.
- An unset clock preference keeps following the Mac's format, while the official
  client defaults to 12-hour. Compact density is not offered because the AppKit
  timeline has no compact layout yet.

The first XCUITest run showed that SwiftUI's Settings `TabView` saved the selected
tab to UserDefaults (`com_apple_SwiftUI_Settings_selectedTabIndex`). The view now
binds an explicit in-memory selection, and a rerun wrote no such key. The Settings
scene also opts out of restoration.

**Channel sheet.** "Notification Preferences…" opens from the channel info pane and
the sidebar row menu. It is an AppKit sheet hosting SwiftUI and attached to the key
window, so neither view needs presentation state.
