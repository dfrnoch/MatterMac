import SwiftUI

/// Colours of the full-window backdrop behind the sign-in screens. Presentation
/// only; nothing here is saved. A theme can tint the backdrop without touching the
/// screens: `.environment(\.onboardingBackdropPalette, .tinted(color))`.
struct OnboardingBackdropPalette: Equatable {
    /// Top-leading glow (the app icon's warm orange by default).
    var warm: Color
    /// Bottom-leading glow.
    var cool: Color
    /// Trailing glow.
    var accent: Color

    static let standard = OnboardingBackdropPalette(
        warm: Color(.displayP3, red: 0.98, green: 0.50, blue: 0.24),
        cool: Color(.displayP3, red: 0.52, green: 0.38, blue: 0.96),
        accent: .accentColor)

    /// One hue throughout, for a single theme colour.
    static func tinted(_ color: Color) -> Self { Self(warm: color, cool: color, accent: color) }
}

extension OnboardingBackdropPalette {
    /// The window theme's hues as the backdrop glows; the standard palette for System.
    init(theme: AppTheme) {
        guard let gradient = theme.gradient else { self = .standard; return }
        let hues = gradient.hues
        func glow(_ hue: Double) -> Color {
            Color(hue: hue, saturation: 0.35 + 0.5 * gradient.saturation, brightness: 0.95)
        }
        self.init(warm: glow(hues[0]), cool: glow(hues[hues.count - 1]), accent: glow(hues[hues.count / 2]))
    }
}

extension EnvironmentValues {
    @Entry var onboardingBackdropPalette: OnboardingBackdropPalette = .standard
}

/// Soft colour field behind the onboarding cards. A mesh gradient on macOS 15 and
/// later, radial glows on macOS 14. The glows drift to a new resting place when the
/// step changes (no continuous animation; none at all with Reduce Motion).
struct OnboardingBackdrop: View {
    /// 0 server address, 1 confirm, 2 sign in; other values clamp.
    var stage: Int = 0
    @Environment(\.onboardingBackdropPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if #available(macOS 15.0, *) {
                mesh
            } else {
                glows
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 1.4), value: stage)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var step: Int { min(max(stage, 0), 2) }

    /// Colour strength over the window background.
    private var strength: Double { isDark ? 0.34 : 0.36 }
    /// The warm glow reads as brown on dark backgrounds; it is quieter there.
    private var warmStrength: Double { strength * (isDark ? 0.7 : 1) }

    @available(macOS 15.0, *)
    private var mesh: some View {
        let base = Color(nsColor: .windowBackgroundColor)
        let s = strength
        let w = warmStrength
        // Interior control points move a little per step; edges stay pinned.
        let centers: [SIMD2<Float>] = [[0.42, 0.52], [0.56, 0.44], [0.62, 0.58]]
        let top: [Float] = [0.58, 0.40, 0.46]
        let side: [Float] = [0.46, 0.58, 0.36]
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [top[step], 0], [1, 0],
                [0, side[step]], centers[step], [1, 1 - side[step]],
                [0, 1], [1 - top[step], 1], [1, 1],
            ],
            colors: [
                base.mix(with: palette.warm, by: w * (step == 2 ? 0.8 : 1.1)),
                base.mix(with: palette.warm, by: w * 0.35),
                base.mix(with: palette.accent, by: s * (step == 0 ? 0.7 : 1.0)),
                base.mix(with: palette.cool, by: s * 0.30),
                base,
                base.mix(with: palette.accent, by: s * 0.55),
                base.mix(with: palette.cool, by: s * (step == 1 ? 1.1 : 0.85)),
                base.mix(with: palette.accent, by: s * 0.35),
                base.mix(with: palette.warm, by: w * (step == 2 ? 0.75 : 0.45)),
            ],
            smoothsColors: true)
    }

    private var glows: some View {
        let s = strength
        let anchors: [(UnitPoint, UnitPoint, UnitPoint)] = [
            (.topLeading, .bottomLeading, .trailing),
            (.top, .bottomLeading, .topTrailing),
            (.topLeading, .bottom, .bottomTrailing),
        ]
        let (warm, cool, accent) = anchors[step]
        return ZStack {
            RadialGradient(colors: [palette.warm.opacity(warmStrength * 1.1), .clear], center: warm, startRadius: 20, endRadius: 640)
            RadialGradient(colors: [palette.cool.opacity(s), .clear], center: cool, startRadius: 20, endRadius: 600)
            RadialGradient(colors: [palette.accent.opacity(s), .clear], center: accent, startRadius: 20, endRadius: 620)
        }
    }
}
