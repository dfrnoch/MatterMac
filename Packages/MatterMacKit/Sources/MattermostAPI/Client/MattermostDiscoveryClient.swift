import Foundation
public import MatterMacModels

/// Production `MattermostDiscoveryService`: unauthenticated probing and password
/// login against one normalized server (docs/research/auth.md §1, §5, §8).
///
/// Lifetime: owns its own transport/URLSession (no credential). Call `shutdown()`
/// once discovery/login is finished; the authenticated session uses a separate
/// `MattermostHTTPClient` created by the factory.
public final class MattermostDiscoveryClient: MattermostDiscoveryService {
    public let endpoint: ServerEndpoint
    private let pipeline: RequestPipeline
    private let budget: ResourceBudget

    init(endpoint: ServerEndpoint, pipeline: RequestPipeline, budget: ResourceBudget) {
        self.endpoint = endpoint
        self.pipeline = pipeline
        self.budget = budget
    }

    public func shutdown() async {
        await pipeline.shutdown()
    }

    /// `GET /api/v4/system/ping` (no parameters). A 200 must carry a JSON body with
    /// `status == "OK"`, which rejects non-Mattermost sites that answer 200 with HTML.
    /// The version comes from `X-Version-Id` (`<major>.<minor>.<patch>.<build>.<hash>.<licensed>`)
    /// and is `nil` when a proxy strips the header.
    public func ping() async throws(APIError) -> ServerVersion? {
        let response = try await pipeline.execute(request(.get, ["system", "ping"]), priority: .interactive, limits: small)
        let wire: PingWire = try MattermostHTTPClient.decode(response.body)
        guard wire.status == "OK" else { throw .malformedResponse }
        return response.headers["X-Version-Id"].flatMap { ServerVersion(parsing: String($0.prefix(256))) }
    }

    /// `GET /api/v4/config/client?format=old` without a session (the limited
    /// config). `format=old` is required by v10 and ignored by v11.
    public func limitedConfiguration() async throws(APIError) -> ServerCapabilities {
        let response = try await pipeline.execute(
            request(.get, ["config", "client"], query: [URLQueryItem(name: "format", value: "old")]),
            priority: .interactive, limits: small)
        let wire: ClientConfigWire = try MattermostHTTPClient.decode(response.body)
        return wire.capabilities
    }

    /// `POST /api/v4/users/login` with an all-string body `{login_id, password[, token]}`
    /// (no `device_id`, no `X-Requested-With`, so the server sets no cookies). The
    /// session token is read from the `Token` response header, then verified with
    /// `GET /api/v4/users/me` using `Authorization: Bearer` before it is returned.
    public func login(_ login: LoginRequest) async throws(LoginFailure) -> LoginResult {
        let mfa = login.mfaToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mfaToken = (mfa?.isEmpty ?? true) ? nil : mfa
        let response: HTTPResponse
        do throws(APIError) {
            let body = try RequestBodyEncoding.encode(LoginBody(login_id: login.loginID, password: login.password,
                                                                token: mfaToken))
            // Never retried (POST); never coalesced.
            response = try await pipeline.execute(request(.post, ["users", "login"], body: body), priority: .interactive,
                                                  limits: small)
        } catch {
            throw LoginErrorMapping.map(error, mfaTokenProvided: mfaToken != nil)
        }
        guard let header = response.headers["Token"]?.trimmingCharacters(in: .whitespaces),
              let credential = BearerCredential(token: header, kind: .session)
        else { throw .api(.malformedResponse) }
        let loginUser: User
        do throws(APIError) {
            loginUser = (try MattermostHTTPClient.decode(response.body) as UserWire).user
        } catch {
            throw .api(error)
        }
        // Verify that bearer authentication works end to end (a proxy that strips
        // `Authorization` would otherwise surface only on the first real request).
        let verified: User
        do throws(APIError) {
            var me = request(.get, ["users", "me"])
            me.credential = credential
            let meResponse = try await pipeline.execute(me, priority: .interactive, limits: small)
            verified = (try MattermostHTTPClient.decode(meResponse.body) as UserWire).user
        } catch {
            throw .api(error)
        }
        guard verified.id == loginUser.id else { throw .api(.malformedResponse) }
        return LoginResult(credential: credential, user: verified)
    }

    /// Mattermost Desktop's one-time SSO exchange. The response can contain extra
    /// sensitive user fields; decode only UserWire and never retain the raw body.
    public func loginWithDesktopCode(_ code: DesktopLoginCode) async throws(APIError) -> LoginResult {
        struct Body: Encodable { let token: String; let device_id = "" }
        let body = try RequestBodyEncoding.encode(Body(token: code.value))
        var request = request(.post, ["users", "login", "desktop_token"], body: body)
        request.allowsRedirects = false
        let response = try await pipeline.execute(request, priority: .interactive, limits: small)
        guard let token = response.headers["Token"],
              let credential = BearerCredential(token: token, kind: .session) else { throw .malformedResponse }
        let user = (try MattermostHTTPClient.decode(response.body) as UserWire).user
        return LoginResult(credential: credential, user: user)
    }

    private var small: ResponseLimits { ResponseLimits(maximumBodyBytes: budget.smallResponseBytes) }

    private func request(_ method: HTTPMethod, _ segments: [String], query: [URLQueryItem] = [], body: Data? = nil)
        -> HTTPRequest {
        HTTPRequest(method: method, url: endpoint.url(path: ["api", "v4"] + segments, query: query), body: body)
    }
}
