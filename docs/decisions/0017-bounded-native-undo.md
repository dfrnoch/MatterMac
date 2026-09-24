# 0017 — Admit complete native undo groups

Date: 2026-09-24. Status: implemented.

AppKit undo/redo can bypass ordinary text insertion admission. If another composer
uses the shared headroom, restoring a larger draft could leave visible text that
DraftStore could not save. Rejecting individual edits inside a native undo group
would corrupt that group's history.

The composer applies a whole group synchronously on the main actor, suppressing
intermediate draft and selection publication. It measures final UTF-8 growth
against the available shared budget. An over-budget group is immediately reversed,
restoring the original selection and keeping the operation available for retry.
An admitted group publishes one final draft update. Shrinking operations remain
available at capacity. The composer's own UndoManager routes direct manager calls
and responder actions through the same check.

Native AppKit regression tests cover compound Unicode undo, growth on redo,
capacity consumed by another pane, refusal without losing history, and retry
after capacity is released. Existing count-admission checks remain in place.
This changes neither session-only draft storage nor the bounded undo-history cap.
