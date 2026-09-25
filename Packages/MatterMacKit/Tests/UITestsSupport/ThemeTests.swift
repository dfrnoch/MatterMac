import AppKit
import Foundation
import Testing
@testable import MatterMacUI

/// Window themes: the model's validation and storage format, persistence through
/// `LocalSettingsStorage`, and the contrast guarantees of the derived colors.
@MainActor
@Suite("Window themes")
struct ThemeTests {
    private static let appearances = [
        RenderAppearance.light, .dark,
        RenderAppearance(isDark: false, increasedContrast: true), RenderAppearance(isDark: true, increasedContrast: true),
    ]

    /// Presets, extremes and a spread of random gradients.
    private static var sampleGradients: [ThemeGradient] {
        var generator = SeededGenerator(seed: 0x5eed)
        let extremes = [0.0, 1.0].flatMap { saturation in
            [0.0, 1.0].flatMap { brightness in
                [0.0, 0.08, 0.17, 0.33, 0.5, 0.67, 0.83].map { hue in
                    ThemeGradient(hues: [hue, hue + 0.1, hue + 0.3], saturation: saturation, brightness: brightness, intensity: 1)
                }
            }
        }
        let random = (0..<60).map { _ in ThemeGradient.standardCustom.randomized(using: &generator) }
        return ThemePreset.allCases.map(\.gradient) + extremes + random
    }

    // MARK: Model

