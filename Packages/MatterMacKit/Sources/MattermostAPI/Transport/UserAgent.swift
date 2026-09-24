import Foundation

/// The `User-Agent` MatterMac sends: `MatterMac/<version> (Macintosh; macOS)`.
///
/// Mattermost treats a User-Agent containing `Mobile`, `Android`, `iOS`, `iPhone` or
/// `iPad` as a mobile client (mobile session length and semantics;
/// `channels/utils/utils.go IsMobileRequest`). None of those tokens may appear.
public enum UserAgent {
    public static let fallbackVersion = "0.1"
    static let forbiddenTokens = ["mobile", "android", "ios", "iphone", "ipad"]

    /// Built from `CFBundleShortVersionString` of the main bundle, else `0.1`.
    public static let standard: String = make(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    public static func make(version rawVersion: String?) -> String {
        let version = sanitize(rawVersion) ?? fallbackVersion
        return "MatterMac/\(version) (Macintosh; macOS)"
    }

    /// Keeps a conservative version alphabet so a bundle value can never inject
    /// header syntax or a mobile token.
    static func sanitize(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 32,
              raw.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e || $0 == 0x2d
                  || ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x41 && $0 <= 0x5a) })
        else { return nil }
        let lower = raw.lowercased()
        if forbiddenTokens.contains(where: { lower.contains($0) }) { return nil }
        return raw
    }

    /// Whether `value` would make Mattermost classify the request as mobile.
    public static func containsMobileToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return forbiddenTokens.contains { lower.contains($0) }
    }
}
