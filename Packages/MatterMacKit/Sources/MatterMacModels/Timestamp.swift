public import Foundation

/// A Mattermost timestamp. The wire unit is Unix epoch **milliseconds**; this type
/// makes the unit explicit so it is never confused with `TimeInterval` seconds.
public struct MattermostTimestamp: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let milliseconds: Int64

    public init(milliseconds: Int64) { self.milliseconds = milliseconds }

    public init(date: Date) {
        self.milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    public static let zero = MattermostTimestamp(milliseconds: 0)

    /// `true` for the server's "not set" sentinel (0).
    public var isZero: Bool { milliseconds == 0 }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.milliseconds < rhs.milliseconds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.milliseconds = try container.decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(milliseconds)
    }

    public var description: String { "\(milliseconds)ms" }
}

/// Wall-clock source used for timestamps shown to or sent to the server.
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}
