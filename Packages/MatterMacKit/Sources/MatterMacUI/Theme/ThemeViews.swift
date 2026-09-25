public import SwiftUI
import AppKit

extension EnvironmentValues {
    /// The window theme from Settings › Appearance (`.system` unless a window injects
    /// the saved one). Read it with `ThemedBackdrop`, `.themedBackground()` or
    /// `.themeAccentTint()` rather than drawing colors directly.
    @Entry public var matterMacTheme: AppTheme = .system
}

extension RenderAppearance {
    init(colorScheme: ColorScheme, contrast: ColorSchemeContrast) {
        self.init(isDark: colorScheme == .dark, increasedContrast: contrast == .increased)
    }
}

extension ThemeRGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// The themed window background for the current `matterMacTheme`, appearance and
/// contrast setting. With the System theme it draws nothing, so the standard
/// backgrounds show. Never hit-testable and hidden from accessibility.
///
/// A screen adopts the theme by putting its content on a clear background over a
/// backdrop, usually with `.themedBackground()`:
///
///     List { … }
///         .scrollContentBackground(.hidden)
///         .themedBackground()
public struct ThemedBackdrop: View {
    public enum Role: Sendable {
        /// The main window gradient behind content and glass chrome.
        case window
        /// The deeper sidebar tint, drawn over the sidebar material.
        case sidebar
    }

    let role: Role
    @Environment(\.matterMacTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ role: Role = .window) {
        self.role = role
    }

    public var body: some View {
        Group {
            if let palette = theme.palette(for: RenderAppearance(colorScheme: colorScheme, contrast: contrast)) {
                switch role {
                case .window: ThemeWindowGradient(palette: palette)
                case .sidebar:
                    LinearGradient(colors: palette.sidebarStops.map(\.color), startPoint: .top, endPoint: .bottom)
                        .opacity(palette.sidebarOpacity)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The opaque linear gradient plus the corner bloom.
struct ThemeWindowGradient: View {
    let palette: ThemePalette

    var body: some View {
        GeometryReader { geometry in
            let radius = max(geometry.size.width, geometry.size.height) * 0.75
            ZStack {
                LinearGradient(colors: palette.backgroundStops.map(\.color),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [palette.glow.color.opacity(palette.glowOpacity), palette.glow.color.opacity(0)],
                               center: .topTrailing, startRadius: 0, endRadius: max(radius, 1))
            }
        }
    }
}

extension View {
    /// Puts the themed window gradient behind this view (edge to edge). No effect with
    /// the System theme; the view must not draw its own opaque background.
    public func themedBackground(_ role: ThemedBackdrop.Role = .window) -> some View {
        background { ThemedBackdrop(role).ignoresSafeArea() }
    }

    /// Uses the theme's accent for controls, selection and `.tint` fills.
    public func themeAccentTint() -> some View {
        modifier(ThemeAccentTint())
    }
}

private struct ThemeAccentTint: ViewModifier {
    @Environment(\.matterMacTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.tint(theme.palette(for: RenderAppearance(colorScheme: colorScheme, contrast: contrast))?.accent.color)
    }
}

/// A small window-shaped preview of a theme (sidebar strip and content) for pickers.
struct ThemeSwatch: View {
    let theme: AppTheme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = theme.palette(for: RenderAppearance(colorScheme: colorScheme, contrast: contrast))
        HStack(spacing: 0) {
            Group {
                if let palette {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        LinearGradient(colors: palette.sidebarStops.map(\.color), startPoint: .top, endPoint: .bottom)
                            .opacity(palette.sidebarOpacity)
                    }
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }
            }
            .frame(width: 22)
            Group {
                if let palette {
                    ThemeWindowGradient(palette: palette)
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
            }
            .overlay(alignment: .topLeading) { lines }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityHidden(true)
    }

    /// Two short "message" lines so the preview reads as a window.
    private var lines: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(Color.primary.opacity(0.35)).frame(width: 30, height: 3)
            Capsule().fill(Color.primary.opacity(0.2)).frame(width: 22, height: 3)
        }
        .padding(8)
    }
}
