public import Foundation
public import MatterMacModels

// Value types exchanged between the REST client and an `HTTPTransport`. They are
// immutable `Sendable` values; nothing here references URLSession, so tests can
// script transports without a network (TestSupport `FakeHTTPTransport`).

public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case head = "HEAD"

    /// Safe (read-only) methods. Only these are ever retried or coalesced.
    public var isSafe: Bool { self == .get || self == .head }
}

/// An ordered header list with case-insensitive lookup (RFC 9110 §5.1). Multiple
/// fields with the same name are preserved; `self[name]` joins them with ", " the
/// way Foundation does for received headers.
public struct HTTPHeaders: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    public struct Field: Sendable, Hashable {
        public let name: String
        public let value: String
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    private var fields: [Field]

    public init() { fields = [] }

    public init(_ fields: [Field]) { self.fields = fields }

    public init(dictionaryLiteral elements: (String, String)...) {
        fields = elements.map { Field(name: $0.0, value: $0.1) }
    }

    /// Converts `HTTPURLResponse.allHeaderFields`, which may contain non-string keys.
    public init(response: HTTPURLResponse) {
        var fields: [Field] = []
        fields.reserveCapacity(Swift.min(response.allHeaderFields.count, 128))
        for (key, value) in response.allHeaderFields.prefix(128) {
            guard let name = key as? String, let value = value as? String else { continue }
            fields.append(Field(name: name, value: value))
        }
        self.fields = fields
    }

    public var count: Int { fields.count }

    public func makeIterator() -> IndexingIterator<[Field]> { fields.makeIterator() }

    /// Case-insensitive lookup; multiple values joined with ", ".
    public subscript(name: String) -> String? {
        let values = self.values(for: name)
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    public func values(for name: String) -> [String] {
        fields.filter { Self.namesEqual($0.name, name) }.map(\.value)
    }

    public func contains(_ name: String) -> Bool { fields.contains { Self.namesEqual($0.name, name) } }

    /// Replaces every field named `name` (case-insensitively) with one value.
    public mutating func set(_ name: String, _ value: String) {
        remove(name)
        fields.append(Field(name: name, value: value))
    }

    public mutating func add(_ name: String, _ value: String) {
        fields.append(Field(name: name, value: value))
    }

    public mutating func remove(_ name: String) {
        fields.removeAll { Self.namesEqual($0.name, name) }
    }

    static func namesEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.count == rhs.utf8.count && lhs.lowercased() == rhs.lowercased()
    }
}

/// One HTTP request to a Mattermost server.
///
/// `credential` is attached as `Authorization: Bearer …` by the transport, and only
/// when `url` lies inside the transport's `ServerEndpoint` scope (same origin and
/// subpath); requests never carry cookies.
public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    /// Request-specific headers (e.g. `Content-Type`). `Authorization`, `Cookie`,
    /// `User-Agent` and `X-Requested-With` are controlled by the transport and any
    /// value supplied here for them is ignored.
    public var headers: HTTPHeaders
    public var body: Data?
    public var credential: BearerCredential?
    /// Idle timeout for this request (`URLRequest.timeoutInterval`).
    public var allowsRedirects: Bool
    public var timeout: TimeInterval

    public init(method: HTTPMethod, url: URL, headers: HTTPHeaders = HTTPHeaders(), body: Data? = nil,
                credential: BearerCredential? = nil, timeout: TimeInterval = HTTPRequest.defaultTimeout, allowsRedirects: Bool = true) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.credential = credential
        self.timeout = timeout
        self.allowsRedirects = allowsRedirects
    }

    public static let defaultTimeout: TimeInterval = 30
    /// Idle timeout for attachment uploads and downloads.
    public static let transferTimeout: TimeInterval = 120
}

/// A received response. Non-2xx responses are *returned*, not thrown, by the
/// transport; the client maps them with `HTTPStatusMapping`.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: HTTPHeaders
    /// The (bounded) body. Empty for downloads, whose body is written to a file.
    public let body: Data
    /// `true` when a non-2xx body exceeded the error-body limit and was dropped
    /// (only the status and headers are meaningful then).
    public let bodyDiscarded: Bool

    public init(statusCode: Int, headers: HTTPHeaders = HTTPHeaders(), body: Data = Data(), bodyDiscarded: Bool = false) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyDiscarded = bodyDiscarded
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Lowercased media type without parameters, e.g. `image/png`.
    public var mediaType: String? {
        guard let raw = headers["Content-Type"] else { return nil }
        let type = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        let trimmed = type.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Byte bounds applied while a response body is being received (SPEC §9, §15).
public struct ResponseLimits: Sendable, Hashable {
    /// Maximum bytes accepted for a 2xx body (post-decompression). For downloads
    /// this bounds the bytes written to the destination file.
    public var maximumBodyBytes: Int64
    /// Non-2xx bodies are read up to this size for the machine-readable error id;
    /// larger error bodies are dropped (`HTTPResponse.bodyDiscarded`), not failed.
    public var maximumErrorBodyBytes: Int

    public init(maximumBodyBytes: Int64, maximumErrorBodyBytes: Int = ResponseLimits.defaultErrorBodyBytes) {
        self.maximumBodyBytes = max(0, maximumBodyBytes)
        self.maximumErrorBodyBytes = max(0, maximumErrorBodyBytes)
    }

    public init(maximumBodyBytes: Int) {
        self.init(maximumBodyBytes: Int64(maximumBodyBytes))
    }

    /// `ServerErrorInfo.parse` never looks at more than 64 KiB.
    public static let defaultErrorBodyBytes = 64 * 1_024
}

/// A user-selected file to stream as a raw request body.
public struct UploadFile: Sendable, Hashable {
    public let url: URL
    /// Size the caller observed when the user selected the file. The upload fails
    /// with `.localFileUnavailable` if the file no longer has exactly this size, or
    /// changes while it is being sent.
    public let expectedLength: Int64

    public let expectedRevision: String?

    public init(url: URL, expectedLength: Int64, expectedRevision: String? = nil) {
        self.url = url
        self.expectedLength = expectedLength
        self.expectedRevision = expectedRevision
    }
}
