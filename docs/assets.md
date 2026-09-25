# Asset provenance

The app icon is an original geometric drawing made for MatterMac: two speech
bubbles, three dots, and a rounded background. It uses Core Graphics paths and
colors, with no fonts, SF Symbols, stock art, downloaded image, or Mattermost logo.
The recovered generator is [Tools/GenerateAppIcon.swift](../Tools/GenerateAppIcon.swift),
covered by the repository's MIT license along with its generated PNGs.

To reproduce the app icon from the repository root:

```sh
swift Tools/GenerateAppIcon.swift /tmp/mattermac-icons
```

The initial-publication check reproduced all ten committed PNGs byte-for-byte on
the recorded local toolchain. Image encoders on other OS versions may produce
different PNG byte streams for the same drawing. The generator is a development
tool and is not linked into the app.

## System emoji table

`Packages/MatterMacKit/Sources/MatterMacModels/Emoji/SystemEmojiData.swift` is a
generated short-name → Unicode table (no images; glyphs are drawn by the system
emoji font). It is produced by the development-only
[Tools/GenerateEmojiCatalog.swift](../Tools/GenerateEmojiCatalog.swift), which is
not linked into the app. The app never downloads emoji data. Inputs, pinned by
SHA-256 and checked by the generator before it writes anything:

| Input | Source | License | SHA-256 |
| --- | --- | --- | --- |
| `emoji.json` | [iamcal/emoji-data](https://github.com/iamcal/emoji-data) tag `v6.1.1` (identical to the `emoji-datasource@6.1.1` npm package, the version Mattermost v11.11.1 builds from) | MIT, © 2013 Cal Henderson | `6e7ebffed46cc813a7e47191eaabe9c4efb39e66b731d72e21e3e8134eb8296e` |
| `emoji_data.go` | [mattermost/mattermost](https://github.com/mattermost/mattermost) tag `v11.11.1`, `server/public/model/emoji_data.go` (`SystemEmojis`) | Apache-2.0 (`server/public/` per the repository's LICENSE.txt) | `f643f1a2edcadb04b980cd4b987c75362efde54caab2ccbf32a9048d6c8f2b4c` |

`emoji.json` supplies glyph code points, categories, picker order and skin-tone
variations; `SystemEmojis` is the authoritative set of names the server accepts
for reactions. The generator fails unless every `SystemEmojis` name is covered
exactly once; the only exclusion is Mattermost's image-only `mattermost` emoji.
The output has 1,810 emoji, 1,490 skin-tone variants and 4,463 short names in one
packed string literal (67,525 bytes of `__cstring` in the release object file),
parsed once on first use. Most skin-tone names are derived from the base names
plus a tone suffix instead of being listed, which roughly halves the table
(listing every name would add about 68 KB). Custom (server-uploaded) emoji are not included.

To reproduce the table from the repository root:

```sh
curl -fsSL -o /tmp/emoji.json https://raw.githubusercontent.com/iamcal/emoji-data/v6.1.1/emoji.json
curl -fsSL -o /tmp/emoji_data.go https://raw.githubusercontent.com/mattermost/mattermost/v11.11.1/server/public/model/emoji_data.go
swift Tools/GenerateEmojiCatalog.swift /tmp/emoji.json /tmp/emoji_data.go \
  Packages/MatterMacKit/Sources/MatterMacModels/Emoji/SystemEmojiData.swift
```

## Runtime

The application uses system fonts and framework-provided controls at runtime;
it bundles no font, emoji atlas, or external runtime dependency. See
[LICENSE](../LICENSE) and [architecture](architecture.md).

## README screenshots

`docs/images/*.png` are captures of MatterMac's own test window, with no other part
of the screen. They were taken by the opt-in `LiveReadmeScreenshotsTests`
(UI-support target), signed in as the synthetic test user **alice** on the local
Mattermost 11.11.1 test server (`Tests/Integration/Server`). The only content is
the synthetic "Design Demo" channel seeded by `LiveSeedDemoTests`. Its dashboard
image is drawn with Core Graphics in that test, and contains no real data or
third-party art. Captures were downscaled to 1600 px with `sips`. To reproduce
them, from the repository root with the test servers running:

```sh
set -a; . ./.local/test-server.env; set +a
MM_LIVE_TESTS=1 MM_SEED_DEMO=1 swift test --package-path Packages/MatterMacKit --filter LiveSeedDemoTests
MM_README_SCREENSHOTS=/tmp/mm-readme swift test --package-path Packages/MatterMacKit --filter LiveReadmeScreenshotsTests
```
