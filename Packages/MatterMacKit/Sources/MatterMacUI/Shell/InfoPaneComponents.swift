import SwiftUI

/// Grouped, System Settings–style building blocks for inspector panes: rounded
/// groups with a subtle fill, rows with a colored symbol tile, and a hover/press
/// highlight for tappable rows. Light and dark appearances use the same semantic
/// colors; nothing here is glass (glass belongs to floating controls).
struct InfoGroup<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: Self.shape)
                .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                .clipShape(Self.shape)
        }
    }
}

/// A hairline between rows of an `InfoGroup`, inset past the symbol tile.
struct InfoDivider: View {
    var leadingInset: CGFloat = 42

    var body: some View {
        Divider().padding(.leading, leadingInset)
    }
}

/// A rounded, colored SF Symbol tile (as in System Settings).
struct InfoSymbolTile: View {
    let systemImage: String
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: systemImage)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// The content of one group row: tile, title and trailing accessory.
struct InfoRowLabel<Trailing: View>: View {
    let title: Text
    let systemImage: String
    let tint: Color
    var isDestructive = false
    /// `false` when the trailing control (a labeled toggle) carries the title itself.
    var isTitleAccessible = true
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: Text, systemImage: String, tint: Color, isDestructive: Bool = false,
         isTitleAccessible: Bool = true, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.isDestructive = isDestructive
        self.isTitleAccessible = isTitleAccessible
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            InfoSymbolTile(systemImage: systemImage, tint: isEnabled ? tint : .gray)
            title
                .foregroundStyle(isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(!isTitleAccessible)
            Spacer(minLength: 6)
            trailing()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A trailing chevron for rows that open another view.
struct InfoChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// Plain row buttons with a hover and press highlight that fills the whole row.
struct InfoRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(opacity))
                .onHover { isHovering = $0 }
        }

        private var opacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.1 }
            return isHovering ? 0.05 : 0
        }
    }
}

/// A compact capsule for header statistics (members, pinned, archived).
struct InfoPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration)
    }

    private struct Pill: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .modifier(InfoPillBackground(fill: fill))
                .onHover { isHovering = $0 }
        }

        private var fill: Double {
            guard isEnabled else { return 0.05 }
            if configuration.isPressed { return 0.14 }
            return isHovering ? 0.09 : 0.06
        }
    }
}

/// The capsule shared by statistic pills, interactive or not.
struct InfoPillBackground: ViewModifier {
    let fill: Double

    func body(content: Content) -> some View {
        content
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(fill), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            .contentShape(Capsule())
    }
}
