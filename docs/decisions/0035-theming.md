# 0035 — Window themes

Date: 2026-09-25. Status: accepted at the user's request (gradient themes in the
spirit of SakuraCord's theme designer; SakuraCord is GPL-3.0 and was studied for
behavior only — no code, text or assets were copied).

## Decision

- **Model.** `AppTheme` (MatterMacUI/Theme) is `.system` (the default: the
  standard macOS look, nothing drawn), `.preset(ThemePreset)` (Dawn, Lagoon,
  Meadow, Dusk, Ember, Aurora, Slate) or `.custom(ThemeGradient)`: 2–4 hues sharing
  saturation, brightness and intensity (each 0…1). Initializers clamp; decoding
  rejects out-of-range values.
- **Storage.** One more "On This Mac" value (decision 0032): `MatterMac.theme`,
  versioned JSON `Data` of at most 1 KB, written only when the theme changes.
  A missing, oversized, wrong-type, unknown-version/kind/preset or out-of-range
  value loads as `.system` without writing. Nothing is sent to the server; the
  Mattermost server theme is still not applied.
- **Derived colors.** `ThemePalette(gradient:appearance:)` produces opaque window
  gradient stops, a corner bloom, sidebar stops, an accent and a selection color
  for Light/Dark and Increase Contrast. Each hue is matched to a target luminance
  (pale in Light Mode, deep in Dark Mode) so every hue tints equally. A contrast
  guard then scales the tint down until every surface keeps ≥ 7:1 for primary
  label text and, for secondary text, WCAG AA 4.5:1 or 90 % of the untinted
  window's own contrast where the system is lower (Light Mode's 50 % black is
  ≈ 4:1); Increase Contrast halves the tint and requires the full system
  contrast. The accent keeps 3:1 against every surface and under white badge
  text. Settings says when some tint is held back. All presets pass unclipped.
- **Drawing.** `MainWindowView` injects `\.matterMacTheme` and puts
  `ThemedBackdrop` behind the whole `NavigationSplitView` (`.themedBackground()`),
  tints controls/badges with `.themeAccentTint()`, and the sidebar draws
  `ThemedBackdrop(.sidebar)` over its material. With a theme the AppKit timeline
  stops drawing its text background (`drawsThemedBackground`), so the gradient
  shows through; the composer's glass (or pre-26 box) and every other surface are
  unchanged. No view is added over the title bar: the timeline's `NSScrollView`
  still provides the toolbar's scroll edge effect (verified in captures).
- **Live.** Settings edits `LocalSettings.theme`; SwiftUI observation re-renders the
  backdrop and each pane's `withObservationTracking` binding updates its timeline.

## Adopting the theme elsewhere

A screen puts its content on a clear background and calls `.themedBackground()`
(and `.themeAccentTint()` for its accent) inside a view that has
`\.matterMacTheme` in its environment; with `.system` both are no-ops. Opaque
panes (search results, channel info lists) keep their standard backgrounds for
now.

## Consequences

- The window background is no longer the flat system color when a theme is
  chosen; message rows, mention highlights and code blocks draw their existing
  translucent fills over the gradient.
- The theme accent replaces the system accent only inside MatterMac's main and
  Settings windows (SwiftUI `tint`); AppKit controls and text selection keep the
  system accent.
