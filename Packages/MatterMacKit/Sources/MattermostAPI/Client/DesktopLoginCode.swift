/// Single-use server code from the desktop SSO handoff, not an API bearer token.
public struct DesktopLoginCode: Sendable, CustomStringConvertible, CustomReflectable {
    let value: String
    public init?(_ value: String) {
        guard value.utf8.count == 64, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        self.value = value
    }
    public var description: String { "DesktopLoginCode(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
