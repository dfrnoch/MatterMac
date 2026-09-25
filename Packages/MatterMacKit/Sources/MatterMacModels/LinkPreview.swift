public import Foundation

/// A server-provided preview of the first link in a post (`metadata.embeds`), reduced
/// to what MatterMac renders natively. The server fetched this metadata; MatterMac
/// never contacts the linked site itself. Every string is bounded at decode time.
public struct LinkPreview: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        /// An OpenGraph page summary (title, description, site name, optional image).
        case website
        /// A direct link to an image.
        case image
    }

    public struct Image: Hashable, Sendable, Codable {
        /// Absolute http(s) URL of the image as reported by the server.
        public var url: String
        /// Dimensions from `metadata.images`, when the server measured the image.
        public var width: Int?
        public var height: Int?

        public init(url: String, width: Int? = nil, height: Int? = nil) {
            self.url = url
            self.width = width
            self.height = height
        }
    }

    public static let maximumTitleBytes = 300
    public static let maximumDescriptionBytes = 600
    public static let maximumSiteNameBytes = 100
    public static let maximumURLBytes = SafeLink.maximumLength

    public var kind: Kind
    /// The previewed link; always passes `SafeLink` (http or https).
    public var link: SafeLink
    public var title: String
    public var description: String
    public var siteName: String
    public var image: Image?

    public init(kind: Kind, link: SafeLink, title: String = "", description: String = "", siteName: String = "",
                image: Image? = nil) {
        self.kind = kind
        self.link = link
        self.title = Self.bounded(title, Self.maximumTitleBytes)
        self.description = Self.bounded(description, Self.maximumDescriptionBytes)
        self.siteName = Self.bounded(siteName, Self.maximumSiteNameBytes)
        self.image = image
    }

    /// The link's host, for a card without a site name.
    public var host: String { link.url.host(percentEncoded: false) ?? "" }

    /// Approximate retained bytes (for the post store's cost accounting).
    public var estimatedCost: Int {
        96 + link.url.absoluteString.utf8.count + title.utf8.count + description.utf8.count + siteName.utf8.count
            + (image.map { 32 + $0.url.utf8.count } ?? 0)
    }

    /// Collapses whitespace runs and cuts at a character boundary within `maxBytes`.
    public static func bounded(_ raw: String, _ maxBytes: Int) -> String {
        var out = ""
        var pendingSpace = false
        var bytes = 0
        for character in raw {
            if character.isWhitespace || character.isNewline {
                pendingSpace = !out.isEmpty
                continue
            }
            let piece = pendingSpace ? " " + String(character) : String(character)
            let size = piece.utf8.count
            if bytes + size > maxBytes {
                out += "…"
                break
            }
            out += piece
            bytes += size
            pendingSpace = false
        }
        return out
    }
}

/// A link that points into the signed-in Mattermost server (same origin and subpath).
/// Such links are opened inside MatterMac instead of the browser.
public enum MattermostLink: Hashable, Sendable {
    /// `<server>/<team>/pl/<post id>`.
    case post(team: String, postID: PostID)
    /// `<server>/<team>/channels/<channel name>`.
    case channel(team: String, name: String)
    /// `<server>/<team>/messages/@<username>`.
    case directMessage(team: String, username: String)

    /// Recognizes permalink, channel and direct-message links for `endpoint`. Links to
    /// other servers, other paths, or with malformed components return `nil` (the caller
    /// then treats them as ordinary external links).
    public init?(url: URL, endpoint: ServerEndpoint) {
        guard endpoint.contains(url) else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        let rest = Array(segments.dropFirst(endpoint.pathSegments.count))
        guard rest.count == 3, Self.isTeamName(rest[0]) else { return nil }
        let team = rest[0]
        switch rest[1] {
        case "pl":
            guard rest[2].utf8.count == 26, let id = PostID(rawValue: rest[2]) else { return nil }
            self = .post(team: team, postID: id)
        case "channels":
            guard Self.isChannelName(rest[2]) else { return nil }
            self = .channel(team: team, name: rest[2])
        case "messages":
            guard rest[2].hasPrefix("@") else { return nil }
            let username = String(rest[2].dropFirst()).lowercased()
            guard Self.isUsername(username) else { return nil }
            self = .directMessage(team: team, username: username)
        default:
            return nil
        }
    }

    /// Server team names are `[a-z0-9-_]{1,64}` (plus the web client's `_redirect`).
    static func isTeamName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        }
    }

    /// Channel names are lowercase `[a-z0-9-_]`, up to 64 characters (DMs use `a__b`).
    static func isChannelName(_ value: String) -> Bool { isTeamName(value) }

    static func isUsername(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }
}
