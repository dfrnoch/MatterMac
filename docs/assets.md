# Asset provenance

The app icons are two Icon Composer documents in `Apps/MatterMac/Resources`:

- `AppIcon.icon` is the production and local-build icon: white glass on Swift's
  orange-to-red gradient.
- `AppIconNightly.icon` is used by nightly releases: violet glass on near-black.

Each holds the same two hand-written SVG layers (`Assets/ring.svg` and
`Assets/drop.svg`) and an `icon.json` that sets the fills, glass and shadows. The
drawing is original, written as SVG path coordinates for MatterMac, and covered by
the repository's MIT license: an open ring with rounded ends, and a drop whose tip
points into the ring's gap. Both shapes share one axis through the centre,
tilted 38° clockwise from vertical. The paths were computed from these values on
the 1024-point canvas:

- **Ring:** centred at (512, 512); centreline radius 300, thickness 88, round ends,
  and a 48° gap centred on the axis.
- **Drop:** symmetric about the axis, with straight sides tangent to its round base.
  The base has radius 136 and its centre is 56 points from the ring centre, away
  from the tip. The tip sits on the ring's centreline, in the middle of the gap.

The build setting `MATTERMAC_APP_ICON` (`App.xcconfig`,
default `AppIcon`) selects the icon; `build-dmg.yml` sets `AppIconNightly` for
`-nightly.` labels and checks `CFBundleIconName`.

It nods to Mattermost's ring-and-drop mark but is not the Mattermost logo: no
Mattermost artwork was traced or copied. It uses no fonts, SF Symbols, stock art or
downloaded images.

Xcode compiles the selected document into the layered Liquid Glass icon in `Assets.car`,
plus an `AppIcon.icns` fallback for macOS 14 and 15. Icon Composer can edit it
(Xcode ▸ Open Developer Tool). To preview a rendition from the repository root:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Apps/MatterMac/Resources/AppIcon.icon --export-image --output-file /tmp/icon.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

`--rendition` also accepts `Dark`, `ClearLight`, `ClearDark`, `TintedLight` and
`TintedDark`. The earlier two-bubble icon and its generator, `Tools/GenerateAppIcon.swift`,
were removed on 2026-09-25.

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

The screenshots in `docs/images/` (every file except `icon.png`) come from the
opt-in `ReadmeShowcaseTests` (UI-support target, an XCTest case). It runs the real
SwiftUI/AppKit shell in the test process against the in-process TestSupport fakes:
no server, no network and no real account. Everything on screen is synthetic and
defined in that file:

- the fictional company "Northwind Studio", its people, teams, channels and
  messages (English, no real people or companies);
- the profile pictures, team icons and the attached dashboard image, drawn with
  Core Graphics in the test (no photos, stock art or third-party images);
- the app icon on the sign-in screen, read from a local build of this
  repository's `MatterMac.app`.

Each window is a focused window on the main display, captured on its own with
`screencapture -l` (never the screen) with its shadow. Behind the windows the test
shows the desktop wallpaper of the Mac it runs on (read with
`NSWorkspace.desktopImageURL(for:)` and never changed), so the glass materials
blur it. The test then composites each capture onto the matching crop of that
wallpaper and scales it to 2000 px wide (PNG, or JPEG at quality 0.85 when a PNG
would exceed 1 MB). The background of the current images is therefore the
maintainer's own desktop wallpaper at capture time (2026-09-25), not an asset of
this project; recapturing on another Mac uses that Mac's wallpaper.

To reproduce from the repository root (it takes focus for about a minute; build
the app first for its icon):

```sh
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac -configuration Debug -derivedDataPath build build
swift build --package-path Packages/MatterMacKit --build-tests
MM_README_SHOWCASE=/tmp/mm-showcase xcrun xctest -AppleLocale en_US -AppleLanguages '(en)' -AppleAccentColor 4 \
  -XCTest UITestsSupport.ReadmeShowcaseTests/testCaptureReadmeShowcase \
  "$(swift build --package-path Packages/MatterMacKit --show-bin-path)/UITestsSupport.xctest"
```

The composited images are written to `/tmp/mm-showcase/final/`, the raw window
captures to `/tmp/mm-showcase/`. `MM_README_SHOWCASE_ONLY=hero,thread` limits the
run to matching shots. The locale and accent are passed to `xctest` because it
reads them before any test runs; they apply to that process only.
