import Foundation

/// The window theme (Settings › Appearance). `system` keeps the standard macOS look;
/// a preset or a custom gradient tints the window background behind the sidebar,
/// conversation and glass chrome. Saved on this Mac with the other local settings
/// (decision 0035); never sent to the server.
nonisolated public enum AppTheme: Hashable, Sendable {
    case system
    case preset(ThemePreset)
    case custom(ThemeGradient)

    /// The gradient to draw, or `nil` for the standard look.
    public var gradient: ThemeGradient? {
        switch self {
        case .system: nil
        case .preset(let preset): preset.gradient
        case .custom(let gradient): gradient
        }
    }

    public var isSystem: Bool { self == .system }

    /// Derived colors for one appearance, or `nil` for the standard look.
    public func palette(for appearance: RenderAppearance) -> ThemePalette? {
        gradient.map { ThemePalette(gradient: $0, appearance: appearance) }
    }
}

/// Built-in gradients. Raw values are stored; names are shown.
nonisolated public enum ThemePreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case dawn, lagoon, meadow, dusk, ember, aurora, slate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dawn: String(localized: "Dawn")
        case .lagoon: String(localized: "Lagoon")
        case .meadow: String(localized: "Meadow")
        case .dusk: String(localized: "Dusk")
        case .ember: String(localized: "Ember")
        case .aurora: String(localized: "Aurora")
        case .slate: String(localized: "Slate")
        }
    }

    public var gradient: ThemeGradient {
        // Hues in degrees for readability; saturation, brightness, intensity 0…1.
        switch self {
        case .dawn: ThemeGradient(degrees: [22, 345, 280], saturation: 0.62, brightness: 0.6, intensity: 0.72)
        case .lagoon: ThemeGradient(degrees: [178, 212], saturation: 0.66, brightness: 0.55, intensity: 0.72)
        case .meadow: ThemeGradient(degrees: [88, 148], saturation: 0.55, brightness: 0.55, intensity: 0.66)
        case .dusk: ThemeGradient(degrees: [232, 272, 318], saturation: 0.6, brightness: 0.5, intensity: 0.76)
        case .ember: ThemeGradient(degrees: [8, 36], saturation: 0.68, brightness: 0.55, intensity: 0.68)
        case .aurora: ThemeGradient(degrees: [150, 195, 285], saturation: 0.62, brightness: 0.5, intensity: 0.76)
        case .slate: ThemeGradient(degrees: [205, 228], saturation: 0.24, brightness: 0.5, intensity: 0.7)
        }
    }
}

