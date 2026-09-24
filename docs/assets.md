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

The application uses system fonts and framework-provided controls at runtime;
it bundles no font, emoji atlas, or external runtime dependency. See
[LICENSE](../LICENSE) and [architecture](architecture.md).
