public import Foundation
import MatterMacModels

// Tolerant decoding helpers for Mattermost wire JSON.
//
// Policy (SPEC §9): unknown fields are ignored and not retained; missing optional
// fields decode to defaults; unknown enum values map to `.unknown`; but missing or
// malformed *identity* (ids) fails decoding of that entity.

struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer {
    /// Decodes a string, accepting numbers and booleans rendered as strings by some
    /// server versions. Returns `nil` for missing, null, or non-scalar values.
    func lenientString(_ key: Key, maxBytes: Int = 1 << 20) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value.utf8.count <= maxBytes ? value : String(decoding: value.utf8.prefix(maxBytes), as: UTF8.self)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? "true" : "false" }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0", "": return false
            default: return nil
            }
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value != 0 }
        return nil
    }

    func lenientInt64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite, abs(value) < 9.0e18 {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    func timestamp(_ key: Key) -> MattermostTimestamp {
        MattermostTimestamp(milliseconds: lenientInt64(key) ?? 0)
    }

    /// Required identifier: throws if missing or invalid.
    func requiredID<ID: MattermostIdentifier>(_ type: ID.Type, _ key: Key) throws -> ID {
        let raw = try decode(String.self, forKey: key)
        guard let id = ID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "invalid identifier")
        }
        return id
    }

    /// Optional identifier: empty string or missing → nil; malformed non-empty → nil
    /// (for non-authorization-critical references such as `root_id` on display).
    func optionalID<ID: MattermostIdentifier>(_ type: ID.Type, _ key: Key) -> ID? {
        guard let raw = try? decodeIfPresent(String.self, forKey: key), !raw.isEmpty else { return nil }
        return ID(rawValue: raw)
    }

    func idList<ID: MattermostIdentifier>(_ type: ID.Type, _ key: Key, limit: Int) -> [ID] {
        guard let raw = try? decodeIfPresent([String].self, forKey: key) else { return [] }
        return raw.prefix(limit).compactMap { ID(rawValue: $0) }
    }
}

/// A decoded JSON array that tolerates individual malformed elements: bad elements
/// are skipped (and counted) instead of failing the whole list.
public struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    public var elements: [Element]
    public var skipped: Int

    public init(elements: [Element], skipped: Int = 0) {
        self.elements = elements
        self.skipped = skipped
    }

    private struct Skip: Decodable {}

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skipped = 0
        if let count = container.count { elements.reserveCapacity(min(count, 10_000)) }
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                skipped += 1
                _ = try? container.decode(Skip.self)
            }
        }
        self.elements = elements
        self.skipped = skipped
    }
}

/// Shared decoder configuration. JSON numbers are decoded exactly; no key strategy
/// (Mattermost uses explicit snake_case keys that DTOs spell out).
public enum WireJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = false
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}
