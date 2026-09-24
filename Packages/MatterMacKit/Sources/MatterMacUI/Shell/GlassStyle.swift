import SwiftUI

/// Liquid Glass on macOS 26 and later, with material fallbacks for macOS 14–15.
/// Use for floating surfaces (banners, toasts, cards, the quick switcher) rather
/// than for content: glass belongs to the navigation and control layer.
extension View {
    /// A floating rounded surface.
    func glassSurface(cornerRadius: CGFloat = 14, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: .rounded(cornerRadius), tint: tint, interactive: interactive))
    }

    /// A floating capsule (pills, toasts, badges).
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: .capsule, tint: tint, interactive: interactive))
    }

    /// `.glass` button style where available, otherwise `.bordered`.
    func glassButtonStyle(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
    }
}

private struct GlassSurface: ViewModifier {
    enum Shape { case rounded(CGFloat), capsule }
    let shape: Shape
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = Glass.regular.tint(tint).interactive(interactive)
            switch shape {
            case .rounded(let radius): content.glassEffect(glass, in: .rect(cornerRadius: radius))
            case .capsule: content.glassEffect(glass, in: .capsule)
            }
        } else {
            switch shape {
            case .rounded(let radius):
                content
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            case .capsule:
                content
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            }
        }
    }
}

private struct GlassButton: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

/// A floating notice card with an icon, message and trailing actions.
struct FloatingBanner<Actions: View>: View {
    enum Tone { case info, warning, error }
    let tone: Tone
    let systemImage: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.callout)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            actions()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 14, tint: tone == .error ? .red.opacity(0.12) : nil)
        .accessibilityElement(children: .contain)
    }

    private var color: Color {
        switch tone {
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}
