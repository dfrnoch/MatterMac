/// A parsed Mattermost server version (`11.11.1`, or the `X-Version-Id` header form
/// `11.11.1.<build>.<hash>.<enterprise>`).
public struct ServerVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        let parts = raw.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = Int(parts[2].prefix(while: \.isNumber)),
              (0...999).contains(major), (0...999).contains(minor), (0...9_999).contains(patch)
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Whether collapsed reply threads are available, per server `CollapsedThreads` config.
public enum CollapsedThreadsMode: Hashable, Sendable {
    case disabled
    case defaultOn
    case defaultOff
    case alwaysOn
    case unknown

    public init(config: String?) {
        switch config {
        case "disabled": self = .disabled
        case "default_on": self = .defaultOn
        case "default_off": self = .defaultOff
        case "always_on": self = .alwaysOn
        default: self = .unknown
        }
    }
}

/// Login methods the server *advertises*. Advertised is not the same as supported by
/// MatterMac: see `LoginMethodSupport`.
public struct LoginOptions: Hashable, Sendable {
    public var email: Bool
    public var username: Bool
    public var ldap: Bool
    public var ldapFieldName: String
    public var gitlab: Bool
    public var google: Bool
    public var office365: Bool
    public var openID: Bool
    public var saml: Bool
    public var ssoProviderLabels: [SSOProvider: String]
    public var passwordMinimumLength: Int?

    public init(email: Bool = false, username: Bool = false, ldap: Bool = false, ldapFieldName: String = "",
                gitlab: Bool = false, google: Bool = false, office365: Bool = false, openID: Bool = false,
                saml: Bool = false, passwordMinimumLength: Int? = nil, ssoProviderLabels: [SSOProvider: String] = [:]) {
        self.email = email
        self.username = username
        self.ldap = ldap
        self.ldapFieldName = ldapFieldName
        self.gitlab = gitlab
        self.google = google
        self.office365 = office365
        self.openID = openID
        self.saml = saml
        self.ssoProviderLabels = ssoProviderLabels
        self.passwordMinimumLength = passwordMinimumLength
    }

    public func displayName(for provider: SSOProvider) -> String {
        ssoProviderLabels[provider] ?? provider.displayName
    }

    public var passwordLoginAvailable: Bool { email || username || ldap }
    public var anySSOAdvertised: Bool { gitlab || google || office365 || openID || saml }
}

/// What the server told us before and after login. Unknown values stay `nil`;
/// unknown is never treated as permission granted.
public struct ServerCapabilities: Hashable, Sendable {
    public var version: ServerVersion?
    public var buildNumber: String
    public var siteName: String
    public var login: LoginOptions
    // Available only after authentication (full client config):
    public var collapsedThreads: CollapsedThreadsMode
    public var maximumFileSize: Int64?
    public var maximumPostCharacters: Int?
    public var fileAttachmentsEnabled: Bool?
    public var customEmojiEnabled: Bool?
    public var personalAccessTokensEnabled: Bool?
    public var postEditTimeLimitSeconds: Int?
    public var uniqueReactionLimitPerPost: Int?
    public var experimentalTownSquareReadOnly: Bool?
    /// `HasImageProxy`: external images can be fetched through `/api/v4/image`.
    public var hasImageProxy: Bool?
    /// `EnableLinkPreviews`: the server generates website previews.
    public var linkPreviewsEnabled: Bool?

    public init(version: ServerVersion? = nil, buildNumber: String = "", siteName: String = "",
                login: LoginOptions = LoginOptions(), collapsedThreads: CollapsedThreadsMode = .unknown,
                maximumFileSize: Int64? = nil, maximumPostCharacters: Int? = nil,
                fileAttachmentsEnabled: Bool? = nil, customEmojiEnabled: Bool? = nil,
                personalAccessTokensEnabled: Bool? = nil, postEditTimeLimitSeconds: Int? = nil,
                uniqueReactionLimitPerPost: Int? = nil, experimentalTownSquareReadOnly: Bool? = nil) {
        self.version = version
        self.buildNumber = buildNumber
        self.siteName = siteName
        self.login = login
        self.collapsedThreads = collapsedThreads
        self.maximumFileSize = maximumFileSize
        self.maximumPostCharacters = maximumPostCharacters
        self.fileAttachmentsEnabled = fileAttachmentsEnabled
        self.customEmojiEnabled = customEmojiEnabled
        self.personalAccessTokensEnabled = personalAccessTokensEnabled
        self.postEditTimeLimitSeconds = postEditTimeLimitSeconds
        self.uniqueReactionLimitPerPost = uniqueReactionLimitPerPost
        self.experimentalTownSquareReadOnly = experimentalTownSquareReadOnly
    }

    /// Release lines MatterMac has actually been exercised against (docs/compatibility.md).
    public static let testedReleaseLines: [(major: Int, minor: Int)] = [(11, 11), (10, 11)]

    public var isTestedReleaseLine: Bool {
        guard let version else { return false }
        return Self.testedReleaseLines.contains { $0.major == version.major && $0.minor == version.minor }
    }
}

/// Native login flows implemented by MatterMac and whether each is usable here.
public enum LoginMethodSupport: Hashable, Sendable {
    case password
    case personalAccessToken
    /// Server-advertised provider using the desktop browser handoff.
    case browserSSO(SSOProvider)
}

/// Browser providers supported by Mattermost's desktop sign-in routes. The IdP
/// behind OpenID Connect or SAML (e.g. Keycloak) is configured by the server.
public enum SSOProvider: String, CaseIterable, Hashable, Sendable {
    case openID = "openid", saml, google, office365, gitlab
    public var displayName: String {
        switch self {
        case .openID: "OpenID Connect"
        case .saml: "SAML"
        case .google: "Google"
        case .office365: "Microsoft Entra ID"
        case .gitlab: "GitLab"
        }
    }
}
