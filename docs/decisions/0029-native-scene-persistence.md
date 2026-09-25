# 0029 — Fresh main window and session-only split geometry

Date: 2026-09-25

Disabling scene restoration can leave a legacy empty restore session with no main
window. Apple's `defaultLaunchBehavior(.presented)` only applies when previous saved
state is absent; it did not fix the real-app regression without the test-only
`ApplePersistenceIgnoreState` override. The main scene's initial lifecycle callback
therefore explicitly opens its existing unique window ID once per process. It must
not wait for `.active`, because a windowless scene can remain inactive. Later
activation does not reopen a window the user deliberately closed. The macOS 14
path uses the same callback; it has not been executed on macOS 14.

SwiftUI's scene-owned NavigationSplitView assigns a native autosave name despite
scene/window restoration being disabled. A standalone scene fixture measured two
split views with one name, unlike the NSHostingController-only fixture (zero names).
One process-lifetime `NSSplitView.willResizeSubviewsNotification` observer clears
that name before AppKit resizes/saves. The callback also catches replacement views
after login and newly opened panes. No polling, stored frame state, UserDefaults
access, preference deletion, or manual split-layout implementation is introduced.

The scene fixture with the guard kept zero names across initial login, pane opening,
sign-out, replacement login and pane closing. Native fixture tests resize new and
replaced splits after assigning fresh fixture names. The semantic sampler compares
only the two known native geometry keys, under a 1 MiB input cap, and prints change
flags without values. Existing preferences remain untouched. Historical keys or an
mtime change alone do not prove a current app write; the initial real-app audit
without successful window resizing reported no semantic changes. The guard is not
claimed to fix the separate search-pane overflow without actual screenshots.
