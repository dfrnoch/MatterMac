public import Foundation

/// A size- and depth-bounded JSON value for the few places that must inspect
/// arbitrary server JSON (plugin props, unknown realtime events). Never used to
/// retain a raw response; callers extract what they need and drop the tree.
public enum BoundedJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BoundedJSON])
    case object([String: BoundedJSON])

    public struct Limits: Hashable, Sendable {
        public var maximumDepth: Int
        public var maximumNodes: Int
        public var maximumStringBytes: Int
        public init(maximumDepth: Int = 8, maximumNodes: Int = 2_048, maximumStringBytes: Int = 64 * 1_024) {
            self.maximumDepth = maximumDepth
            self.maximumNodes = maximumNodes
            self.maximumStringBytes = maximumStringBytes
        }
        public static let standard = Limits()
    }

    public enum LimitError: Error, Sendable, Hashable {
        case tooDeep, tooManyNodes, stringTooLong, notJSON
    }

    /// Converts a `JSONSerialization` result, enforcing limits.
    public static func from(_ any: Any, limits: Limits = .standard) throws(LimitError) -> BoundedJSON {
        var nodes = 0
        return try convert(any, depth: 0, nodes: &nodes, limits: limits)
    }

    public static func parse(_ data: Data, limits: Limits = .standard) throws(LimitError) -> BoundedJSON {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw .notJSON
        }
        return try from(object, limits: limits)
    }

    private static func convert(_ any: Any, depth: Int, nodes: inout Int, limits: Limits) throws(LimitError) -> BoundedJSON {
        nodes += 1
        guard nodes <= limits.maximumNodes else { throw .tooManyNodes }
        guard depth <= limits.maximumDepth else { throw .tooDeep }
        switch any {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let string as String:
            guard string.utf8.count <= limits.maximumStringBytes else { throw .stringTooLong }
            return .string(string)
        case let array as [Any]:
            var out: [BoundedJSON] = []
            out.reserveCapacity(min(array.count, limits.maximumNodes))
            for element in array { out.append(try convert(element, depth: depth + 1, nodes: &nodes, limits: limits)) }
            return .array(out)
        case let dictionary as [String: Any]:
            var out: [String: BoundedJSON] = [:]
            for (key, value) in dictionary {
                guard key.utf8.count <= 256 else { throw .stringTooLong }
                out[key] = try convert(value, depth: depth + 1, nodes: &nodes, limits: limits)
            }
            return .object(out)
        default:
            return .null
        }
    }

    public subscript(key: String) -> BoundedJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): value == "true" ? true : (value == "false" ? false : nil)
        default: nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .number(let value): value.isFinite && abs(value) < 9.0e15 ? Int64(value) : nil
        case .string(let value): Int64(value)
        default: nil
        }
    }

    public var arrayValue: [BoundedJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: BoundedJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
