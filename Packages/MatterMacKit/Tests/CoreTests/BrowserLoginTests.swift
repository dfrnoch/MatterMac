import Foundation
import Testing
import os
import MatterMacModels
import MattermostAPI
import TestSupport
@testable import MatterMacCore

@MainActor
@Suite("Browser SSO binding and exchange")
struct BrowserLoginTests {
    let code = String(repeating: "a", count: 64)

    func discovery(_ endpoint: ServerEndpoint = CoreFixtures.endpoint) -> DiscoveryResult {
        DiscoveryResult(endpoint: endpoint, version: nil, capabilities: ServerCapabilities(login:
            LoginOptions(gitlab: true, google: true, office365: true, openID: true, saml: true)))
    }

    func callback(_ attempt: BrowserLoginAttempt) -> URL {
        let client = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems![0].value!
        var url = URLComponents(url: attempt.endpoint.url(path: ["login", "desktop"]), resolvingAgainstBaseURL: false)!
        url.scheme = BrowserLoginAttempt.callbackScheme
        url.queryItems = [URLQueryItem(name: "client_token", value: client), URLQueryItem(name: "server_token", value: code)]
        return url.url!
    }

    @Test func customProviderLabelKeepsAdvertisedRoute() throws {
        let wire = try JSONDecoder().decode(ClientConfigWire.self, from: Data(#"{"Version":"10.11.9","EnableSignUpWithGitLab":"true","GitLabButtonText":"Company SSO","EnableSignUpWithOpenId":"false"}"#.utf8))
        let discovery = DiscoveryResult(endpoint: CoreFixtures.endpoint, version: wire.capabilities.version,
                                        capabilities: wire.capabilities)
        #expect(discovery.browserSSOProviders == [.gitlab])
        #expect(wire.capabilities.login.displayName(for: .gitlab) == "Company SSO")
        #expect(wire.capabilities.login.displayName(for: .openID) == "OpenID Connect")
        let attempt = try BrowserLoginAttempt(discovery: discovery, provider: .gitlab)
        #expect(attempt.authorizationURL.path == "/company/chat/oauth/gitlab/login")
        let oversized = try JSONEncoder().encode(["GitLabButtonText": String(repeating: "x", count: 257)])
        let bounded = try JSONDecoder().decode(ClientConfigWire.self, from: oversized)
        #expect(bounded.capabilities.login.displayName(for: .gitlab).utf8.count <= ResourceBudget.standard.authenticationProviderLabelBytes)
    }

    @Test(arguments: SSOProvider.allCases)
    func providerRouteAndSingleUse(_ provider: SSOProvider) throws {
        let attempt = try BrowserLoginAttempt(discovery: discovery(), provider: provider)
        let expected = provider == .saml ? "/company/chat/login/sso/saml" : "/company/chat/oauth/\(provider.rawValue)/login"
        #expect(attempt.authorizationURL.path == expected)
        let query = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.count == 1 && query[0].name == "desktop_token" && query[0].value?.count == 64)
        let callback = callback(attempt)
        _ = try attempt.consume(callback)
        #expect(throws: BrowserLoginError.invalidCallback) { try attempt.consume(callback) }
    }

    @Test(arguments: ["host", "port", "path", "scheme", "state", "duplicate", "userinfo", "fragment", "bearer", "oversize", "code", "dev"])
    func rejectsUnboundOrMalformedCallback(_ mutation: String) throws {
        let attempt = try BrowserLoginAttempt(discovery: discovery(), provider: .openID)
        var c = URLComponents(url: callback(attempt), resolvingAgainstBaseURL: false)!
        switch mutation {
        case "host": c.host = "other.example.test"
        case "port": c.port = 444
        case "path": c.path = "/login/desktop"
        case "scheme": c.scheme = "https"
        case "state": c.queryItems![0].value = String(repeating: "f", count: 64)
        case "duplicate": c.queryItems!.append(c.queryItems![0])
        case "userinfo": c.user = "injected"
        case "fragment": c.fragment = "extra"
        case "bearer": c.queryItems!.append(URLQueryItem(name: "MMAUTHTOKEN", value: "not-a-code"))
        case "oversize": c.queryItems!.append(URLQueryItem(name: "redirect_to", value: String(repeating: "x", count: 9_000)))
        case "code": c.queryItems![1].value = "invalid"
        case "dev": c.scheme = "mattermost-dev"
        default: break
        }
        let url = c.url!
        #expect(throws: BrowserLoginError.invalidCallback) { try attempt.consume(url) }
    }

    @Test func cancellationExpiryAndProviderGating() throws {
        let a = try BrowserLoginAttempt(discovery: discovery(), provider: .openID)
        let url = callback(a)
        a.cancel()
        #expect(throws: BrowserLoginError.invalidCallback) { try a.consume(url) }
        var budget = ResourceBudget.standard
        budget.authenticationTimeoutSeconds = 0
        let expired = try BrowserLoginAttempt(discovery: discovery(), provider: .openID, budget: budget)
        let expiredURL = callback(expired)
        #expect(throws: BrowserLoginError.timedOut) { try expired.consume(expiredURL) }
        let disabled = DiscoveryResult(endpoint: CoreFixtures.endpoint, version: nil, capabilities: ServerCapabilities())
        #expect(throws: BrowserLoginError.unsupportedProvider) { try BrowserLoginAttempt(discovery: disabled, provider: .openID) }
    }

    @Test(arguments: [false, true])
    func exchangeVerifiesIdentityAndRevokesMismatch(mismatch: Bool) async throws {
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let expected = CoreFixtures.me.id.rawValue
        let actual = mismatch ? CoreFixtures.bob.id.rawValue : expected
        let factory = DefaultMattermostServiceFactory(budget: .standard, diagnostics: nil,
            retryPolicy: .standard, clock: ContinuousClock()) { _ in
            FakeHTTPTransport { request in
                calls.withLock { $0.append(request.url.path) }
                if request.url.path.hasSuffix("/desktop_token") {
                    #expect(!request.allowsRedirects)
                    #expect(request.url.query == nil && request.credential == nil)
                    return .json("{\"id\":\"\(expected)\",\"username\":\"alice\",\"mfa_secret\":\"ignored\"}", headers: ["Token": "fixture-session"])
                }
                if request.url.path.hasSuffix("/users/me") {
                    #expect(request.credential?.kind == .session)
                    return .json("{\"id\":\"\(actual)\",\"username\":\"alice\"}")
                }
                return .json("{}")
            }
        }
        let coordinator = LoginCoordinator(factory: factory)
        let attempt = try BrowserLoginAttempt(discovery: discovery(), provider: .openID)
        let url = callback(attempt)
        if mismatch {
            await #expect(throws: BrowserLoginError.requestFailed(.malformedServerData)) {
                try await coordinator.completeBrowserLogin(attempt, callback: url)
            }
            #expect(calls.withLock { $0.contains(where: { $0.hasSuffix("/users/logout") }) })
        } else {
            let result = try await coordinator.completeBrowserLogin(attempt, callback: url)
            #expect(result.user.id == CoreFixtures.me.id)
        }
        let before = calls.withLock { $0.count }
        await #expect(throws: BrowserLoginError.invalidCallback) {
            try await coordinator.completeBrowserLogin(attempt, callback: url)
        }
        #expect(calls.withLock { $0.count } == before)
    }
}
