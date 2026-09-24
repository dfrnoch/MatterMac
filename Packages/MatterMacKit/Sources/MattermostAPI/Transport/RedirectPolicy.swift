public import Foundation
public import MatterMacModels

/// Decides whether an HTTP redirect may be followed (SPEC §8, §18).
///
/// A redirect is followed only when the target stays inside the server scope: the
/// same origin (scheme, host, port) *and* the endpoint's base path
/// (`ServerEndpoint.contains`). Everything else is refused, so a bearer token that
/// URLSession would copy onto the redirected request can never reach another origin,
/// another scheme (including an https → http downgrade), or a sibling application
/// on the same host. A redirect that would silently turn a write into a `GET`
/// (301/302/303 on POST/PUT/DELETE) is refused as well.
public enum RedirectPolicy {
    public enum Decision: Sendable, Hashable {
        case follow
        case refuse
    }

    public static func evaluate(originalMethod: HTTPMethod, originalURL: URL?, redirectMethod: String?, redirectURL: URL?,
                                scope: ServerEndpoint) -> Decision {
        guard let redirectURL, let originalURL else { return .refuse }
        guard scope.contains(originalURL), scope.contains(redirectURL) else { return .refuse }
        // Userinfo in a Location header is never legitimate for this API.
        if redirectURL.user != nil || redirectURL.password != nil { return .refuse }
        // `ServerEndpoint.contains` compares path components without resolving dot
        // segments, so `/company/chat/../other` would pass it while escaping the
        // subpath once a proxy normalizes it. Refuse any dot segment (raw or %2E).
        if hasDotSegment(redirectURL) { return .refuse }
        let newMethod = (redirectMethod ?? originalMethod.rawValue).uppercased()
        if !originalMethod.isSafe, newMethod != originalMethod.rawValue { return .refuse }
        return .follow
    }

    static func hasDotSegment(_ url: URL) -> Bool {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        for segment in raw.split(separator: "/", omittingEmptySubsequences: false) {
            let decoded = String(segment).removingPercentEncoding ?? String(segment)
            if decoded == "." || decoded == ".." { return true }
        }
        return false
    }
}
