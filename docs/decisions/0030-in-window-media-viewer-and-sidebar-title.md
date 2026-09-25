# 0030 — In-window media viewer and sidebar title placement

Date: 2026-09-25

## Media viewer

Image attachments now open in an in-window viewer (`MediaViewerController`)
instead of a separate panel. The design follows SakuraCord's viewer behavior
(studied, not copied: SakuraCord is GPL-3.0). It dims the whole window, shows the
author and time at the top left, has a glass action group and a separate Close
button at the top right, previous/next for messages with several images, and
closes on a click outside the image.

The overlay is a subview of the window's frame view (`contentView.superview`), so
it covers the title bar and toolbar as well as the content. That superview is not
documented API. On macOS 27 adding the view produced no AppKit console warning
(probe window with a toolbar, `log show` checked). If the superview is ever
missing, the viewer falls back to the content view, where the toolbar stays
visible above the dim. The overlay must stay first responder while open. It
handles Escape, Space, arrows, ⌘W, ⌘C, ⌘S and zoom keys, and swallows wheel input
so nothing reaches the conversation underneath.

Memory stays within the image budget. One full-image lease is held at a time,
and moving to another image releases the previous one. While the full image
loads, the viewer shows the timeline's thumbnail by holding a second reference
to the same `ImagePipeline.Decoded`. That keeps the thumbnail's bytes charged
until the viewer drops it, rather than keeping an untracked `CGImage` alive. The
author avatar is fetched through the pipeline with its own lease. Everything is
released when the viewer closes.

Video and other non-image files still go through Save (explicit download).
Playing them in the viewer would need AVFoundation to stream through the app's
own ephemeral transport (for example with a resource-loader delegate), because
AVFoundation's own networking would bypass the bearer-only, cache-free rules.
That is not implemented.

## Sidebar title

The window uses full-size content. There, `.navigation` toolbar items start
after the sidebar toggle, in the detail column. A SwiftUI overlay placed in the
title bar area does not receive clicks, because `NSTitlebarView` takes them. An
`.automatic` item declared by the sidebar column is placed in the sidebar's part
of the toolbar, just before the toggle. Giving it a width of the column width
minus 154 pt makes it start next to the traffic lights and keeps it clickable.
This was measured in the native fixture window, not on macOS 14 or 15.

The channel list is clipped at its own top edge, and on macOS 26+ the top scroll
edge effect is hidden. Rows used to scroll on under the title bar, where the edge
effect blurred them behind the traffic lights.
