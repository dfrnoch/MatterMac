# 0032 — Saved local settings and notifications on by default

Date: 2026-09-25

## Context

The "On This Mac" settings (`LocalSettings`) lived in memory only, so every
relaunch turned Notification Center alerts off again and reset sound, text size,
appearance and send behavior. On 2026-09-25 the user asked for notifications to be
enabled automatically, with message previews on by default, and reported that the
setting did not survive reopening the app. SPEC §2/§7/§19 had required
session-only local settings, notifications off by default, and no permission
request at launch; the user explicitly overrode those rules for these settings.

## Decision

- **Saved settings:** `LocalSettings` reads and writes through an injected
  `LocalSettingsStorage` (`object(forKey:)`/`set(_:forKey:)`; `UserDefaults`
  conforms). `AppComposition` passes `UserDefaults.standard`; the keys are
  `MatterMac.notificationsEnabled`, `.showMessagePreview`, `.playSound`,
  `.soundName`, `.bounceDockIcon`, `.sendBehavior`, `.textSize`, `.appearance`.
  Values are `Bool` or short known strings. On load a wrong type, unknown enum
  value or unknown sound name falls back to the default, and loading writes
  nothing. A saved appearance is applied at launch.
- **Hermetic tests:** with no storage (package tests, `-MatterMacUITesting`)
  settings stay in memory. UI testing also starts with notifications off in
  memory so a test never prompts for permission or posts to the developer's
  Notification Center.
- **Defaults:** notifications on, message previews on (up to 100 characters),
  sound and Dock bounce on as before.
- **Authorization:** the toggles show the saved choice; `AppModel.notificationsEnabled`
  is the effective state (choice and macOS authorization). After every successful
  sign-in (new or restored) and whenever the app becomes active,
  `refreshNotificationAuthorization()` reads the macOS status without blocking the
  UI. It shows the permission request only when macOS reports `.notDetermined`, at
  most once per launch, and never before an account exists. A refusal is not
  reported as an error and not asked again; Settings says macOS is blocking
  notifications and where to allow them. An explicit toggle-on calls
  `requestAuthorization`, which macOS answers without prompting once decided.
  Quitting stops delivery and withdraws delivered alerts but keeps the saved choice.
- **Unchanged:** drafts, pending sends and pasted images remain session-only.
  Nothing message-related, account-related or secret is stored in `UserDefaults`.

## Consequences

- Settings now say "Saved on this Mac"; the Accounts privacy note, first-launch
  disclosure, About panel and README describe the saved settings.
- Notification Center receives short message text by default. macOS may retain
  delivered notifications after a crash or forced termination; the disclosure
  stays in Settings.
- Users who previously never answered the permission request are asked once
  after their saved sign-in restores on the next launch.
