# 0014 — Ended sessions preserve unsent work without continuing requests

Date: 2026-09-24

An authenticated 401 handled by the session, realtime authentication failure, or
an unexpected account identity ends that session's network activity. This is a
terminal state for its existing credential, distinct from temporary disconnection
and from explicit shutdown. It advances the epoch, cancels requests/tasks, stops the
socket and service, clears received content, and prevents reconnect/send attempts.
A late disconnected/connected event cannot replace the authentication-required
status. Permission failures (403) remain operation failures, not forced sign-out.
No logout request is sent after identity loss, including during later removal.

Pending work stays in the existing queue and retains its text/image reservations.
Channel revocation also parks affected sends instead of moving their text into a
lossy notice stream. Interrupted in-flight operations retain an unknown outcome;
no late upload completion may proceed to posting in the revoked channel. A user
may explicitly discard them; retries require active membership and send validation.
Unsent drafts remain in DraftStore. Cleared or dismantled composer instances cannot
write empty drafts over saved work or reload stale editing state after revocation.

The shell displays a persistent authentication recovery banner, dismissible access
and operation notices, and a Session menu with explicit clipboard copy and sign-out.
Copy Unsent Text includes drafts and unconfirmed-send text but never attachments.
The recovery UI explains possible already-sent messages and warns against blindly
resending the copied text. The existing sign-out confirmation names the unsent work
and attachment loss before discarding. Sign In Again uses that same confirmation,
removes the old slot, and rediscovers its exact server/subpath so its advertised SSO
providers remain available. No automatic resubmission or cross-account draft
migration is performed. A new login receives a new scope.

Known disabled or unconfirmed file-attachment support disables selection and is
validated by Core before admission. Configuration updates publish the restriction
to both channel and thread composers without deleting existing selections. Archived
channel controls show the existing read-only policy. This does not claim complete
role/permission discovery or all server capability controls.

Copying all text and explicitly signing out are the current recovery options for
inaccessible drafts. A per-item recovery editor/exporter, including pasted-image
export or transfer after reauthentication, remains a separate UI slice. Existing
attachments stay charged in the session until explicit discard/sign-out/quit.

History request replacement (2026-09-25): a canceled initial/around/thread load must
not mark its successor failed or merge an obsolete page. Both success and failure
paths check task cancellation; failure paths also require their exact loading
generation. Cancellation is necessary even on success because closing and
recreating a window can reuse its initial generation number. Gated regressions
reproduced both stale-error clobbering and stale-success acceptance before the fix.
This independently confirmed race is not by itself attribution of a live reconnect
timeout; live failures still need their stage diagnostics.
