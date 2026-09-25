# 0026 — Profile editing and file search

2026-09-25. Profile editing sends only changed first/last name, nickname and position
fields through the existing user patch endpoint. Username and email remain read-only.
The server remains authoritative for sign-in-provider and administrator restrictions;
409 responses have a content-free explanation. Profile changes refresh the pinned
current user and affected presentation snapshots.

Pictures are selected explicitly, read in place with Image I/O off the main actor,
checked against source byte/pixel limits, downsampled to a maximum 512-pixel edge,
center-cropped square and re-encoded to a bounded PNG. The circular preview shows
that crop. Upload and Remove Picture are separate explicit actions. No staging file,
bookmark or disk image cache exists. Removal restores the server-generated default.
A successful mutation invalidates avatar revisions even if refreshing the user fails.
Picture changes retain any unsubmitted text edits in the form. Sign-out closes the
profile sheet, cancels the picker/preparation and clears editor state; changing the
Settings account recreates the form for that account.

Files use the existing single results pane and task key. Search requests use the
server's team file-search endpoint and grammar; Channel Files supplies an `in:`
filter. Results are paginated and bounded by ResourceBudget's search count and byte
limits. Mini-preview data is dropped. Visible thumbnails and explicit image previews
use the existing bounded image pipeline. Save uses the existing explicit download
path, one transfer per pane, with cancellation on pane closure. Search results without
channel metadata cannot preview/download/jump; permissions are checked again by Core.

Out of Office has an explicit presentation and suppresses notifications. It cannot
be chosen as manual presence. Profile cards show a DND end time when supplied by the
single-user status endpoint. This does not add automatic replies or timed-DND controls.
