# 0040 — Agent control from the command line

Date: 2026-11-16. Status: implemented.

User request: let agents look at and work with the chats; a local, low-overhead
mechanism instead of an MCP server ("I just want it so it can be agent controlled").

## Shape

`MatterMac.app/Contents/MacOS/MatterMac agent <command>` is the app's own executable
in a command-line mode: it sends one JSON request to the running app and prints the
JSON answer (exit status 0, or 1 with `"ok": false`; 2 when the app isn't
listening). No second target, no daemon, no protocol library.

| Command | Does |
|---|---|
| `status` | accounts, connection, the open conversation |
| `channels [--unread] [--limit N]` | conversations by latest activity, with unread and mention counts |
| `read <channel> [--limit N] [--before <post id>]` | messages, oldest first |
| `thread <post id>` | a whole thread |
| `search <terms> [--limit N]` | message search in the current team |
| `send <channel> <text> [--reply-to <post id>]` | send (`-` reads the text from standard input) |
| `open <channel> [--post <post id>]` | show a conversation in the window |
| `summary today` / `summary thread <post id>` | the assistant's summaries (decision 0039) |

`<channel>` is an id, a URL name, an unambiguous display name, or `@username`.

## Security and behavior

- **Off by default** (Settings › Assistant › Allow command-line agents). Turning it
  on is consent for any program running as the user to read conversations and send
  as them while MatterMac is open.
- Transport: a Unix domain socket at `<container>/Data/agent.sock`, mode 0600, peer
  user id checked; request ≤ 256 KiB, response ≤ 4 MiB, at most 8 connections. A
  sandboxed process can bind and connect inside its own container without the
  network-server entitlement (verified with a sandboxed probe).
- The agent never sees the token; requests run in the app against the active
  account only.
- Reads fetch without opening windows: nothing is marked read and the visible
  conversation does not change.
- Sends use the composer's validation, the unsent-text budget and the pending
  queue, so they appear in the app like typed messages. The answer is `sent` only
  after the server confirmed the post (waits up to 8 s), otherwise `queued`,
  `unknown` or a failure with the reason.
- Diagnostics record that a command ran, never its content.

## Limits

- One account (the active one). No attachments, reactions, edits or deletes.
- An agent running inside its own sandbox (for example Codex's default) cannot
  launch the app-sandboxed executable; it needs permission to run it unsandboxed.
- A second running copy of the app with the same bundle ID does not take over the
  socket; its Settings says another copy is answering.
