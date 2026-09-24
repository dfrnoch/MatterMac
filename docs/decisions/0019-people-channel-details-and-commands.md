# 0019 — Profiles, channel details, explicit settings and slash commands

Date: 2026-09-24. Status: implemented.

SPEC §3 counts basic profiles, channel information and membership-aware actions as
part of the usable product. Profile cards open from avatars, author names,
`@mentions`, member rows and "View Profile". Data is fetched on demand: users go
into the existing bounded directory LRU, the card's picture holds an image-budget
lease only while visible, and the channel details panel keeps at most 600 member
rows, dropped when it closes or the channel changes. A profile always refreshes the
user's presence because the server pushes status only for the signed-in user.

Channel details use the single optional trailing pane, mutually exclusive with the
thread pane, instead of a SwiftUI inspector. With an inspector the sidebar,
conversation and inspector minimum widths exceed the 760 pt minimum window width and
AppKit raised an "Update Constraints in Window" exception in a native live test.

Favorite, mute, leave and presence changes are explicit server changes (SPEC §4),
separate from local presentation. Favorites use the `favorite_channel` preference
that the server maps into the Favorites sidebar category; mute sends only
`mark_unread`, which the server merges into the member's notify properties. Leaving
asks for confirmation; drafts for the channel stay in the unsent-work list.

Text that begins with `/` is executed with `POST /commands/execute`, matching the
official client, instead of being posted literally (typing `/away` previously
posted "/away" to the channel). A leading space sends such text as a message, which
the server's own not-found error also recommends. Commands never become pending
sends: success releases the draft reservation; failure or an unknown outcome keeps
the draft. Only the synchronous reply text is displayed, above the conversation, and
it is cleared on navigation. Command dialogs, ephemeral bot posts and
`goto_location` are not supported and are listed on the compatibility panel.

The channel name and header now live in the window title and subtitle, with
presence and member count in the toolbar. A header row inside the detail content
rendered blurred under the toolbar edge on macOS 27 (see progress log).
