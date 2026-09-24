# 0010 — Keep draft ownership during send admission

Date: 2026-09-24. Status: implemented.

A composer can change channels or be replaced while awaiting the session actor.
Removing its draft before admission allowed navigation to save the same text again;
releasing a rejected reservation before restoring it also let another draft consume
the available budget.

`DraftStore` now pins the original text, selection, and optional edited-post ID until
admission completes. Its existing ledger reservation accounts for those bytes once.
The key is read-only during admission, including in a replacement composer. Acceptance
removes the draft; rejection atomically transfers its reservation back to draft
accounting. Explicit sign-out invalidates the pin so late completion cannot restore
account data. Network edits use the same operation bound and release their reservation
when the edit finishes; queued sends leave ownership with Core.

A composer still supports one submission at a time. An unfinished edit occupies that
conversation's draft slot and resumes in edit mode after navigation; entering edit
mode requires an empty composer. This avoids a second unaccounted compose buffer.
History/visibility work does not occupy the submission slot. Deterministic budget
and native-controller tests exercise navigation, pane replacement, success, rejection,
and sign-out; opt-in native UI integration covers real server admission.
