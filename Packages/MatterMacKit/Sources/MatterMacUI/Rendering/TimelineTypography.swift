public import AppKit

/// The appearance variant a rendered attributed string was produced for. Part of the
/// render-cache key (SPEC §13): dark/light and increased contrast.
///
/// Colors in rendered text are dynamic (`NSColor` system colors or `TimelinePalette`
/// providers), so a rendering stays correct if the appearance changes before the cache
/// entry is replaced; the key still separates variants so no stale variant is reused.
nonisolated public struct RenderAppearance: Hashable, Sendable {
    public var isDark: Bool
    public var increasedContrast: Bool

    public init(isDark: Bool, increasedContrast: Bool) {
        self.isDark = isDark
        self.increasedContrast = increasedContrast
    }

    public init(_ appearance: NSAppearance) {
        let match = appearance.bestMatch(from: RenderAppearance.candidates)
        isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        increasedContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }

    public static let light = RenderAppearance(isDark: false, increasedContrast: false)
    public static let dark = RenderAppearance(isDark: true, increasedContrast: false)

    static let candidates: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]
}

/// Dynamic colors used by the timeline. Every color resolves at draw time for the
/// drawing appearance, so dark/light and increased-contrast switches need no re-render.
/// Only system colors are used as sources.
nonisolated enum TimelinePalette {
    /// Background of the current user's mentions and of @channel/@here/@all.
    static let mentionHighlight = dynamic { _, highContrast in
        NSColor.controlAccentColor.withAlphaComponent(highContrast ? 0.42 : 0.22)
    }
    static let codeBackground = dynamic { isDark, highContrast in
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.16 : (isDark ? 0.10 : 0.06))
    }
    static let inlineCodeBackground = dynamic { isDark, highContrast in
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.18 : (isDark ? 0.12 : 0.08))
    }
    static let quoteBar = dynamic { _, highContrast in
        highContrast ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
    }
    static let flashHighlight = dynamic { _, highContrast in
        NSColor.controlAccentColor.withAlphaComponent(highContrast ? 0.35 : 0.18)
    }
    static let reactionBackground = dynamic { isDark, highContrast in
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.14 : (isDark ? 0.10 : 0.06))
    }
    static let reactionSelectedBackground = dynamic { _, highContrast in
        NSColor.controlAccentColor.withAlphaComponent(highContrast ? 0.40 : 0.20)
    }
    static let reactionSelectedBorder = dynamic { _, _ in NSColor.controlAccentColor }
    static let placeholderFill = dynamic { isDark, highContrast in
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.18 : (isDark ? 0.12 : 0.07))
    }

    /// Stable avatar placeholder tint derived from the user id (no randomness).
    static func avatarTint(for seed: String) -> NSColor {
        let palette: [NSColor] = [
            .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal,
            .systemIndigo, .systemBrown, .systemRed, .systemMint,
        ]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private static func dynamic(_ make: @escaping @Sendable (_ isDark: Bool, _ highContrast: Bool) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let variant = RenderAppearance(appearance)
            var resolved = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                resolved = make(variant.isDark, variant.increasedContrast)
            }
            return resolved
        }
    }
}

/// Fonts and line metrics for one font scale. System fonts only (SPEC §2): the body
/// font comes from `NSFont.preferredFont(forTextStyle: .body)` multiplied by the scale.
/// Instances are cached per scale key (a handful of scales at most per session).
final class TimelineFonts {
    let scaleKey: Int
    let scale: CGFloat
    let bodySize: CGFloat
    let body: NSFont
    let authorName: NSFont
    let meta: NSFont
    let metaBold: NSFont
    let monoSize: CGFloat
    let mono: NSFont
    let bodyLineHeight: CGFloat
    let authorLineHeight: CGFloat
    let metaLineHeight: CGFloat
    let monoAdvance: CGFloat
    private let bodyDescriptor: NSFontDescriptor

    /// Font scales are clamped to a sane range and quantized to 1/100 so they can key
    /// caches without floating-point noise.
    static func scaleKey(for scale: CGFloat) -> Int {
        let clamped = min(max(scale.isFinite ? scale : 1, 0.75), 2.5)
        return Int((clamped * 100).rounded())
    }

    private static var cache: [Int: TimelineFonts] = [:]

    static func forScale(_ scale: CGFloat) -> TimelineFonts {
        let key = scaleKey(for: scale)
        if let fonts = cache[key] { return fonts }
        // Bounded: scale keys come from a user setting; keep at most a few.
        if cache.count >= 8 { cache.removeAll() }
        let fonts = TimelineFonts(scaleKey: key)
        cache[key] = fonts
        return fonts
    }

    private init(scaleKey: Int) {
        self.scaleKey = scaleKey
        let scale = CGFloat(scaleKey) / 100
        self.scale = scale
        let preferredBody = NSFont.preferredFont(forTextStyle: .body)
        bodyDescriptor = preferredBody.fontDescriptor
        bodySize = (preferredBody.pointSize * scale).rounded(.toNearestOrEven)
        body = NSFont(descriptor: bodyDescriptor, size: bodySize) ?? .systemFont(ofSize: bodySize)
        authorName = NSFont.systemFont(ofSize: bodySize, weight: .semibold)
        let metaSize = (NSFont.preferredFont(forTextStyle: .subheadline).pointSize * scale).rounded(.toNearestOrEven)
        meta = NSFont.systemFont(ofSize: metaSize)
        metaBold = NSFont.systemFont(ofSize: metaSize, weight: .semibold)
        monoSize = max(bodySize - 1, 8)
        mono = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
        let metrics = NSLayoutManager()
        bodyLineHeight = ceil(metrics.defaultLineHeight(for: body))
        authorLineHeight = ceil(metrics.defaultLineHeight(for: authorName))
        metaLineHeight = ceil(metrics.defaultLineHeight(for: meta))
        monoAdvance = max(NSAttributedString(string: "M", attributes: [.font: mono]).size().width, 1)
    }

    /// Heading sizes follow the system text styles (title1/title2/title3/headline).
    func headingSize(level: Int) -> CGFloat {
        let style: NSFont.TextStyle = switch level {
        case 1: .title1
        case 2: .title2
        case 3: .title3
        default: .headline
        }
        return (NSFont.preferredFont(forTextStyle: style).pointSize * scale).rounded(.toNearestOrEven)
    }

    struct Variant: Hashable {
        var sizeKey: Int
        var bold: Bool
        var italic: Bool
        var mono: Bool
    }

    private var variants: [Variant: NSFont] = [:]

    /// A body-family (or monospaced) font with the requested traits. The set of sizes is
    /// fixed (body, four heading sizes, mono), so this cache holds at most ~48 entries.
    func font(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        let key = Variant(sizeKey: Int((size * 100).rounded()), bold: bold, italic: italic, mono: mono)
        if let font = variants[key] { return font }
        var font: NSFont
        if mono {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
            if italic {
                let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
                font = NSFont(descriptor: descriptor, size: size) ?? font
            }
        } else {
            var traits = bodyDescriptor.symbolicTraits
            if bold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }
            let descriptor = bodyDescriptor.withSymbolicTraits(traits)
            font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }
        if variants.count >= 96 { variants.removeAll() }
        variants[key] = font
        return font
    }
}
