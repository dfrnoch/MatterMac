/// A Mattermost session token or user-supplied personal access token. The app saves
/// verified credentials through KeychainAccounts; other runtime copies stay in memory.
///
/// `description`, `debugDescription`, and reflection are redacted so the value cannot
/// leak through string interpolation, `dump`, or error descriptions. Swift strings may
/// have transient copies; resetting this value is **not** secure zeroization.
public struct BearerCredential: Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public enum Kind: Sendable, Hashable {
        /// Session token from `POST /api/v4/users/login` (`Token` response header).
        case session
        /// Personal access token supplied by the user. Discarding it locally does not
        /// revoke it on the server.
        case personalAccessToken
    }

    public let kind: Kind
    private let secret: String

    public init?(token: String, kind: Kind) {
        // Mattermost tokens are 26 lowercase alphanumerics; accept a conservative
        // header-safe alphabet so a token can never inject header syntax.
        guard !token.isEmpty, token.utf8.count <= 256,
              token.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                      || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
              })
        else { return nil }
        self.secret = token
        self.kind = kind
    }

    /// The `Authorization` header value. The only accessor for the secret.
    public var authorizationHeaderValue: String { "Bearer \(secret)" }

    public var description: String { "BearerCredential(\(kind), <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["kind": kind]) }
}
