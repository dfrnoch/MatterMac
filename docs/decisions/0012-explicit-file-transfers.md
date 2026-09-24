# 0012 — Connect native file selection to the existing sender

2026-09-24. Files are selected through NSOpenPanel or existing file URL paste/drop
callbacks. Selection reads only bounded metadata. It does not upload or stage file
contents. The existing Core sender streams selected files when the user sends;
its global transfer admission remains authoritative.

Drafts own the selected UploadSources alongside text/caret/edit state. Source URLs,
names and bookkeeping are charged to the shared unsent-work ledger, so an
attachment-only draft triggers quit/sign-out protection and follows the existing
atomic draft-to-pending reservation. Per-post selection count and path size are
ResourceBudget limits. Rejected admission keeps the draft; navigation cancels late
selection work and restores the correct channel/thread's files. Editing an existing
post does not accept new attachments in this slice.

File identity, size and nanosecond mtime are captured on selection, rechecked after
transfer admission, and monitored during upload. Security-scoped access lasts only
for metadata inspection or transfer. Sources are never copied to a staging folder,
and no bookmarks are persisted. Uploaded IDs stay in the pending send and are reused
on explicit retry. An ambiguous upload response parks the send as outcome unknown;
it cannot silently retry on reconnect. Queued/uploading items offer Discard, which
cancels the upload before posting and lets the next queued message proceed. Once
a post request is in flight it cannot be represented as successfully cancelled. Orphaned uploads remain subject to the
server's own behavior/cleanup; there is no invented client deletion endpoint.

Downloads use NSSavePanel and bounded streaming to the chosen destination. One
operation per pane has a Cancel Download control; per-session bookkeeping and the
shared transfer admission bound concurrent work. Navigation, sign-out and known
membership revocation cancel affected work. The API removes partial output on
failure/cancellation, keeps existing destination contents intact, and commits only a
completed response. If sandbox access disallows a sibling partial file, direct
creation is allowed only for a new destination (O_EXCL). Replacement then fails
safely rather than truncating an existing file. Files are never opened automatically.

Pasted image data remains explicitly unavailable: it needs a bounded memory upload
source shared across draft/pending ownership, not a hidden temporary-file shortcut.
Automatic image previews and adding/removing files on existing posts remain separate
work. Test evidence and live root/subpath round trips are in docs/progress.md.
