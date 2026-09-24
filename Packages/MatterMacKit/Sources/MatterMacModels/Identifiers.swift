import Foundation

/// A Mattermost entity identifier.
///
/// Mattermost IDs are opaque strings (currently 26 lowercase base32 characters, but
/// clients must not rely on that). Because identifiers are interpolated into REST
/// path components, construction validates a conservative, path-safe alphabet and a
/// length bound; anything else is rejected as malformed identity rather than
/// escaped and sent.
public protocol MattermostIdentifier: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible, Comparable where RawValue == String
{
    init(unchecked rawValue: String)
}

public enum IdentifierValidation {
    /// Upper bound for any identifier we accept from a server or construct locally.
    public static let maximumLength = 64

    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "-"):
                continue
            default:
                return false
            }
        }
        return true
    }
}

extension MattermostIdentifier {
    public init?(rawValue: String) {
        guard IdentifierValidation.isValid(rawValue) else { return nil }
        self.init(unchecked: rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid \(Self.self) identifier")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct UserID: MattermostIdentifier {
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

public struct TeamID: MattermostIdentifier {
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

public struct ChannelID: MattermostIdentifier {
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

public struct PostID: MattermostIdentifier {
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

public struct FileID: MattermostIdentifier {
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// Identifies one in-memory server session slot. Generated locally when the user
/// adds a server in this running process; never persisted and never sent to a server.
public struct ServerSlotID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "slot-\(rawValue)" }
}

/// The namespace for all session state: one authenticated account on one server slot.
/// Every cache, window, draft, and pending operation is keyed by (at least) a scope so
/// data from one account can never be rendered in another account's context.
public struct AccountScope: Hashable, Sendable, CustomStringConvertible {
    public let server: ServerSlotID
    public let user: UserID

    public init(server: ServerSlotID, user: UserID) {
        self.server = server
        self.user = user
    }

    public var description: String { "\(server)/\(user.rawValue.prefix(6))…" }
}

/// Client-generated `pending_post_id` for one logical send.
///
/// Format matches the official web client: `<user_id>:<unix-ms>`; the server treats
/// it as an opaque deduplication key within a short cache window only.
public struct PendingPostID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(user: UserID, milliseconds: Int64) {
        self.rawValue = "\(user.rawValue):\(milliseconds)"
    }

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 128,
              rawValue.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f })
        else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
