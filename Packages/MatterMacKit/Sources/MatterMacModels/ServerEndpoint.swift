public import Foundation

/// A normalized Mattermost server base: scheme + host + optional port + optional
/// reverse-proxy subpath. All REST, WebSocket, file, and permalink URLs are built
/// from path *components* appended to this base; user input is never concatenated
/// into an endpoint path.
public struct ServerEndpoint: Hashable, Sendable, CustomStringConvertible {
    public enum Scheme: String, Sendable, Hashable {
        case https
        /// Allowed only for loopback hosts behind the explicit development setting.
        case http
    }

    public let scheme: Scheme
    /// Lowercased host (IDNA as provided by URLComponents).
    public let host: String
    public let port: Int?
    /// Path segments of the subpath, e.g. `["company", "chat"]` for
    /// `https://chat.example.org/company/chat`. Empty for root deployments.
    public let pathSegments: [String]

    public init(scheme: Scheme, host: String, port: Int?, pathSegments: [String]) {
        self.scheme = scheme
        self.host = host.lowercased()
        self.port = port
        self.pathSegments = pathSegments
    }

    /// Canonical base URL without a trailing slash.
    public var baseURL: URL { url(path: []) }

    /// The origin (scheme://host[:port]) used for credential scoping decisions.
    public var origin: Origin { Origin(scheme: scheme.rawValue, host: host, port: effectivePort) }

    public var effectivePort: Int { port ?? (scheme == .https ? 443 : 80) }

    public var isLoopback: Bool { Self.isLoopbackHost(host) }

    public var description: String { baseURL.absoluteString }

    /// Builds `<base>/<segments...>` with each segment percent-encoded as a single
    /// path component (so `/`, `?`, `#`, and `..` in a segment cannot escape it).
    public func url(path segments: [String], query: [URLQueryItem] = []) -> URL {
        url(path: segments, query: query, schemeOverride: nil)
    }

    /// WebSocket URL (`ws`/`wss`) for a REST-relative path.
    public func webSocketURL(path segments: [String], query: [URLQueryItem] = []) -> URL {
        url(path: segments, query: query, schemeOverride: scheme == .https ? "wss" : "ws")
    }

    private func url(path segments: [String], query: [URLQueryItem], schemeOverride: String?) -> URL {
        var components = URLComponents()
        components.scheme = schemeOverride ?? scheme.rawValue
        // IPv6 literals must be bracketed in a URL authority.
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        let all = pathSegments + segments
        components.percentEncodedPath = all.isEmpty
            ? ""
            : "/" + all.map(Self.encodePathSegment).joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves '+' unescaped in queries; servers decode it as space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else {
            preconditionFailure("ServerEndpoint produced an invalid URL")
        }
        return url
    }

    static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#;%")
        return set
    }()

    static func encodePathSegment(_ segment: String) -> String {
        // "." and ".." are encoded so they cannot be interpreted as dot-segments.
        if segment == "." { return "%2E" }
        if segment == ".." { return "%2E%2E" }
        return segment.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? ""
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower == "[::1]"
            || lower.hasSuffix(".localhost")
    }

    /// Whether `url` lives under this server's base (same origin and subpath prefix).
    public func contains(_ url: URL) -> Bool {
        guard let origin = Origin(url: url), origin == self.origin else { return false }
        let segments = url.pathComponents.filter { $0 != "/" }
        return segments.starts(with: pathSegments)
    }
}

/// A scheme/host/port triple for same-origin credential checks.
public struct Origin: Hashable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port: Int
        if let explicit = url.port {
            port = explicit
        } else {
            switch scheme {
            case "https", "wss": port = 443
            case "http", "ws": port = 80
            default: return nil
            }
        }
        // Treat ws/wss as the same origin as http/https for credential scoping.
        let normalized = switch scheme {
        case "wss": "https"
        case "ws": "http"
        default: scheme
        }
        self.init(scheme: normalized, host: host, port: port)
    }

    public var description: String { "\(scheme)://\(host):\(port)" }
}

public enum ServerURLError: Error, Hashable, Sendable {
    case empty
    case malformed
    case unsupportedScheme(String)
    case embeddedCredentials
    case missingHost
    case queryOrFragmentNotAllowed
    /// Plain HTTP is only accepted for loopback hosts with the development setting on.
    case insecureTransportNotAllowed
    case invalidPort
}

public enum ServerURLNormalizer {
    /// Normalizes user input into a `ServerEndpoint`.
    ///
    /// - Adds `https://` when no scheme is given.
    /// - Preserves a reverse-proxy subpath; strips a trailing slash and a trailing
    ///   `/login` or web-app route only if it is exactly that (never guesses deeper).
    /// - Rejects embedded credentials, non-http(s) schemes, queries, and fragments.
    /// - Rejects `http` unless the host is loopback and `allowInsecureLoopback` is set.
    public static func normalize(_ input: String, allowInsecureLoopback: Bool) throws(ServerURLError) -> ServerEndpoint {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value >= 0x20 })
        else { throw .malformed }

        let lower = trimmed.lowercased()
        let withScheme: String
        if let schemeEnd = lower.range(of: "://") {
            let scheme = String(lower[lower.startIndex..<schemeEnd.lowerBound])
            guard scheme == "https" || scheme == "http" else { throw .unsupportedScheme(String(scheme.prefix(16))) }
            withScheme = trimmed
        } else if lower.contains(":"), !lower.contains("."), !lower.hasPrefix("localhost"), !lower.hasPrefix("[") {
            // e.g. "mailto:x" or "javascript:..." – a scheme without "//".
            let scheme = lower.split(separator: ":").first.map(String.init) ?? ""
            throw .unsupportedScheme(String(scheme.prefix(16)))
        } else {
            withScheme = "https://" + trimmed
        }

        guard let components = URLComponents(string: withScheme) else { throw .malformed }
        if components.user != nil || components.password != nil { throw .embeddedCredentials }
        if components.query != nil || components.fragment != nil { throw .queryOrFragmentNotAllowed }
        guard let rawScheme = components.scheme?.lowercased(), let scheme = ServerEndpoint.Scheme(rawValue: rawScheme)
        else { throw .unsupportedScheme(components.scheme ?? "") }
        guard var host = components.host, !host.isEmpty else { throw .missingHost }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let port = components.port, !(1...65_535).contains(port) { throw .invalidPort }

        if scheme == .http {
            guard allowInsecureLoopback, ServerEndpoint.isLoopbackHost(host) else { throw .insecureTransportNotAllowed }
        }

        var segments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        if segments.contains(where: { $0 == "." || $0 == ".." }) { throw .malformed }
        // Users often paste the login page URL. Only strip exact, well-known leaf routes.
        if let last = segments.last?.lowercased(), last == "login" || last == "signup_email" {
            segments.removeLast()
        }

        return ServerEndpoint(scheme: scheme, host: host, port: components.port, pathSegments: segments)
    }
}
