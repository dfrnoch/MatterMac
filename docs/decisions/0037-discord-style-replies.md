# 0037 — Discord-style replies

Date: 2026-11-16. Status: implemented.

User request: make replies look and work like Discord, while keeping the thread
reachable.

## What changed

- **Reply line.** With collapsed reply threads off, a reply in a channel timeline
  shows one line above its header: a connector curving from the reply's avatar, a
  16 pt avatar of the thread root's author, the author's name and the start of the
  root's text (one line, ≤ 160 characters, whitespace collapsed). Deleted, missing
  and still-loading roots get an italic placeholder. Pressing the line opens the
  thread. It replaces the old "↳ Replied to a thread" label.
- **Thread summary.** Under a thread root, "N replies" became a chip with the reply
  count, the last reply time (absolute, like every other timeline time) and a
  chevron. It opens the thread.
- **Inline reply.** With replies shown inline, Reply (hover bar, menu, Return on a
  selected message) puts the channel composer into the existing reply mode
  ("Replying to NAME", Escape or × cancels and keeps the text). The message posts
  with that `root_id` and stays in the channel. **Open Thread** is a separate
  hover-bar button and menu entry on any message that has a thread. With collapsed
  reply threads on, replies are not in the channel, so Reply still opens the thread
  (unchanged).

## Constraints and tradeoffs

- Mattermost only records the thread root (`root_id`), not which reply a message
  answers, so the line always quotes the root. Replying to a reply quotes the root
  too. Discord quotes the exact message; the server has no field for that.
- Roots usually arrive only as page context (`PostPage.related`) or are older than
  the window, and `PostStore` retention drops unreferenced posts after every load.
  `ReplyRootCache` keeps a summary per root: author, webhook name override, preview,
  file count, deleted flag. It is in memory only, per session, and least-recently
  used, bounded by `ResourceBudget.replyRootSummaries` (1,000). It is cleared on
  sign-out/shutdown, purged with a revoked channel, updated by realtime edits and
  deletes, and never persisted to `ContentCache`.
- Roots in neither the store nor the cache are fetched in batches of 100 with
  `POST /posts/ids` (the existing `posts(ids:)`). Roots the server doesn't return
  are remembered as unavailable. After a failed fetch, a root is requested again
  only once a later page load succeeds, so an offline session doesn't retry on
  every rebuild.
- The reply root is part of the channel draft (`Draft.replyRoot`) and charged to
  the unsent-text budget with it, so reply mode survives switching channels like
  edit mode does.
