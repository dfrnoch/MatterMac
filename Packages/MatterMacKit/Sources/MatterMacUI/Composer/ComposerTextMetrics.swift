import Foundation

/// Sizes of a piece of composer text in the three units that matter:
/// - `utf8`: the unsent-text budget unit (`Draft.byteCost` is `text.utf8.count`),
/// - `scalars`: the server's message-length unit (Mattermost counts runes, which
///   equals Swift `unicodeScalars.count`),
/// - `utf16`: AppKit's range unit, used to detect drift against the text storage.
///
/// The composer keeps a running total and updates it from the (small) replaced and
/// inserted fragments of each edit, so a keystroke never rescans the whole draft.
nonisolated struct ComposerTextMetrics: Hashable, Sendable {
    var utf8 = 0
    var scalars = 0
    var utf16 = 0

    static let zero = ComposerTextMetrics()

    init() {}

    init(utf8: Int, scalars: Int, utf16: Int) {
        self.utf8 = utf8
        self.scalars = scalars
        self.utf16 = utf16
    }

    init(_ text: some StringProtocol) {
        var utf8 = 0
        var scalars = 0
        var utf16 = 0
        for scalar in text.unicodeScalars {
            scalars += 1
            utf8 += UTF8.width(scalar)
            utf16 += UTF16.width(scalar)
        }
        self.init(utf8: utf8, scalars: scalars, utf16: utf16)
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(utf8: lhs.utf8 + rhs.utf8, scalars: lhs.scalars + rhs.scalars, utf16: lhs.utf16 + rhs.utf16)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(utf8: lhs.utf8 - rhs.utf8, scalars: lhs.scalars - rhs.scalars, utf16: lhs.utf16 - rhs.utf16)
    }

    static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// Character-counter presentation for the server message limit (SPEC §11: show
/// which limit was reached; never truncate).
nonisolated enum ComposerLengthState: Hashable, Sendable {
    /// No limit known, or comfortably below it.
    case hidden
    /// Above 90% of the limit: show "count / limit".
    case nearLimit(count: Int, limit: Int)
    /// Over the limit: show the count, explain, and block sending.
    case exceeded(count: Int, limit: Int)

    /// Fraction of the limit above which the counter appears.
    static let visibleFractionNumerator = 9
    static let visibleFractionDenominator = 10

    init(scalarCount count: Int, limit: Int?) {
        guard let limit, limit > 0 else {
            self = .hidden
            return
        }
        if count > limit {
            self = .exceeded(count: count, limit: limit)
        } else if count * Self.visibleFractionDenominator > limit * Self.visibleFractionNumerator {
            self = .nearLimit(count: count, limit: limit)
        } else {
            self = .hidden
        }
    }

    var blocksSending: Bool {
        if case .exceeded = self { return true }
        return false
    }
}
