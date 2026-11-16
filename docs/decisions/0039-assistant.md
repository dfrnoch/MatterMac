# 0039 — Assistant: reply suggestions and summaries

Date: 2026-11-16. Status: implemented.

User request: AI that always prefills a reply, thread and today summaries, with a
choice of on-device and Claude, and "connect with my subscription claude/codex".

## What it does

- **Reply suggestion.** When the newest message in the visible conversation is
  someone else's (not a bot, not older than 72 hours), the composer is empty and the
  app is active, the assistant drafts a reply. It shows as ghost text with a "Tab"
  hint (only with "Suggest a reply while reading" on); Tab inserts it as an ordinary undoable edit that counts against the draft
  budget, Escape removes it for that message, typing hides it. It is never a draft
  and never sent by itself. One request per newest message, after a 1.2 s settle;
  the last 48 suggestions are cached in memory.
- **Thread summary.** "Summarize" in the thread pane header: fetches the thread (up
  to 200 posts) and shows the summary in a popover.
- **Today.** Go ▸ Summarize Today (⇧⌘Y): today's messages from up to 15 conversations
  (mentions and direct messages first, then latest activity; 60 posts each).
- Every summary states how many messages it covers, how many were left out to fit,
  which provider wrote it, and that it can be wrong.

- **The user's voice** (user feedback 2026-11-16: suggestions "talk like a LinkedIn
  robot"; then: "a button to learn from my writing … sonnet 5.5 … then haiku will
  create the messages"). Two steps:
  1. **Learn from My Writing** (Settings, shown once suggestions are on): reads up
     to 300 of the user's own recent messages (`from:<username>` search in the current
     team, pages of 100, each cut to 400 characters, at most 60,000 characters) and
     asks the stronger model for notes on how they write (≤ 200 words: language,
     casing, punctuation, length, typical phrases, what they never do). The notes
     are a `StyleProfile` kept in the Keychain per account (≤ 2,400 characters),
     shown in Settings, and deleted by Forget or Sign Out. Fewer than 10 messages:
     nothing is sent.
  2. Every suggestion request carries the notes, up to 12 of the user's own messages
     from the current conversation, and its last 20 messages; the fast model writes
     the reply. The instructions ask for their language, casing, punctuation, length
     and bluntness, and for no greetings, thanks or enthusiasm they would not use.
  Models by task: Claude API uses Haiku 5.5 for replies and Sonnet 5.5 for learning
  (fixed), and the Settings picker only chooses the summary model; the Claude Code
  script uses Haiku for replies and Sonnet otherwise; Codex and the on-device model
  have one model.
- **Off by default, twice.** No provider is chosen at first, and "Suggest a reply
  while reading" is a separate switch that starts off. Without it nothing is
  requested unless the user clicks Summarize, Summarize Today, Test or Learn.
- The on-device model does not support Czech (`supportsLocale` is false) and in a
  Czech test it either repeated a style sample or wrote nonsense; Claude Code (Haiku)
  and Codex produced fitting replies from the same prompt. Settings lists the
  languages Apple's model handles.

## Providers (Settings › Assistant, off by default)

| Choice | Where the text goes | Notes |
|---|---|---|
| On-device model | Nowhere | FoundationModels, macOS 26+, Apple Intelligence on. About 4,000 tokens of context, so input is capped at 6,000 characters and long days are condensed per conversation, then combined. |
| Claude API | `api.anthropic.com` | `POST /v1/messages`, API version `2026-10-21`, key in Keychain. Replies `claude-haiku-5-5` (effort `low`), learning `claude-sonnet-5-5`, summaries the chosen model (default `claude-opus-5-5`), both effort `medium`; `fallbacks: "default"` on Opus and Sonnet; refusals reported as such. |
| Claude Code | Anthropic, via the user's `claude` login | User-installed script, `claude -p` with tools, MCP, slash commands and session history off; Haiku for replies, Sonnet for summaries. |
| Codex | OpenAI, via the user's `codex` login | User-installed script, `codex exec --ephemeral --sandbox read-only`. |

## Decisions and tradeoffs

- **Subscriptions through a user-installed script, not a new unsandboxed helper.**
  The sandboxed app cannot run `claude` or `codex`. `NSUserUnixTask` runs scripts
  from `~/Library/Application Scripts/<bundle id>/` outside the sandbox, which is
  Apple's mechanism for this and keeps "the update installer is the only
  unsandboxed code MatterMac ships" true. The app cannot install the script: a
  file written from the sandbox is quarantined and macOS then refuses to run it
  (verified: error 3587). Settings offers a Terminal command instead. Scripts
  cannot be killed; on timeout (180 s) or cancellation their pipes are closed.
- **Network rule relaxed** for the Claude API only: one more host, contacted only
  when that provider is chosen, with the same ephemeral session rules.
- **Prompt injection.** Message text is other people's content. Every prompt says
  to treat it as material, not instructions; output is only shown to the user or
  offered as a suggestion they must accept and send themselves. The script
  providers run with tools disabled.
- **No silent truncation.** A conversation that does not fit loses its oldest
  messages and the count is shown. A provider that still rejects the size gets one
  retry with half the input.
- Provider errors are mapped to fixed texts; response and error bodies are never
  shown or logged. A broken setup (no key, no script, model unavailable) is
  reported once per run; transient failures only mean no suggestion.

## Not done

- No streaming of summaries.
- Suggestions do not learn from which ones were accepted.
- Reply suggestions for threads use the thread pane's own conversation; a channel
  with inline replies mixes threads in the context.
