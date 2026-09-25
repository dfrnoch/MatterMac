import Foundation

/// An sRGB color with components in 0…1 and the WCAG 2 luminance/contrast math the
/// theme uses to keep text readable.
nonisolated public struct ThemeRGB: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
    }

    public init(white: Double) { self.init(red: white, green: white, blue: white) }

    /// HSB (HSV) to RGB; hue wraps, the rest clamp.
    public init(hue: Double, saturation: Double, brightness: Double) {
        let hue = ThemeGradient.normalizedHue(hue) * 6
        let saturation = Self.unit(saturation), value = Self.unit(brightness)
        let sector = Int(hue) % 6
        let fraction = hue - Double(Int(hue))
        let low = value * (1 - saturation)
        let falling = value * (1 - fraction * saturation)
        let rising = value * (1 - (1 - fraction) * saturation)
        switch sector {
        case 0: self.init(red: value, green: rising, blue: low)
        case 1: self.init(red: falling, green: value, blue: low)
        case 2: self.init(red: low, green: value, blue: rising)
        case 3: self.init(red: low, green: falling, blue: value)
        case 4: self.init(red: rising, green: low, blue: value)
        default: self.init(red: value, green: low, blue: falling)
        }
    }

    public static let white = ThemeRGB(white: 1)
    public static let black = ThemeRGB(white: 0)

    /// This color drawn with `opacity` over an opaque `background`.
    public func over(_ background: ThemeRGB, opacity: Double) -> ThemeRGB {
        let alpha = Self.unit(opacity)
        return ThemeRGB(red: red * alpha + background.red * (1 - alpha),
                        green: green * alpha + background.green * (1 - alpha),
                        blue: blue * alpha + background.blue * (1 - alpha))
    }

    /// WCAG 2 relative luminance.
    public var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio (1…21).
    public func contrast(with other: ThemeRGB) -> Double {
        let (first, second) = (luminance, other.luminance)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    static func unit(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
}

/// The concrete colors of a theme for one appearance. Every surface is opaque and
/// is checked against the system's standard label colors: primary text keeps at
/// least 7:1 and secondary text at least 90 % of its contrast on the untinted
/// window (100 % with Increase Contrast). When a gradient would break that, its
/// tint is reduced until it holds, so any stored or random theme stays readable.
nonisolated public struct ThemePalette: Hashable, Sendable {
    public let appearance: RenderAppearance
    /// The untinted base under the tint.
    public let base: ThemeRGB
    /// Window background colors in gradient order (top leading to bottom trailing).
    public let backgroundStops: [ThemeRGB]
    /// A soft bloom at the top trailing corner, drawn over the stops.
    public let glow: ThemeRGB
    public let glowOpacity: Double
    /// Sidebar colors (top to bottom), drawn over the sidebar material.
    public let sidebarStops: [ThemeRGB]
    public let sidebarOpacity: Double
    /// Selection and badge color: 3:1 against every surface and for white text on it.
    public let accent: ThemeRGB
    /// Opaque text selection background; primary text keeps 7:1 on it.
    public let selection: ThemeRGB
    /// How much of the requested tint survived the contrast guard (0…1).
    public let appliedStrength: Double

    /// Standard label colors (`labelColor`, `secondaryLabelColor`) as white/black
    /// with alpha, and the untinted content background.
    static func standardText(_ appearance: RenderAppearance) -> (primary: (ThemeRGB, Double), secondary: (ThemeRGB, Double)) {
        appearance.isDark ? ((.white, 0.85), (.white, 0.55)) : ((.black, 0.85), (.black, 0.5))
    }

    static func standardBackground(_ appearance: RenderAppearance) -> ThemeRGB {
        appearance.isDark ? ThemeRGB(white: 0.118) : .white
    }

    public static let minimumPrimaryContrast = 7.0
    public static let minimumAccentContrast = 3.0

    /// Least contrast secondary text may keep, relative to the untinted window.
    static func minimumSecondaryContrast(_ appearance: RenderAppearance) -> Double {
        let standard = standardBackground(appearance)
        let text = standardText(appearance).secondary
        let system = text.0.over(standard, opacity: text.1).contrast(with: standard)
        // WCAG AA (4.5:1) where the system itself exceeds it (Dark Mode), otherwise
        // within 10 % of the system (Light Mode's 50 % black is about 4:1).
        return appearance.increasedContrast ? system : min(4.5, system * 0.9)
    }

    /// Primary and secondary label contrast on `surface`.
    public static func textContrast(on surface: ThemeRGB, _ appearance: RenderAppearance) -> (primary: Double, secondary: Double) {
        let text = standardText(appearance)
        return (text.primary.0.over(surface, opacity: text.primary.1).contrast(with: surface),
                text.secondary.0.over(surface, opacity: text.secondary.1).contrast(with: surface))
    }

    static func isReadable(_ surface: ThemeRGB, _ appearance: RenderAppearance) -> Bool {
        let contrast = textContrast(on: surface, appearance)
        return contrast.primary >= minimumPrimaryContrast && contrast.secondary >= minimumSecondaryContrast(appearance)
    }

    /// Every opaque color text may be drawn on.
    public var surfaceSamples: [ThemeRGB] {
        backgroundStops + backgroundStops.map { glow.over($0, opacity: glowOpacity) } + sidebarStops + [selection]
    }

    public init(gradient: ThemeGradient, appearance: RenderAppearance) {
        self.appearance = appearance
        let requested = pow(gradient.intensity, 1.2) * (appearance.increasedContrast ? 0.5 : 1)
        // The largest share of the requested tint that keeps every surface readable.
        // Strength 0 is the standard window, which always passes.
        var strength = requested
        if !Self.surfaces(gradient, appearance, strength: strength).allSatisfy({ Self.isReadable($0, appearance) }) {
            var (low, high) = (0.0, strength)
            for _ in 0..<14 {
                let middle = (low + high) / 2
                if Self.surfaces(gradient, appearance, strength: middle).allSatisfy({ Self.isReadable($0, appearance) }) {
                    low = middle
                } else {
                    high = middle
                }
            }
            strength = low
        }
        appliedStrength = requested > 0 ? strength / requested : 1
        let layers = Self.layers(gradient, appearance, strength: strength)
        base = layers.base
        backgroundStops = layers.stops
        glow = layers.glow
        glowOpacity = layers.glowOpacity
        sidebarStops = layers.sidebar
        sidebarOpacity = appearance.increasedContrast ? 0.94 : 0.86
        let accent = Self.accent(gradient, appearance, surfaces: layers.stops + layers.sidebar)
        self.accent = accent
        selection = Self.selection(accent: accent, over: layers.stops, appearance)
    }

    // MARK: Derivation

    private struct Layers {
        var base: ThemeRGB
        var stops: [ThemeRGB]
        var glow: ThemeRGB
        var glowOpacity: Double
        var sidebar: [ThemeRGB]
    }

    /// The tint source for one hue, matched to a target luminance so every hue tints
    /// equally: a pale color in Light Mode (blues and violets are lightened by
    /// giving up some saturation), a deep one in Dark Mode (greens and yellows are
    /// darkened, blues lifted). Brightness moves the target.
    static func source(_ hue: Double, _ gradient: ThemeGradient, _ appearance: RenderAppearance) -> ThemeRGB {
        if appearance.isDark {
            let saturation = min(1, gradient.saturation * 1.15)
            let target = 0.016 + 0.026 * gradient.brightness
            return search(reaching: target) { ThemeRGB(hue: hue, saturation: saturation, brightness: $0) }
        }
        let target = 0.42 + 0.4 * gradient.brightness
        let full = ThemeRGB(hue: hue, saturation: gradient.saturation * 0.85, brightness: 1)
        guard full.luminance < target else { return full }
        // Less saturation is lighter: find the most colorful version that is light enough.
        return search(reaching: target) { ThemeRGB(hue: hue, saturation: gradient.saturation * 0.85 * (1 - $0), brightness: 1) }
    }

    /// The parameter in 0…1 at which `make`'s luminance (increasing with the
    /// parameter) first reaches `target`, or 1 when it never does.
    private static func search(reaching target: Double, _ make: (Double) -> ThemeRGB) -> ThemeRGB {
        guard make(1).luminance > target else { return make(1) }
        var (low, high) = (0.0, 1.0)
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if make(middle).luminance < target { low = middle } else { high = middle }
        }
        return make(high)
    }

    private static func layers(_ gradient: ThemeGradient, _ appearance: RenderAppearance, strength: Double) -> Layers {
        let standard = standardBackground(appearance)
        // Brightness also moves the base: a little grayer or whiter in Light Mode,
        // deeper or lifted in Dark Mode.
        let shifted = appearance.isDark
            ? ThemeRGB(white: 0.06 + 0.08 * gradient.brightness)
            : ThemeRGB(white: 0.955 + 0.045 * gradient.brightness)
        let base = shifted.over(standard, opacity: strength)
        let opacity = (appearance.isDark ? 0.9 : 0.6) * strength
        let sources = gradient.hues.map { source($0, gradient, appearance) }
        let stops = sources.map { $0.over(base, opacity: opacity) }
        let glowSource = sources.count > 1 ? sources[1] : sources[0]
        // The sidebar is a slightly deeper version of the same colors.
        let sidebarBase = base.over(.black, opacity: 1 - (appearance.isDark ? 0.12 : 0.025) * strength)
        let sidebar = sources.map { $0.over(sidebarBase, opacity: min(1, opacity * (appearance.isDark ? 1.1 : 1.3))) }
        return Layers(base: base, stops: stops, glow: glowSource, glowOpacity: opacity * 0.7, sidebar: sidebar)
    }

    private static func surfaces(_ gradient: ThemeGradient, _ appearance: RenderAppearance, strength: Double) -> [ThemeRGB] {
        let layers = layers(gradient, appearance, strength: strength)
        return layers.stops + layers.stops.map { layers.glow.over($0, opacity: layers.glowOpacity) } + layers.sidebar
    }

    /// The first hue, as colorful as possible while keeping 3:1 against every
    /// surface and under white text: first darkened step by step at full saturation,
    /// then (for hues too dark even at full brightness, like deep blue on a dark
    /// window) lightened by giving up saturation. Otherwise the best compromise.
    private static func accent(_ gradient: ThemeGradient, _ appearance: RenderAppearance, surfaces: [ThemeRGB]) -> ThemeRGB {
        let hue = gradient.hues[0]
        let saturation = min(0.9, max(0.3, gradient.saturation * 1.3))
        let darkening = (0...140).lazy.map { ThemeRGB(hue: hue, saturation: saturation, brightness: 1 - Double($0) * 0.005) }
        let lightening = (1...100).lazy.map { ThemeRGB(hue: hue, saturation: saturation * (1 - Double($0) * 0.01), brightness: 1) }
        var best = (color: ThemeRGB(hue: hue, saturation: saturation, brightness: 0.5), score: 0.0)
        for candidate in [AnySequence(darkening), AnySequence(lightening)].joined() {
            let score = min(candidate.contrast(with: .white), surfaces.map { candidate.contrast(with: $0) }.min() ?? 21)
            if score >= minimumAccentContrast { return candidate }
            if score > best.score { best = (candidate, score) }
        }
        return best.color
    }

    private static func selection(accent: ThemeRGB, over stops: [ThemeRGB], _ appearance: RenderAppearance) -> ThemeRGB {
        let background = stops[stops.count / 2]
        var opacity = appearance.isDark ? 0.45 : 0.3
        while opacity > 0.05 {
            let candidate = accent.over(background, opacity: opacity)
            if textContrast(on: candidate, appearance).primary >= minimumPrimaryContrast { return candidate }
            opacity -= 0.05
        }
        return accent.over(background, opacity: 0.05)
    }
}
