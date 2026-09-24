/// Maps a failed `POST /users/login` to `LoginFailure` using the server's error id
/// (docs/research/auth.md §1 outcome table, identical in v10.11 and v11.11).
///
/// The server masks most failures (wrong password, unknown user, SSO-only account,
/// LDAP errors, method disabled) into one `api.user.login.invalid_credentials_*` id,
/// so "method disabled" cannot be told apart from bad credentials by id; the UI
/// should consult the limited client config for that.
public enum LoginErrorMapping {
    public static func map(_ error: APIError, mfaTokenProvided: Bool) -> LoginFailure {
        guard let id = error.serverErrorID, !id.isEmpty else { return .api(error) }
        switch id {
        case ServerErrorID.mfaRequired:
            // The server returns the same id for a missing *and* a malformed (not six
            // digits) code; if a code was sent, it was rejected.
            return mfaTokenProvided ? .invalidMFACode : .mfaRequired
        case ServerErrorID.mfaBadCode:
            return .invalidMFACode
        case ServerErrorID.loginInactive:
            return .accountDeactivated
        case ServerErrorID.loginNotVerified:
            return .emailNotVerified
        case ServerErrorID.loginBlankPassword:
            return .invalidCredentials
        case ServerErrorID.loginBotForbidden:
            return .loginMethodDisabled
        case ServerErrorID.loginTooManyAttempts, ServerErrorID.loginTooManyAttemptsLDAP:
            return .accountLocked
        default:
            if id.hasPrefix(ServerErrorID.invalidCredentialsPrefix) { return .invalidCredentials }
            if id.hasPrefix("api.user.check_user_login_attempts.too_many") { return .accountLocked }
            return .api(error)
        }
    }
}
