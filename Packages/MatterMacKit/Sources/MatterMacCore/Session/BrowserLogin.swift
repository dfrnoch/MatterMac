public import Foundation
public import MatterMacModels
public import MattermostAPI
import Security

public enum BrowserLoginError: Error, Sendable, Equatable {
    case unsupportedProvider, invalidCallback, cancelled, timedOut, browserUnavailable, randomUnavailable
    case requestFailed(UserFacingError)
}

/// A desktop SSO attempt belongs to exactly one server and one system browser
/// session. Only its own random client_token may redeem a callback, exactly once.
@MainActor
public final class BrowserLoginAttempt: CustomReflectable {
    public let endpoint: ServerEndpoint
    public let authorizationURL: URL
    public static let callbackScheme = "mattermost"
    private var clientToken: String?
    private let deadline: ContinuousClock.Instant
    private let maximumCallbackBytes: Int

    public init(discovery: DiscoveryResult, provider: SSOProvider, budget: ResourceBudget = .standard)
        throws(BrowserLoginError) {
        guard discovery.browserSSOProviders.contains(provider) else { throw .unsupportedProvider }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw .randomUnavailable }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        endpoint = discovery.endpoint
        clientToken = token
        deadline = ContinuousClock.now + .seconds(budget.authenticationTimeoutSeconds)
        maximumCallbackBytes = budget.authenticationCallbackBytes
        let path = provider == .saml ? ["login", "sso", "saml"] : ["oauth", provider.rawValue, "login"]
        authorizationURL = endpoint.url(path: path, query: [URLQueryItem(name: "desktop_token", value: token)])
    }

    public func cancel() { clientToken = nil }
    nonisolated public var customMirror: Mirror { Mirror(self, children: [:]) }

    public func consume(_ callback: URL) throws(BrowserLoginError) -> DesktopLoginCode {
        guard ContinuousClock.now < deadline else { cancel(); throw .timedOut }
        guard let expected = clientToken else { throw .invalidCallback }
        defer { clientToken = nil } // Never retry or replay a received callback.
        guard callback.absoluteString.utf8.count <= maximumCallbackBytes,
              let c = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              c.scheme == Self.callbackScheme, c.user == nil, c.password == nil, c.fragment == nil,
              c.host?.lowercased() == endpoint.host,
              (c.port ?? (endpoint.scheme == .https ? 443 : 80)) == endpoint.effectivePort,
              c.percentEncodedPath == URLComponents(url: endpoint.url(path: ["login", "desktop"]),
                                                    resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let items = c.queryItems, items.count <= 4,
              Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "client_token" })?.value == expected,
              items.allSatisfy({ ["client_token", "server_token", "redirect_to"].contains($0.name) }),
              let value = items.first(where: { $0.name == "server_token" })?.value,
              let code = DesktopLoginCode(value) else { throw .invalidCallback }
        return code
    }
}

extension LoginCoordinator {
    @MainActor
    public func completeBrowserLogin(_ attempt: BrowserLoginAttempt, callback: URL) async throws(BrowserLoginError) -> LoginResult {
        guard !Task.isCancelled else { attempt.cancel(); throw .cancelled }
        let code = try attempt.consume(callback)
        let discovery = factory.discovery(for: attempt.endpoint)
        let result: LoginResult
        do {
            result = try await discovery.loginWithDesktopCode(code)
            await discovery.shutdown()
        } catch {
            await discovery.shutdown()
            if Task.isCancelled { throw .cancelled }
            throw .requestFailed(ServerSession.userFacing(error))
        }
        let service = factory.service(for: attempt.endpoint, credential: result.credential)
        do {
            let user = try await service.currentUser()
            guard user.id == result.user.id else { throw BrowserLoginError.requestFailed(.malformedServerData) }
            guard !Task.isCancelled else { throw BrowserLoginError.cancelled }
            await service.shutdown()
            return LoginResult(credential: result.credential, user: user)
        } catch {
            await service.shutdown()
            await discardNewLogin(result, endpoint: attempt.endpoint)
            if Task.isCancelled { throw .cancelled }
            if let failure = error as? BrowserLoginError { throw failure }
            throw .requestFailed(.malformedServerData)
        }
    }

    /// Cancellation or a rejected session slot must not leave an invisible login.
    public func discardNewLogin(_ result: LoginResult, endpoint: ServerEndpoint) async {
        guard result.credential.kind == .session else { return }
        let service = factory.service(for: endpoint, credential: result.credential)
        // An independent, bounded request so cancelling sign-in doesn't cancel its
        // best-effort server logout as well. This never retries the code exchange.
        await Task {
            try? await service.logout()
            await service.shutdown()
        }.value
    }
}