/// A custom gradient: 2–4 hues sharing one saturation, brightness and intensity.
/// Every initializer clamps, so a value always satisfies `isValid`; decoding
/// rejects anything outside the ranges instead of guessing.
nonisolated public struct ThemeGradient: Hashable, Sendable {
    public static let colorCounts = 2...4

    /// Hues in `0..<1`, in gradient order.
    public private(set) var hues: [Double]
    /// Colorfulness of the tint (0 is gray).
    public var saturation: Double { didSet { saturation = Self.unit(saturation) } }
    /// Lighter or deeper surfaces within each appearance's readable range.
    public var brightness: Double { didSet { brightness = Self.unit(brightness) } }
    /// How strongly the tint covers the standard window color (0 is untinted).
    public var intensity: Double { didSet { intensity = Self.unit(intensity) } }

    public init(hues: [Double], saturation: Double, brightness: Double, intensity: Double) {
        var hues = hues.filter(\.isFinite).map(Self.normalizedHue)
        if hues.isEmpty { hues = [0.6] }
        while hues.count < Self.colorCounts.lowerBound { hues.append(Self.normalizedHue(hues[hues.count - 1] + 0.12)) }
        self.hues = Array(hues.prefix(Self.colorCounts.upperBound))
        self.saturation = Self.unit(saturation)
        self.brightness = Self.unit(brightness)
        self.intensity = Self.unit(intensity)
    }

    init(degrees: [Double], saturation: Double, brightness: Double, intensity: Double) {
        self.init(hues: degrees.map { $0 / 360 }, saturation: saturation, brightness: brightness, intensity: intensity)
    }

    /// The starting point for a new custom theme.
    public static let standardCustom = ThemePreset.lagoon.gradient

    public var isValid: Bool {
        Self.colorCounts.contains(hues.count)
            && hues.allSatisfy { $0.isFinite && (0..<1).contains($0) }
            && [saturation, brightness, intensity].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    public var canAddColor: Bool { hues.count < Self.colorCounts.upperBound }
    public var canRemoveColor: Bool { hues.count > Self.colorCounts.lowerBound }

    public mutating func setHue(_ hue: Double, at index: Int) {
        guard hues.indices.contains(index), hue.isFinite else { return }
        hues[index] = Self.normalizedHue(hue)
    }

    /// Adds a hue in the widest gap between the existing ones.
    public mutating func addColor() {
        guard canAddColor else { return }
        let sorted = hues.sorted()
        var best = (start: sorted[0], width: 0.0)
        for (index, hue) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1] : sorted[0] + 1
            if next - hue > best.width { best = (hue, next - hue) }
        }
        hues.append(Self.normalizedHue(best.start + best.width / 2))
    }

    public mutating func removeColor(at index: Int) {
        guard canRemoveColor, hues.indices.contains(index) else { return }
        hues.remove(at: index)
    }

    /// A pleasant random gradient: related hues (an arc of 40°–150°) with moderate
    /// saturation; the brightness stays as the user set it.
    public func randomized(using generator: inout some RandomNumberGenerator) -> ThemeGradient {
        let count = Int.random(in: 2...3, using: &generator)
        let start = Double.random(in: 0..<1, using: &generator)
        let arc = Double.random(in: 40...150, using: &generator) / 360
        let direction: Double = Bool.random(using: &generator) ? 1 : -1
        let hues = (0..<count).map { start + direction * arc * Double($0) / Double(count - 1) }
        return ThemeGradient(hues: hues, saturation: .random(in: 0.45...0.8, using: &generator),
                             brightness: brightness, intensity: .random(in: 0.6...0.9, using: &generator))
    }

    static func normalizedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        let normalized = remainder < 0 ? remainder + 1 : remainder
        return normalized >= 1 ? 0 : normalized
    }

    static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}

// MARK: - Storage format

/// Versioned JSON: `{"version":1,"kind":"system"}`, `{"version":1,"kind":"preset","preset":"dusk"}`
/// or `{"version":1,"kind":"custom","gradient":{...}}`. Decoding throws for an unknown
/// version, kind or preset, and for any out-of-range gradient value.
extension AppTheme: Codable {
    static let storageVersion = 1
    /// Stored data larger than this is ignored without being parsed.
    static let maximumStoredBytes = 1024

    private enum CodingKeys: String, CodingKey { case version, kind, preset, gradient }
    private enum Kind: String, Codable { case system, preset, custom }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.storageVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported version")
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .system: self = .system
        case .preset: self = .preset(try container.decode(ThemePreset.self, forKey: .preset))
        case .custom: self = .custom(try container.decode(ThemeGradient.self, forKey: .gradient))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.storageVersion, forKey: .version)
        switch self {
        case .system:
            try container.encode(Kind.system, forKey: .kind)
        case .preset(let preset):
            try container.encode(Kind.preset, forKey: .kind)
            try container.encode(preset, forKey: .preset)
        case .custom(let gradient):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(gradient, forKey: .gradient)
        }
    }

    /// Compact, stable bytes for `LocalSettingsStorage`.
    func storageData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }

    /// The stored theme, or `nil` when the value is missing, too large or invalid.
    init?(storageData data: Data) {
        guard data.count <= Self.maximumStoredBytes,
              let theme = try? JSONDecoder().decode(AppTheme.self, from: data) else { return nil }
        self = theme
    }
}

extension ThemeGradient: Codable {
    private enum CodingKeys: String, CodingKey { case hues, saturation, brightness, intensity }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hues = try container.decode([Double].self, forKey: .hues)
        let values = try [CodingKeys.saturation, .brightness, .intensity].map { try container.decode(Double.self, forKey: $0) }
        guard Self.colorCounts.contains(hues.count), hues.allSatisfy({ $0.isFinite && (0..<1).contains($0) }),
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .hues, in: container, debugDescription: "Out of range")
        }
        self.init(hues: hues, saturation: values[0], brightness: values[1], intensity: values[2])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hues, forKey: .hues)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(brightness, forKey: .brightness)
        try container.encode(intensity, forKey: .intensity)
    }
}
