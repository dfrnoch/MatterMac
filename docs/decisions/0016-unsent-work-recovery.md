# 0016 — Recover individual unsent items in memory

Date: 2026-09-24. Status: implemented in the continued native-client work.

Authentication loss and revoked membership retain drafts and pending sends, but
copying all text or discarding an entire account does not let the user recover
individual items or export pasted images. Add a native Unsent Work sheet reachable
from the Session menu and recovery notice. It lists account-scoped drafts and
pending sends, supports per-item copy and confirmed local discard, and exports
pasted images only after explicit destination selection.

A recovery snapshot does not own or transfer the original text reservation.
Attachment references keep their existing shared image leases. The view holds one
latest snapshot and clears it when dismissed. Stable item IDs and revision checks
prevent a stale confirmation from deleting edited/recreated drafts or changed
pending sends. Submitting drafts and sends already in flight are read-only. Local
discard never claims to undo an upload or a possibly delivered message; unknown
outcomes remain labeled. There is no automatic retry, cross-account draft
migration, or disk recovery after quit.

Use the existing ResourceBudget.unsentText count as a combined limit for drafts
and pending operations. Previously only pending operations consumed that count,
so many tiny drafts could retain too much metadata. Admission refuses new work at
the limit; editing existing drafts, conversion to pending and failed-admission
rollback preserve ownership without silently evicting user text.

Pasted-image export reuses the existing DownloadStaging implementation. The write
runs off the main actor, retains the image's budget lease, uses scoped access to
the selected destination, and atomically commits when possible. Cancellation or
failure removes partial output and preserves an existing file. Original selected
local attachments remain at their source paths and are not copied automatically.

The native undo/redo responder refuses restoring an empty draft when no slot is
available, before consuming undo history. Broader pre-existing undo byte-growth
admission requires a separate correction; progress.md records the exact case.
Verification and remaining UI/platform limitations are recorded in progress.md.
