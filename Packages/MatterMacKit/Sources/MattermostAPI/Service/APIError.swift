/// Typed API failure taxonomy (SPEC §6, §8). Distinguishes authentication failure,
/// permission denial, ambiguous not-found, rate limiting, transport loss before vs.
/// possibly after a write was sent, cancellation, oversize and malformed responses.
/// Never carries server `message`/`detailed_error` text or request bodies.
public enum APIError: Error, Hashable, Sendable, CustomStringConvertible {
    /// 401: session expired/revoked or bad credentials, depending on the endpoint.
    case unauthorized(ServerErrorInfo)
    /// 403: permission or policy denial. Not necessarily an expired token.
    case forbidden(ServerErrorInfo)
    /// 404: missing *or* inaccessible (ambiguous by design).
    case notFound(ServerErrorInfo)
    case badRequest(ServerErrorInfo)
    case payloadTooLarge(ServerErrorInfo)
    /// 429 with `Retry-After` / `X-Ratelimit-Reset` seconds when present.
    case rateLimited(retryAfterSeconds: Int?)
    /// 501: feature disabled/unlicensed on this server.
    case notImplemented(ServerErrorInfo)
    /// 5xx other than 501.
    case server(ServerErrorInfo)
    case unexpectedStatus(Int)
    /// The response exceeded the byte budget for this request and was cancelled.
    case responseTooLarge(limitBytes: Int)
    case malformedResponse
    /// The request definitely did not reach the server (DNS, refused, offline, TLS).
    case notSent(TransportFailure)
    /// Transport failed after the request may have been delivered (timeout,
    /// connection lost). For non-idempotent writes the outcome is unknown.
    case outcomeUnknown(TransportFailure)
    /// A redirect to a different origin or scheme was refused (credentials are never
    /// forwarded across origins).
    case redirectRefused
    case cancelled
    /// Client-side admission control refused the request (too many queued requests).
    case overloaded
    /// A user-selected file became unreadable or changed during upload.
    case localFileUnavailable

    public var description: String {
        switch self {
        case .unauthorized(let info): "unauthorized(\(info.id))"
        case .forbidden(let info): "forbidden(\(info.id))"
        case .notFound(let info): "notFound(\(info.id))"
        case .badRequest(let info): "badRequest(\(info.id))"
        case .payloadTooLarge(let info): "payloadTooLarge(\(info.id))"
        case .rateLimited(let seconds): "rateLimited(\(seconds.map(String.init) ?? "?"))"
        case .notImplemented(let info): "notImplemented(\(info.id))"
        case .server(let info): "server(\(info.statusCode), \(info.id))"
        case .unexpectedStatus(let status): "unexpectedStatus(\(status))"
        case .responseTooLarge(let limit): "responseTooLarge(\(limit))"
        case .malformedResponse: "malformedResponse"
        case .notSent(let failure): "notSent(\(failure))"
        case .outcomeUnknown(let failure): "outcomeUnknown(\(failure))"
        case .redirectRefused: "redirectRefused"
        case .cancelled: "cancelled"
        case .overloaded: "overloaded"
        case .localFileUnavailable: "localFileUnavailable"
        }
    }

    public var serverErrorID: String? {
        switch self {
        case .unauthorized(let info), .forbidden(let info), .notFound(let info), .badRequest(let info),
             .payloadTooLarge(let info), .notImplemented(let info), .server(let info):
            info.id
        default:
            nil
        }
    }

    /// Whether a *safe* (idempotent) read may be retried with backoff.
    public var isRetryableRead: Bool {
        switch self {
        case .rateLimited, .notSent, .outcomeUnknown, .server: true
        default: false
        }
    }
}

public enum TransportFailure: Hashable, Sendable, CustomStringConvertible {
    case offline
    case timedOut
    case cannotConnect
    case dnsFailure
    case connectionLost
    case tlsFailure
    case other(code: Int)

    public var description: String {
        switch self {
        case .offline: "offline"
        case .timedOut: "timedOut"
        case .cannotConnect: "cannotConnect"
        case .dnsFailure: "dnsFailure"
        case .connectionLost: "connectionLost"
        case .tlsFailure: "tlsFailure"
        case .other(let code): "other(\(code))"
        }
    }
}

/// Well-known server error ids used for control flow. Verified against v11.11.1 and
/// v10.11.24 source (docs/compatibility.md).
public enum ServerErrorID {
    /// Login failures are masked by the server into one of these (chosen from config).
    public static let invalidCredentialsPrefix = "api.user.login.invalid_credentials"
    public static let invalidCredentials = "api.user.login.invalid_credentials_email_username"
    public static let mfaRequired = "mfa.validate_token.authenticate.app_error"
    public static let mfaBadCode = "api.user.check_user_mfa.bad_code.app_error"
    public static let loginBlankPassword = "api.user.login.blank_pwd.app_error"
    public static let loginInactive = "api.user.login.inactive.app_error"
    public static let loginNotVerified = "api.user.login.not_verified.app_error"
    public static let loginBotForbidden = "api.user.login.bot_login_forbidden.app_error"
    public static let loginTooManyAttempts = "api.user.check_user_login_attempts.too_many.app_error"
    public static let loginTooManyAttemptsLDAP = "api.user.check_user_login_attempts.too_many_ldap.app_error"
    /// 403 on every session endpoint when MFA is enforced but not enrolled.
    public static let mfaEnrollmentRequired = "api.context.mfa_required.app_error"
    /// 500 during token lookup. Not a logout signal.
    public static let invalidTokenServerError = "api.context.invalid_token.error"
    public static let sessionExpired = "api.context.session_expired.app_error"
    public static let permissions = "api.context.permissions.app_error"
    public static let deduplicatePending = "api.post.deduplicate_create_post.pending"
    public static let messageTooLong = "model.post.is_valid.message_length.app_error"
    public static let editTimeLimit = "api.post.update_post.permissions_time_limit.app_error"
    public static let channelsNotFound = "app.channel.get_channels.not_found.app_error"
    public static let deletedChannelsNotFound = "app.channel.get_deleted.missing.app_error"
    public static let channelNameTaken = "store.sql_channel.save_channel.exists.app_error"
    public static let channelNameArchived = "store.sql_channel.save.archived_channel.app_error"
    public static let channelLimitReached = "store.sql_channel.save_channel.limit.app_error"
    public static let postNotFound = "app.post.get.app_error"
    public static let commandNotFound = "api.command.execute_command.not_found.app_error"
    public static let deletedChannel = "api.post.create_post.can_not_post_to_deleted.error"
    public static let rootIDInvalid = "api.post.create_post.root_id.app_error"
    public static let townSquareReadOnly = "api.post.create_post.town_square_read_only"
    public static let tooManyReactions = "app.reaction.save.save.too_many_reactions"
    public static let fileTooLarge = "api.file.upload_file.too_large_detailed.app_error"
    public static let attachmentsDisabled = "api.file.attachments.disabled.app_error"
    public static let requestBodyTooLarge = "api.context.request_body_too_large.app_error"
}
