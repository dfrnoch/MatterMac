# 0028 — Float controls over the conversation

Date: 2026-09-25

The user asked for a blurred top bar and message content behind the Liquid Glass
composer. The old vertical stack reserved an opaque-looking empty strip underneath
the input, so the glass could not sample message pixels.

The timeline now fills its pane. The composer and temporary download status occupy
a bottom overlay; native scroll content/scroller insets reserve their full height
at the live edge. Changing that height preserves the first visible post/offset, or
keeps the live edge pinned. Existing visibleDocumentRect excludes the insets, so
content visible only behind the composer is not reported as read. Jump to Latest
already follows that same bottom inset. Insets are explicitly owned because AppKit's
automatic inset adjustment otherwise overwrites the bottom reservation.

A single native glass surface contains the input and its optional edit/reply banner,
attachment chips and status text. Those controls therefore retain a readable
background when the timeline scrolls behind them. The macOS 14–15 filled native
fallback remains; no persistence, animation loop, image capture or new dependency
was added to runtime code. macOS controls retain their reduced-transparency behavior.

The header uses the system toolbar material. A macOS 26 background-extension
experiment expanded the native representable beneath the sidebar and was removed;
message reflection beneath the top toolbar remains follow-up work. Thread/search/
detail headers retain their normal safe-area layout.

Focused tests cover composer height growth, resize, download-status visibility,
full-height timeline geometry, preserving an anchor across inset changes and history
prepends, pinned live-edge positioning, and excluding covered posts from visibility
reports. Opt-in fixture captures use MM_GLASS_SNAPSHOTS and only capture the test's
own window. Final app execution evidence belongs in progress.md.
