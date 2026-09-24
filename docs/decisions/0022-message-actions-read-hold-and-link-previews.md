# 0022 — Message actions, the Mark-as-Unread read hold, server links and link previews

Date: 2026-09-25. Status: implemented.

**Hover action bar.** The timeline owns one `HoverActionBar` overlay, not one per row.
It sits above the scroll view, straddles the top-right edge of the message under the
pointer, and falls back to the single selected row when the pointer is elsewhere.
It holds three fixed quick reactions (`+1`, `white_check_mark`, `heart`), Add
Reaction, Reply and More. It never changes row heights. Hover updates come from a
mouse-moved tracking area, scrolling, snapshot application and selection changes;
there is no timer. On macOS 26 and later the bar uses `NSGlassEffectView`, otherwise
a rounded menu-material `NSVisualEffectView`.

The context menu, More and each row's accessibility custom actions are built from
one list (`TimelinePostActions`), so they cannot drift apart. VoiceOver users get
every action on the row itself (quick reactions first). Control-Return opens the
selected message's menu. The quick reactions are a static list: MatterMac keeps no
recent-emoji history, because persisting it would violate the session-only rule.

**Pin and save.** Pinning calls `POST /posts/{id}/pin|unpin` and updates the
retained copy on success. The server's `post_edited` echo, with a newer `update_at`,
replaces it; edits from other clients win the same way. Saved messages are the
official `flagged_post` preferences. They are now kept when preferences are loaded,
bounded separately from settings (`ResourceBudget.savedPostIDs`, 5,000), and
followed through `preferences_changed`/`preferences_deleted`. A save beyond the cap
still reaches the server but shows as unsaved locally.

**Mark as Unread and the read hold.** `set_unread` returns the member's new read
state (`last_viewed_at`, read message counts, mentions). MatterMac applies it and
shows the "New messages" line above the post. Without more, the visibility policy
would mark the channel viewed again within about 600 ms, because the user is still
looking at the live edge. So the session keeps a hold for the channel
(`manualUnreadHold`). While it is set, no automatic `view` request is made, and the
sidebar shows the open channel as unread.

The hold ends only when the user acts again:
- scrolls that channel's timeline. The timeline reports user scrolls separately
  (bounds changes outside its own updates); snapshot application, incoming posts,
  resizes and programmatic jumps do not count.
- sends a message in it.
- opens another channel.

App activation, window changes and realtime events leave it in place. A queued view
request is cancelled before `set_unread` is sent, and a failed request releases the
hold. Mark as Unread is offered in channel timelines only. The thread pane would need
the separate thread-level `set_unread`, which is not implemented.

**Links into the signed-in server.** `MattermostLink` recognizes `/<team>/pl/<post>`,
`/<team>/channels/<name>` and `/<team>/messages/@user`. A link matches only when it
has the same origin and the endpoint's subpath, and every component is validated.
Such links open inside the app: posts are looked up in the store, otherwise with
`GET /posts/{id}`. MatterMac opens only channels the user belongs to. It never joins
one implicitly, and never follows a link to another server with this session. Any
other link keeps the existing safe-link policy and opens in the browser.

**Link previews.** Previews show only metadata the server already produced
(`metadata.embeds`: the first OpenGraph or image embed), decoded with bounded
strings: title 300 bytes, description 600, site name 100, URLs 2,048. Previews are
dropped when the post has message attachments, and SVG images are dropped.

Images load only when the server reports `HasImageProxy`. The request goes to
`GET /api/v4/image?url=` with redirects refused. When the proxy is off, the server
answers that endpoint with a redirect to the third-party site, so refusing redirects
guarantees MatterMac never contacts the previewed site. Without a proxy, cards are
text-only. Images go through the existing bounded `ImagePipeline` and per-row image
demand.

The user's `display_settings/link_previews = false` hides website previews. The
card sits between the text and attachments and is part of the row's measured
layout; unmeasured rows use a character-count estimate. Clicking the card opens the
link through the same path as text links.

**Grouping and timestamps.** Continuation now also requires the same webhook origin
and non-decreasing creation time. A pending send continues the user's own recent
group, as in the official client. "(edited)" follows the message text, so it also
shows on continuation rows. Hovering the header time shows the full date and edit
time. Hovering a continuation row shows its time in the avatar gutter.
