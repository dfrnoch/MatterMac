import SwiftUI

/// Settings › Appearance › Theme: a gallery (System, the presets, Custom) and, for
/// any theme but System, an editor for its gradient. Editing a preset turns it into
/// a custom theme. Every change applies live and is saved on this Mac.
struct ThemeSettingsSections: View {
    @Bindable var settings: LocalSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Section {
            ThemeGallery(settings: settings)
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Theme")
                Text("Tints the window behind the sidebar, conversation and toolbar. Text keeps its contrast.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        if let gradient = settings.theme.gradient {
            Section {
                editor(gradient)
            } header: {
                Text(settings.theme == .custom(gradient) ? "Custom Theme" : "Customize")
            }
        }
    }

    @ViewBuilder private func editor(_ gradient: ThemeGradient) -> some View {
        ForEach(Array(gradient.hues.enumerated()), id: \.offset) { index, hue in
            LabeledContent {
                HStack(spacing: 8) {
                    HueSlider(hue: Binding(get: { hue }, set: { value in edit { $0.setHue(value, at: index) } }),
                              label: String(localized: "Color \(index + 1)"))
                    Button {
                        edit { $0.removeColor(at: index) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!gradient.canRemoveColor)
                    .help("Remove this color")
                    .accessibilityLabel("Remove color \(index + 1)")
                }
            } label: {
                Text("Color \(index + 1)")
            }
        }
        HStack {
            Button {
                edit { $0.addColor() }
            } label: {
                Label("Add Color", systemImage: "plus")
            }
            .disabled(!gradient.canAddColor)
            .accessibilityIdentifier("themeAddColor")
            Spacer()
            Button {
                var generator = SystemRandomNumberGenerator()
                settings.theme = .custom(gradient.randomized(using: &generator))
            } label: {
                Label("Randomize", systemImage: "dice")
            }
            .accessibilityIdentifier("themeRandomize")
            Button("Reset to System") { settings.theme = .system }
                .accessibilityIdentifier("themeReset")
        }
        slider("Saturation", systemImage: "drop.halffull", value: gradient.saturation) { $0.saturation = $1 }
        slider("Brightness", systemImage: "sun.max", value: gradient.brightness) { $0.brightness = $1 }
        slider("Intensity", systemImage: "circle.lefthalf.filled", value: gradient.intensity) { $0.intensity = $1 }
        let appearance = RenderAppearance(colorScheme: colorScheme, contrast: contrast)
        if ThemePalette(gradient: gradient, appearance: appearance).appliedStrength < 0.9 {
            Label("Some of the tint is held back so message text stays readable.", systemImage: "textformat")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("themeContrastNote")
        }
    }

    private func slider(_ title: LocalizedStringKey, systemImage: String, value: Double,
                        set: @escaping (inout ThemeGradient, Double) -> Void) -> some View {
        LabeledContent {
            Slider(value: Binding(get: { value }, set: { newValue in edit { set(&$0, newValue) } }), in: 0...1)
                .accessibilityLabel(Text(title))
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func edit(_ change: (inout ThemeGradient) -> Void) {
        var gradient = settings.theme.gradient ?? .standardCustom
        change(&gradient)
        settings.theme = .custom(gradient)
    }
}

/// Swatch tiles for System, each preset and Custom.
private struct ThemeGallery: View {
    let settings: LocalSettings

    private enum Choice: Hashable { case system, preset(ThemePreset), custom }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 12)], spacing: 12) {
            tile(.system, title: String(localized: "System"), preview: .system)
            ForEach(ThemePreset.allCases) { preset in
                tile(.preset(preset), title: preset.title, preview: .preset(preset))
            }
            tile(.custom, title: String(localized: "Custom"), preview: .custom(customPreview))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Themes")
    }

    private var selected: Choice {
        switch settings.theme {
        case .system: .system
        case .preset(let preset): .preset(preset)
        case .custom: .custom
        }
    }

    private var customPreview: ThemeGradient {
        if case .custom(let gradient) = settings.theme { return gradient }
        return settings.theme.gradient ?? .standardCustom
    }

    private func tile(_ choice: Choice, title: String, preview: AppTheme) -> some View {
        let isSelected = selected == choice
        return Button {
            switch choice {
            case .system: settings.theme = .system
            case .preset(let preset): settings.theme = .preset(preset)
            case .custom: if !isSelected { settings.theme = .custom(customPreview) }
            }
        } label: {
            VStack(spacing: 5) {
                ThemeSwatch(theme: preview)
                    .frame(height: 50)
                    .overlay {
                        if choice == .custom {
                            Image(systemName: "slider.horizontal.3")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(5)
                                .background(.regularMaterial, in: Circle())
                        }
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2.5)
                    }
                Text(verbatim: title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("themeTile-" + {
            switch choice {
            case .system: "system"
            case .preset(let preset): preset.rawValue
            case .custom: "custom"
            }
        }())
    }
}

/// A hue picker: a spectrum track with a draggable knob. Keyboard (arrows) and
/// VoiceOver (adjustable) change the hue in 5° steps.
struct HueSlider: View {
    @Binding var hue: Double
    let label: String
    @FocusState private var isFocused: Bool

    private static let spectrum = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        Color(hue: $0, saturation: 0.75, brightness: 0.95)
    }

    var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 18
            let travel = max(1, geometry.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: Self.spectrum, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                    .padding(.horizontal, knob / 2)
                Circle()
                    .fill(Color(hue: hue, saturation: 0.75, brightness: 0.95))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .overlay(Circle().strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.black.opacity(0.18)),
                                                   lineWidth: isFocused ? 2 : 0.5).padding(-1.5))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: hue * travel)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                hue = min(max((value.location.x - knob / 2) / travel, 0), 0.9999)
            })
        }
        .frame(height: 22)
        .frame(minWidth: 120)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text("\(Int((hue * 360).rounded())) degrees"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ direction: Double) {
        hue = ThemeGradient.normalizedHue(hue + direction * 5 / 360)
    }
}
