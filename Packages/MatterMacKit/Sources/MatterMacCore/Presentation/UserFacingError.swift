/// A typed, content-free error suitable for display. Views map these to localized
/// text; they never show raw server error bodies (which can echo user content).
public enum UserFacingError: Hashable, Sendable, Error {
    case offline
    case timedOut
    case serverUnreachable
    case tlsFailure
    case authenticationRequired
    case invalidCredentials
    case mfaRequired
    case invalidMFACode
    case accountLocked
    case loginMethodDisabled
    case permissionDenied
    case notFoundOrInaccessible
    case rateLimited(retryAfterSeconds: Int?)
    case payloadTooLarge(limitBytes: Int)
    case messageTooLong(limitCharacters: Int)
    case unsupportedCapability(String)
    case malformedServerData
    case serverError(status: Int)
    case budgetExceeded(ResourceKind)
    case cancelled
    case fileUnavailable
    case unknown

    public enum ResourceKind: Hashable, Sendable {
        case unsentText
        case pendingOperations
        case pastedImages
        case attachmentCount
        case attachmentSize
    }

    /// Whether retrying the same operation could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .serverUnreachable, .rateLimited, .serverError: true
        default: false
        }
    }
}
