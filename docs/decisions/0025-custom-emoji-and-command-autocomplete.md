# 0025 — Custom emoji and server command completion

Date: 2026-09-25. Status: implemented.

Custom emoji remain server-owned. When `EnableCustomEmoji` is enabled, post metadata
supplies names and IDs first; missing names are resolved in batches of at most 200.
The session keeps bounded positive and negative name caches and a bounded queue in
`ResourceBudget`. Missing names (including transient lookup failures) expire after
ten minutes. `emoji_added` immediately replaces a cached miss. Images use the
existing shared, authenticated, in-memory image pipeline and its decoded-byte
leases. Animated emoji show the pipeline's first frame.

TextKit attachments reserve a square at the font's line height before image arrival.
Measurement and drawing use the same attributed text geometry. The render cache
keeps attachment geometry only; displayed cells own bitmap references and release
them when image demand ends. Reaction chips use the same fixed image width for
measurement and painting. Unresolved names retain their `:name:` text.

The reaction picker appends custom emoji in sorted pages of 60, loading as its
custom section scrolls into view. It retains at most the configured picker budget
(default 600); search reaches names beyond this browsing limit. Custom completion
uses the server autocomplete with a `:` fallback in the leading slot. No usage
history is collected. This supersedes the custom-emoji limitation in decision 0018.

Slash completion uses the composer's existing debounce, cancellation and eight-item
popup. It activates only for `/` at draft offset zero and sends the current command
and argument prefix, channel, team and thread root to the server suggestions API.
Accepting replaces that prefix and adds a space; subsequent argument suggestions
come from the server. A missing/unsupported suggestions route falls back to the
legacy command list for command names only. This does not execute a command.

Verification: focused Core/cache/completion and realtime tests; request formation
and decoding checks; live API create/read/delete emoji and command suggestions on
v11.11.1, v11.11.1 under `/company/chat`, and v10.11.24. Live fixtures are removed.
This is native API verification, not an official web-client interoperability test.
