# 0038 — Scheduled messages and jumbo emoji

Date: 2026-11-16. Status: implemented.

User request: an option to delay a message or reply (chosen: server-scheduled), and
larger emoji when a message is only one or a few emoji.

## Scheduled messages

- Uses the server's scheduled posts (`POST /posts/schedule`, list
  `GET /posts/scheduled/team/{team}?includeDirectChannels=true`, `PUT`/`DELETE
  /posts/schedule/{id}`; server 10.3+). The server stores and sends the message, so it
  goes out while MatterMac is closed and shows in the web client's Scheduled list.
  MatterMac stores nothing locally, in line with the persistence rules.
- The server requires `ServiceSettings.ScheduledPosts` **and a license**. Its 400s
  (`api.scheduled_posts.*`), a 501, or the generic route 404 on older servers mark the
  feature unavailable for the session. The Send Later button then stays hidden; it is
  shown only after the list loads once.
- Composer: a clock button next to Send opens In 1 Hour, Tomorrow at 9:00, Monday at
  9:00 (left out when Monday is tomorrow) and Custom Time…, a date picker at least two
  minutes ahead. It works for channel messages, thread replies and inline replies
  (`root_id`). Messages with attachments, slash commands and edits can't be
  scheduled: attachments would need uploading at schedule time and the server refuses
  repeating posts with files.
- The draft follows the send path: pinned while the request runs, restored if the
  server refuses, and released, not turned into a pending send, once the server has it.
- A bar above the composer counts this conversation's scheduled messages and lists
  them: Reschedule…, Edit in Composer (back into an empty composer, deleting the
  schedule) and Delete. Failed ones (`error_code` set) are marked "Not sent". Server
  error codes are never shown raw.
- The list reloads when a pane opens or changes conversation, after each action, and
  once about 90 s after the soonest message is due. There is no realtime event
  handling for scheduled posts yet.

## Jumbo emoji

A message that is a single paragraph of 1–10 emoji renders at 2.4× the body size:
system emoji, resolved `:name:` and known custom emoji, with whitespace allowed.
ZWJ sequences, flags and keycaps count as one each. Any text, formatting, a second
block or an unresolved `:name:` keeps the normal size.
