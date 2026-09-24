public import MatterMacModels
public import MattermostAPI

/// What discovery learned before any credential is sent (SPEC §8 Server discovery).
public struct DiscoveryResult: Sendable, Hashable {
    public let endpoint: ServerEndpoint
    public let version: ServerVersion?
    public let capabilities: ServerCapabilities

    /// Login methods MatterMac can actually perform against this server.
    public var browserSSOProviders: [SSOProvider] {
        let login = capabilities.login
        return SSOProvider.allCases.filter {
            switch $0 {
            case .openID: login.openID
            case .saml: login.saml
            case .google: login.google
            case .office365: login.office365
            case .gitlab: login.gitlab
            }
        }
    }

    public var supportedMethods: [LoginMethodSupport] {
        var methods: [LoginMethodSupport] = []
        if capabilities.login.passwordLoginAvailable { methods.append(.password) }
        // PAT policy (EnableUserAccessTokens) is only visible after login; offering the
        // option is honest because the server validates the token either way.
        methods.append(.personalAccessToken)
        methods += browserSSOProviders.map { .browserSSO($0) }
        return methods
    }
}

public enum DiscoveryError: Error, Sendable, Hashable {
    case notMattermost
    case unreachable(UserFacingError)
    case redirectedElsewhere
}

public enum AuthenticationError: Error, Sendable, Hashable {
    case login(LoginFailure)
    case invalidToken
    case personalAccessTokensDisabledOrInvalid
    case failed(UserFacingError)
}

/// Performs discovery and authentication for a new session slot. Holds the password
/// only for the duration of one call; nothing is stored.
public struct LoginCoordinator: Sendable {
    public let factory: any MattermostServiceFactory

    public init(factory: any MattermostServiceFactory) {
        self.factory = factory
    }

    /// Non-mutating, bounded probe: ping + limited client config.
    public func discover(_ endpoint: ServerEndpoint) async throws(DiscoveryError) -> DiscoveryResult {
        let discovery = factory.discovery(for: endpoint)
        let version: ServerVersion?
        do {
            version = try await discovery.ping()
        } catch {
            await discovery.shutdown()
            switch error {
            case .redirectRefused: throw .redirectedElsewhere
            case .notFound, .malformedResponse, .unexpectedStatus, .badRequest: throw .notMattermost
            default: throw .unreachable(ServerSession.userFacing(error))
            }
        }
        do {
            var capabilities = try await discovery.limitedConfiguration()
            if capabilities.version == nil { capabilities.version = version }
            await discovery.shutdown()
            return DiscoveryResult(endpoint: endpoint, version: capabilities.version ?? version, capabilities: capabilities)
        } catch {
            await discovery.shutdown()
            switch error {
            case .notFound, .malformedResponse: throw .notMattermost
            default: throw .unreachable(ServerSession.userFacing(error))
            }
        }
    }

    public func login(_ endpoint: ServerEndpoint, loginID: String, password: String, mfaCode: String?)
        async throws(AuthenticationError) -> LoginResult
    {
        let discovery = factory.discovery(for: endpoint)
        let request = LoginRequest(loginID: loginID.trimmingCharacters(in: .whitespacesAndNewlines),
                                   password: password,
                                   mfaToken: mfaCode?.trimmingCharacters(in: .whitespacesAndNewlines))
        let result: LoginResult
        do {
            result = try await discovery.login(request)
            await discovery.shutdown()
        } catch {
            await discovery.shutdown()
            throw .login(error)
        }
        // Verify identity with the new credential before trusting it (SPEC §8).
        let service = factory.service(for: endpoint, credential: result.credential)
        do {
            let me = try await service.currentUser()
            await service.shutdown()
            guard me.id == result.user.id else { throw AuthenticationError.failed(.malformedServerData) }
            return LoginResult(credential: result.credential, user: me)
        } catch let error as AuthenticationError {
            await service.shutdown()
            throw error
        } catch {
            await service.shutdown()
            throw .failed(ServerSession.userFacing(error))
        }
    }

    public enum RestoreError: Error, Sendable { case invalidCredential, accountChanged, failed(UserFacingError) }

    /// Revalidate a saved bearer without changing its session/PAT semantics.
    public func restore(_ endpoint: ServerEndpoint, credential: BearerCredential, expectedUser: UserID)
        async throws(RestoreError) -> LoginResult
    {
        let service = factory.service(for: endpoint, credential: credential)
        let me: User
        do { me = try await service.currentUser() }
        catch {
            await service.shutdown()
            if case .unauthorized = error { throw .invalidCredential }
            throw .failed(ServerSession.userFacing(error))
        }
        await service.shutdown()
        guard me.id == expectedUser else { throw .accountChanged }
        return LoginResult(credential: credential, user: me)
    }

    /// Validates a user-supplied personal access token via `/users/me`.
    public func authenticate(_ endpoint: ServerEndpoint, personalAccessToken token: String)
        async throws(AuthenticationError) -> LoginResult
    {
        guard let credential = BearerCredential(token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                                                kind: .personalAccessToken)
        else { throw .invalidToken }
        let service = factory.service(for: endpoint, credential: credential)
        do {
            let me = try await service.currentUser()
            await service.shutdown()
            return LoginResult(credential: credential, user: me)
        } catch {
            await service.shutdown()
            if case .unauthorized = error { throw .personalAccessTokensDisabledOrInvalid }
            throw .failed(ServerSession.userFacing(error))
        }
    }
}
