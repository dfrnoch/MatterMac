# 0013 — Pasted images and visible preview ownership

Date: 2026-09-24

PNG/TIFF clipboard bytes use the existing attachment draft, queue, and raw-body
upload path. No image conversion or temporary upload file is needed. A shared
8 MiB admission budget is charged by a reference owned by the upload source.
Copies in drafts, pending sends and active transfers share that reference; its last
release returns the charge. Refused pastes preserve existing work and return false
to AppKit. This also avoids claiming a successful drag when admission fails.

The process-wide image pipeline requests authenticated server thumbnails and
avatars. It admits fetches before retaining encoded bytes, coalesces matching
requests, downsamples with Image I/O after checking source dimensions, and retains
only a first frame. There are no direct third-party image fetches. Cache entries,
returned task results and visible rows share a decoded-image owner. Cache eviction
cannot return the budget while a row still displays that bitmap. Cells keep demand
registered until they leave the table and clear their image before releasing demand.

The decoded budget includes a conservative reservation while decoding (up to
4 MiB per image), replaced by actual row-bytes × height afterward. It retains at
most 32 MiB in total, 1,024 cache entries and 256 failed-resource entries. The
512-pixel edge ceiling and source-pixel bound are centralized in ResourceBudget.
Encoded responses have a 2 MiB per-object ceiling and an 8 MiB aggregate ceiling;
fetch/decode concurrency also respects that aggregate. Queued cancellation releases
its gate waiter; account purges cancel flights so late results cannot repopulate
cache entries. Capacity refusal leaves a placeholder and may retry on row reuse.

These are application ownership bounds, not a measurement of all Image I/O,
AppKit, URLSession or operating-system allocations. NSImage wraps the retained
CGImage; a whole-process image-heavy performance and filesystem audit remains a
release gate. No claim is made that the operating system never writes clipboard
or networking internals. Explicit downloads retain the existing user-chosen path.