    @Test func gradientsClampAndKeepTwoToFourColors() {
        let gradient = ThemeGradient(hues: [1.25, -0.25, .nan], saturation: 3, brightness: -1, intensity: .infinity)
        #expect(gradient.hues == [0.25, 0.75])
        #expect(gradient.saturation == 1 && gradient.brightness == 0 && gradient.intensity == 0.5)
        #expect(gradient.isValid)
        #expect(ThemeGradient(hues: [0.1], saturation: 0.5, brightness: 0.5, intensity: 0.5).hues.count == 2)
        #expect(ThemeGradient(hues: [0, 0.1, 0.2, 0.3, 0.4, 0.5], saturation: 0.5, brightness: 0.5, intensity: 0.5).hues.count == 4)

        var edited = ThemeGradient(hues: [0, 0.5], saturation: 0.5, brightness: 0.5, intensity: 0.5)
        edited.addColor()
        #expect(edited.hues.count == 3 && abs(edited.hues[2] - 0.25) < 0.0001)
        edited.addColor()
        edited.addColor()
        #expect(edited.hues.count == 4 && !edited.canAddColor)
        edited.removeColor(at: 0)
        edited.removeColor(at: 0)
        edited.removeColor(at: 0)
        #expect(edited.hues.count == 2 && !edited.canRemoveColor)
        edited.setHue(1.5, at: 1)
        edited.intensity = 7
        #expect(edited.hues[1] == 0.5 && edited.intensity == 1 && edited.isValid)
        for preset in ThemePreset.allCases { #expect(preset.gradient.isValid) }
    }

    @Test func randomizedGradientsAreValidAndKeepBrightness() {
        var generator = SeededGenerator(seed: 42)
        let start = ThemeGradient(hues: [0.2, 0.4], saturation: 0.5, brightness: 0.8, intensity: 0.5)
        for _ in 0..<100 {
            let random = start.randomized(using: &generator)
            #expect(random.isValid)
            #expect(random.brightness == 0.8)
            #expect((0.45...0.8).contains(random.saturation) && (0.6...0.9).contains(random.intensity))
        }
    }

    @Test func storageRoundTripsEveryKindOfTheme() throws {
        let themes: [AppTheme] = [.system, .custom(ThemeGradient(hues: [0.1, 0.6, 0.9], saturation: 0.3, brightness: 0.7, intensity: 0.4))]
            + ThemePreset.allCases.map { .preset($0) }
        for theme in themes {
            let data = try #require(theme.storageData())
            #expect(data.count <= AppTheme.maximumStoredBytes)
            #expect(AppTheme(storageData: data) == theme)
        }
        let preset = try #require(AppTheme.preset(.dusk).storageData())
        #expect(String(decoding: preset, as: UTF8.self) == #"{"kind":"preset","preset":"dusk","version":1}"#)
    }

    @Test func invalidStoredThemesAreRejected() {
        let rejected = [
            "", "null", "[]", #"{"kind":"system"}"#, #"{"version":2,"kind":"system"}"#,
            #"{"version":1,"kind":"sepia"}"#, #"{"version":1,"kind":"preset","preset":"neon"}"#,
            #"{"version":1,"kind":"preset"}"#, #"{"version":1,"kind":"custom"}"#,
            #"{"version":1,"kind":"custom","gradient":{"hues":[0.1],"saturation":0.5,"brightness":0.5,"intensity":0.5}}"#,
            #"{"version":1,"kind":"custom","gradient":{"hues":[0.1,0.2,0.3,0.4,0.5],"saturation":0.5,"brightness":0.5,"intensity":0.5}}"#,
            #"{"version":1,"kind":"custom","gradient":{"hues":[0.1,1.0],"saturation":0.5,"brightness":0.5,"intensity":0.5}}"#,
            #"{"version":1,"kind":"custom","gradient":{"hues":[0.1,0.2],"saturation":1.5,"brightness":0.5,"intensity":0.5}}"#,
            #"{"version":1,"kind":"custom","gradient":{"hues":[0.1,0.2],"saturation":0.5,"brightness":-0.1,"intensity":0.5}}"#,
            #"{"version":1,"kind":"custom","gradient":{"hues":[0.1,0.2],"saturation":0.5,"brightness":0.5}}"#,
            #"{"version":1,"kind":"custom","gradient":{"hues":["red","blue"],"saturation":0.5,"brightness":0.5,"intensity":0.5}}"#,
        ]
        for text in rejected { #expect(AppTheme(storageData: Data(text.utf8)) == nil, "\(text)") }
        // Oversized data is not parsed at all.
        let padded = #"{"version":1,"kind":"system","padding":""# + String(repeating: " ", count: 2000) + #""}"#
        #expect(AppTheme(storageData: Data(padded.utf8)) == nil)
        // Unknown extra keys in an otherwise valid value are tolerated.
        #expect(AppTheme(storageData: Data(#"{"version":1,"kind":"preset","preset":"ember","note":1}"#.utf8)) == .preset(.ember))
    }

    // MARK: Persistence

    @Test func themeIsSavedAndRestoredThroughLocalSettingsStorage() throws {
        let storage = MemorySettingsStorage()
        let first = LocalSettings(storage: storage)
        #expect(first.theme == .system && storage.writes == 0)
        let custom = AppTheme.custom(ThemeGradient(hues: [0.95, 0.12], saturation: 0.7, brightness: 0.3, intensity: 0.9))
        first.theme = custom
        #expect(storage.values["MatterMac.theme"] is Data)
        #expect(LocalSettings(storage: storage).theme == custom)
        let writes = storage.writes
        first.theme = custom
        #expect(storage.writes == writes, "Setting the same theme does not write")
        first.theme = .preset(.meadow)
        #expect(LocalSettings(storage: storage).theme == .preset(.meadow))
        first.theme = .system
        #expect(LocalSettings(storage: storage).theme == .system)
    }

    @Test func invalidSavedThemeLoadsAsSystemWithoutWriting() {
        for value: Any in [Data(#"{"version":1,"kind":"preset","preset":"neon"}"#.utf8), "dusk", 3, [Data()], Data(repeating: 0x7b, count: 5000)] {
            let storage = MemorySettingsStorage(["MatterMac.theme": value, "MatterMac.textSize": "large"])
            let settings = LocalSettings(storage: storage)
            #expect(settings.theme == .system)
            #expect(settings.textSize == .large, "Other settings still load")
            #expect(storage.writes == 0)
        }
    }

    @Test func themeWithoutStorageStaysInMemory() {
        let before = UserDefaults.standard.object(forKey: "MatterMac.theme") == nil
        let settings = LocalSettings()
        settings.theme = .preset(.aurora)
        #expect(LocalSettings().theme == .system)
        #expect((UserDefaults.standard.object(forKey: "MatterMac.theme") == nil) == before)
    }

    // MARK: Derived colors

    @Test func systemThemeHasNoPalette() {
        for appearance in Self.appearances { #expect(AppTheme.system.palette(for: appearance) == nil) }
        #expect(AppTheme.preset(.lagoon).palette(for: .light) != nil)
    }

    @Test func derivedSurfacesKeepStandardTextReadable() {
        for gradient in Self.sampleGradients {
            for appearance in Self.appearances {
                let palette = ThemePalette(gradient: gradient, appearance: appearance)
                let secondaryMinimum = ThemePalette.minimumSecondaryContrast(appearance)
                let surfaces = palette.backgroundStops
                    + palette.backgroundStops.map { palette.glow.over($0, opacity: palette.glowOpacity) } + palette.sidebarStops
                for surface in surfaces {
                    let contrast = ThemePalette.textContrast(on: surface, appearance)
                    #expect(contrast.primary >= ThemePalette.minimumPrimaryContrast, "\(gradient) \(appearance)")
                    #expect(contrast.secondary >= secondaryMinimum - 0.0001, "\(gradient) \(appearance) \(contrast) \(secondaryMinimum)")
                }
                #expect(ThemePalette.textContrast(on: palette.selection, appearance).primary >= ThemePalette.minimumPrimaryContrast)
                #expect(palette.backgroundStops.count == gradient.hues.count)
                #expect((0...1).contains(palette.appliedStrength))
            }
        }
    }

    @Test func accentIsVisibleOnEverySurfaceAndUnderWhiteText() {
        for gradient in Self.sampleGradients where gradient.saturation > 0.2 {
            for appearance in Self.appearances {
                let palette = ThemePalette(gradient: gradient, appearance: appearance)
                let worst = min(palette.accent.contrast(with: .white),
                                (palette.backgroundStops + palette.sidebarStops).map { palette.accent.contrast(with: $0) }.min() ?? 0)
                #expect(worst >= ThemePalette.minimumAccentContrast, "\(gradient) \(appearance) \(worst)")
            }
        }
    }

    @Test func presetsAreVisiblyTintedAndMostlyUnclipped() {
        for preset in ThemePreset.allCases {
            for appearance in [RenderAppearance.light, .dark] {
                let palette = ThemePalette(gradient: preset.gradient, appearance: appearance)
                // A real tint: the surface differs from the untinted window.
                let standard = ThemePalette.standardBackground(appearance)
                let distance = palette.backgroundStops.map {
                    abs($0.red - standard.red) + abs($0.green - standard.green) + abs($0.blue - standard.blue)
                }.max() ?? 0
                #expect(distance > 0.06, "\(preset) \(appearance)")
                #expect(palette.appliedStrength > 0.95, "\(preset) \(appearance)")
            }
        }
    }

    @Test func increasedContrastTintsLess() {
        for preset in ThemePreset.allCases {
            for isDark in [false, true] {
                let standard = ThemePalette.standardBackground(RenderAppearance(isDark: isDark, increasedContrast: false))
                func tint(_ increased: Bool) -> Double {
                    ThemePalette(gradient: preset.gradient, appearance: RenderAppearance(isDark: isDark, increasedContrast: increased))
                        .backgroundStops.map { abs($0.red - standard.red) + abs($0.green - standard.green) + abs($0.blue - standard.blue) }
                        .reduce(0, +)
                }
                #expect(tint(true) < tint(false))
            }
        }
    }

    @Test func colorMathMatchesKnownValues() {
        #expect(ThemeRGB.white.contrast(with: .black) == 21)
        #expect(abs(ThemeRGB(white: 0.5).luminance - 0.214) < 0.001)
        let red = ThemeRGB(hue: 0, saturation: 1, brightness: 1)
        #expect(red == ThemeRGB(red: 1, green: 0, blue: 0))
        #expect(ThemeRGB(hue: 1.0 / 3, saturation: 1, brightness: 1) == ThemeRGB(red: 0, green: 1, blue: 0))
        #expect(ThemeRGB(hue: 0.5, saturation: 0, brightness: 0.4) == ThemeRGB(white: 0.4))
        #expect(red.over(.white, opacity: 0.5) == ThemeRGB(red: 1, green: 0.5, blue: 0.5))
    }
}

/// Deterministic generator (SplitMix64) so random-theme tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
