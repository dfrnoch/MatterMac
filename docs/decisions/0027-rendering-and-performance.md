# 0027 — Native Markdown blocks and reproducible rendering measurements

Date: 2026-09-25

Recovered Claude's interrupted rendering work and completed the model/renderer
migration. Markdown lists retain task state; pipe tables retain alignment and inline
formatting; bot attachments retain their own structure rather than masquerading as
quotes. TextKit 1 provides table grids, wrapping, padding and layout. Small drawing
subclasses decorate quotes, code, rules, attachments and inline backgrounds; both
measurement and display use the same layout manager. No HTML renderer or dependency.

Rendered tables show at most 50 body rows and 10 columns, with a visible omitted
row/column note, and at most 300 UTF-16 units per cell (grapheme-safe ellipsis).
Limits live in ResourceBudget. Copy Text retains the document's full table. The
existing overall character budget remains authoritative. Long code wraps in its
rounded block; no syntax highlighting or separate code-copy button. Task markers
use system-font checkbox characters, retaining `[x]`/`[ ]` in document plain text.

Attachment pretext stays outside the card. Cards show accent, author, safe title
link, text, paired short fields, footer and an explicit unsupported-action note.
Image URLs are explicit safe links, never silently fetched from a third party.
Image-proxy thumbnails for bot attachment images remain unfinished. Hashtags receive
link-color emphasis but no search action. Self/channel-wide mentions tint their
visible message cell; this is presentation, not notification eligibility.

Validation: full package suite passed 358 tests (133 UI-support, 128 Core, 52 API,
27 realtime, 18 models). Two new offscreen rendering tests verify structure, bounds,
and identical TextKit measurement/display heights at widths 180, 420 and 720 points.
One parser test covers task markers, table alignment/inline formatting, and accents.
The build emitted no compiler warnings; existing SwiftUI toolbar ambiguous-size
runtime warnings remain outside this change. No minimum-OS execution is claimed.

Performance measurements and their scope are recorded separately in benchmarks.md.
