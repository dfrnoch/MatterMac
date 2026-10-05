# 0036 — Native message forwarding

Date: 2026-10-05. Status: implemented.

Forward Message is available in the timeline context menu, hover More menu and
VoiceOver actions for confirmed, non-deleted, non-system messages with a permalink,
including thread replies and integration posts. A native sheet previews the source,
uses the existing bounded channel/people switcher to select a destination, and
accepts an optional comment through the native composer. Selecting a person opens
or creates the usual DM. Archived destinations are excluded. Only conversations
already in the directory and people found by the existing search are offered; the
sheet does not join an unknown public channel.

This follows the official Mattermost v11.11.1 client:

- [forwardPost](https://github.com/mattermost/mattermost/blob/v11.11.1/webapp/channels/src/actions/views/posts.ts)
  creates an ordinary post containing the optional comment, a newline, and the
  source permalink. It does not copy the source message or re-upload attachments.
- [ForwardPostModal](https://github.com/mattermost/mattermost/blob/v11.11.1/webapp/channels/src/components/forward_post_modal/index.tsx)
  restricts private-channel, direct and group messages to their original
  conversation. MatterMac enforces that restriction again in Core at send admission,
  together with current source membership, destination membership, archive state,
  server message limits and reservation size. Server permissions remain authoritative.

Forwarding uses the existing pending-send queue, stable pending ID, reconciliation
and retry/discard controls. The sheet closes after queue admission, then opens the
destination so the user sees any send failure or uncertain outcome. No queued post
is presented as confirmed before a REST response or realtime echo.

`DraftKey.forwardingPostID` keeps the full outgoing comment/link separate from
ordinary channel and thread drafts. Both comment and permalink are charged to
`ResourceBudget.unsentText` from presentation, including a comment-free forward.
Admission atomically transfers that draft's reservation into the pending send;
rejection restores the draft. Explicit Cancel discards only this forwarding draft.
Forced dismissal retains it for reopening or copying through Unsent Recovery;
sign-out uses the existing account-wide discard flow. It is never cached on disk.

Recipients with access can follow the permalink. MatterMac currently displays
forwarded posts as their comment/link; server-generated embedded post preview cards
are not decoded. The forwarding sheet's preview is a bounded text excerpt and
does not copy source attachments.

Validation uses native Swift fake-service integration and Core tests. This session
did not run forwarding against an actual server or the official web client.
