import Foundation

/// Maps HTTP status codes to `APIError` (SPEC §8 "Compatibility contract").
///
/// Only the machine-readable part of a Mattermost `AppError` body is kept
/// (`ServerErrorInfo`); `message` and `detailed_error` are never read into memory
/// beyond the bounded error body and never surfaced.
public enum HTTPStatusMapping {
    /// `nil` for 2xx responses.
    public static func error(for response: HTTPResponse) -> APIError? {
        let status = response.statusCode
        if (200..<300).contains(status) { return nil }
        switch status {
        case 429:
            // The limiter's 429 body is plain text ("limit exceeded"), not JSON.
            return .rateLimited(retryAfterSeconds: retryAfterSeconds(response.headers))
        case 400, 401, 403, 404, 413, 500...599:
            let info = errorInfo(response)
            switch status {
            case 400: return .badRequest(info)
            case 401: return .unauthorized(info)
            case 403: return .forbidden(info)
            case 404: return .notFound(info)
            case 413: return .payloadTooLarge(info)
            case 501: return .notImplemented(info)
            default: return .server(info)
            }
        default:
            return .unexpectedStatus(status)
        }
    }

    static func errorInfo(_ response: HTTPResponse) -> ServerErrorInfo {
        let parsed = response.bodyDiscarded
            ? ServerErrorInfo(id: "", statusCode: response.statusCode, requestID: nil)
            : ServerErrorInfo.parse(response.body, status: response.statusCode)
        // The body's status_code is informational; the HTTP status is authoritative.
        let requestID = parsed.requestID ?? sanitizedRequestID(response.headers["X-Request-Id"])
        return ServerErrorInfo(id: parsed.id, statusCode: response.statusCode, requestID: requestID)
    }

    /// Mattermost request ids are 26 lowercase alphanumerics; accept a conservative
    /// alphabet only so a hostile header cannot smuggle content into error values.
    static func sanitizedRequestID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty, first.utf8.count <= 64,
              first.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x41 && $0 <= 0x5a) })
        else { return nil }
        return first
    }

    /// Longest wait we accept from a server hint (one day); larger values are clamped.
    public static let maximumRetryAfterSeconds = 86_400

    /// Seconds to wait from `Retry-After` and/or `X-RateLimit-Reset`.
    ///
    /// Mattermost adds limiter headers with `Header().Add`, so a response that passed
    /// both the global and the per-route limiter carries two values per header, which
    /// Foundation joins with ", ". Every integer value of both headers is considered
    /// and the most restrictive (largest) one wins. HTTP-date forms are ignored (the
    /// server only emits integer seconds).
    public static func retryAfterSeconds(_ headers: HTTPHeaders) -> Int? {
        var best: Int?
        for name in ["Retry-After", "X-RateLimit-Reset"] {
            for value in headers.values(for: name) {
                for part in value.split(separator: ",") {
                    let token = part.trimmingCharacters(in: .whitespaces)
                    guard !token.isEmpty, token.utf8.count <= 12, token.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                          let seconds = Int(token)
                    else { continue }
                    let clamped = min(seconds, maximumRetryAfterSeconds)
                    best = max(best ?? clamped, clamped)
                }
            }
        }
        return best
    }
}
