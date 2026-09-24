# 0018 — Static system-emoji table from Mattermost's own name set

Date: 2026-09-24. Status: implemented.

Message `:name:` emoji, reaction chips, `:` completion and the reaction picker need
the Mattermost system emoji names. The server accepts reactions only for names in
its `SystemEmojis` map (or existing custom emoji), so a generic Unicode name list
would both miss aliases such as `thumbsup` and offer names the server refuses.

The table is generated at development time from two pinned, SHA-256-verified
inputs: emoji-datasource 6.1.1 (glyphs, categories, order, skin tones; MIT) and
Mattermost v11.11.1 `emoji_data.go` (authoritative names; Apache-2.0). The
generator fails unless every `SystemEmojis` name is covered, except the image-only
`mattermost` emoji. See [assets](../assets.md) for commands and provenance.

It is one packed `StaticString` (67.5 KB per architecture) rather than a
dictionary literal: thousands of literal entries slow type checking and emit
initialization code. The string is parsed once on first use (about 4 ms in a
release build) into immutable arrays and a name index; lookups and bounded
searches read that shared value from any actor. Skin-tone names are derived from
base names and a tone code, with 25 records listed explicitly where Mattermost's
aliases differ. This static, fixed-size table is not a session cache and holds no
user data.

Custom emoji are not rendered, completed or offered; they remain `:name:` text.
The picker's "Frequently Used" row is a fixed list, and no usage is recorded.
Names longer than the server's 64-character reaction limit are not offered as
reactions. Newer server versions may add names; regenerate with new pinned inputs.
