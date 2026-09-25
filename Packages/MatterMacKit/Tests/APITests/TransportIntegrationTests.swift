import Foundation
import MatterMacModels
@testable import MattermostAPI
import Testing
import TestSupport

/// Exercises the production `URLSessionTransport` against a loopback HTTP server:
/// size limits before and during consumption, decompression, error bodies,
/// cookies, headers, redirects, failure classification and cancellation.
@Suite("URLSessionTransport (loopback)")
struct TransportIntegrationTests {
    static let token = BearerCredential(token: "abcdefghijklmnopqrstuvwxyz", kind: .session)!

    @discardableResult
    func withServer<T>(_ handler: @escaping LocalHTTPServer.Handler,
                       _ body: (LocalHTTPServer, URLSessionTransport) async throws -> T) async throws -> T {
        let server = try await LocalHTTPServer.start(handler: handler)
        let transport = URLSessionTransport(scope: server.endpoint(), userAgent: UserAgent.make(version: "1.2.3"))
        do {
            let result = try await body(server, transport)
            await transport.shutdown()
            server.stop()
            return result
        } catch {
            await transport.shutdown()
            server.stop()
            throw error
        }
    }

    func get(_ server: LocalHTTPServer, _ path: String, credential: BearerCredential? = nil) -> HTTPRequest {
        HTTPRequest(method: .get, url: server.endpoint().url(path: path.split(separator: "/").map(String.init)),
                    credential: credential)
    }

    @Test func buffersSmallBodyAndSendsExpectedHeaders() async throws {
        try await withServer({ _ in .json(#"{"ok":true}"#) }) { server, transport in
            let response = try await transport.send(get(server, "api/v4/users/me", credential: Self.token),
                                                     limits: ResponseLimits(maximumBodyBytes: 1_024))
            #expect(response.statusCode == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == #"{"ok":true}"#)
            let seen = try #require(server.requests.first)
            #expect(seen.headers["Authorization"] == "Bearer abcdefghijklmnopqrstuvwxyz")
            #expect(seen.headers["User-Agent"] == "MatterMac/1.2.3 (Macintosh; macOS)")
            #expect(seen.headers["Accept"] == "application/json")
            #expect(seen.headers["Cookie"] == nil)
            #expect(seen.headers["X-Requested-With"] == nil)
            #expect(!UserAgent.containsMobileToken(seen.headers["User-Agent"] ?? "Mobile"))
        }
    }

    @Test func unauthenticatedRequestCarriesNoAuthorization() async throws {
        try await withServer({ _ in .json("{}") }) { server, transport in
            _ = try await transport.send(get(server, "api/v4/system/ping"), limits: ResponseLimits(maximumBodyBytes: 1_024))
            #expect(server.requests.first?.headers["Authorization"] == nil)
        }
    }

    @Test func refusesDeclaredContentLengthAboveLimitBeforeReadingBody() async throws {
        try await withServer({ _ in
            LocalHTTPServer.Response(status: 200, headers: ["Content-Type": "application/json"],
                                     body: .generated(count: 5 * 1_048_576, chunk: 65_536))
        }) { server, transport in
            await #expect(throws: APIError.responseTooLarge(limitBytes: 1_000)) {
                _ = try await transport.send(get(server, "big"), limits: ResponseLimits(maximumBodyBytes: 1_000))
            }
        }
    }

    @Test func acceptsBodyExactlyAtLimit() async throws {
        try await withServer({ _ in
            LocalHTTPServer.Response(status: 200, body: .generated(count: 4_096, chunk: 1_000))
        }) { server, transport in
            let response = try await transport.send(get(server, "exact"), limits: ResponseLimits(maximumBodyBytes: 4_096))
            #expect(response.body.count == 4_096)
        }
    }

    @Test func cancelsChunkedBodyThatExceedsLimitWhileStreaming() async throws {
        let parts = (0..<64).map { _ in Data(count: 16 * 1_024) }  // 1 MiB, no Content-Length
        try await withServer({ _ in
            LocalHTTPServer.Response(status: 200, headers: ["Content-Type": "application/json"],
                                     body: .chunked(parts, pause: .milliseconds(2)))
        }) { server, transport in
            await #expect(throws: APIError.responseTooLarge(limitBytes: 100_000)) {
                _ = try await transport.send(get(server, "stream"), limits: ResponseLimits(maximumBodyBytes: 100_000))
            }
        }
    }

    @Test func countsDecompressedBytesNotContentLength() async throws {
        // 8 MiB of zeros gzip to ~8 KiB: Content-Length is tiny, the decoded body is not.
        let bomb = try LocalHTTPServer.gzip(Data(count: 8 * 1_048_576))
        #expect(bomb.count < 64 * 1_024)
        try await withServer({ _ in
            LocalHTTPServer.Response(status: 200, headers: ["Content-Type": "application/json", "Content-Encoding": "gzip"],
                                     body: .data(bomb))
        }) { server, transport in
            await #expect(throws: APIError.responseTooLarge(limitBytes: 1_048_576)) {
                _ = try await transport.send(get(server, "gz"), limits: ResponseLimits(maximumBodyBytes: 1_048_576))
            }
        }
    }

    @Test func decodesLegitimateGzipBody() async throws {
        let payload = Data(String(repeating: #"{"k":"value"},"#, count: 2_000).utf8)
        let encoded = try LocalHTTPServer.gzip(payload)
        try await withServer({ _ in
            LocalHTTPServer.Response(status: 200, headers: ["Content-Encoding": "gzip"], body: .data(encoded))
        }) { server, transport in
            let response = try await transport.send(get(server, "gz"), limits: ResponseLimits(maximumBodyBytes: 1_048_576))
            #expect(response.body == payload)
        }
    }

    @Test func returnsErrorStatusWithBoundedBody() async throws {
        try await withServer({ _ in
            .json(#"{"id":"api.context.permissions.app_error","message":"secret words","status_code":403}"#, status: 403)
        }) { server, transport in
            let response = try await transport.send(get(server, "forbidden"), limits: ResponseLimits(maximumBodyBytes: 10))
            #expect(response.statusCode == 403)
            #expect(!response.bodyDiscarded)
            #expect(HTTPStatusMapping.error(for: response)?.serverErrorID == "api.context.permissions.app_error")
        }
    }

    @Test func discardsOversizedErrorBodyButKeepsStatus() async throws {
        try await withServer({ _ in
            LocalHTTPServer.Response(status: 502, headers: ["Content-Type": "text/html"],
                                     body: .generated(count: 300 * 1_024, chunk: 8_192))
        }) { server, transport in
            let response = try await transport.send(get(server, "proxy"), limits: ResponseLimits(maximumBodyBytes: 1_000))
            #expect(response.statusCode == 502)
            #expect(response.bodyDiscarded)
            #expect(HTTPStatusMapping.error(for: response) == .server(ServerErrorInfo(id: "", statusCode: 502, requestID: nil)))
        }
    }

    @Test func neverStoresOrSendsCookies() async throws {
        try await withServer({ request in
            if request.path.hasSuffix("/login") {
                return .json("{}", headers: ["Set-Cookie": "MMAUTHTOKEN=canarycookie; Path=/; HttpOnly"])
            }
            return .json("{}")
        }) { server, transport in
            _ = try await transport.send(get(server, "api/v4/users/login"), limits: ResponseLimits(maximumBodyBytes: 1_024))
            _ = try await transport.send(get(server, "api/v4/users/me", credential: Self.token),
                                         limits: ResponseLimits(maximumBodyBytes: 1_024))
            #expect(server.requests.count == 2)
            #expect(server.requests.allSatisfy { $0.headers["Cookie"] == nil })
        }
    }

    @Test func followsSameOriginRedirectInsideSubpath() async throws {
        let server = try await LocalHTTPServer.start { request in
            if request.path == "/company/chat/api/v4/old" { return .redirect(to: "/company/chat/api/v4/new") }
            return .json(#"{"at":"new"}"#)
        }
        defer { server.stop() }
        let scope = server.endpoint(pathSegments: ["company", "chat"])
        let transport = URLSessionTransport(scope: scope)
        let response = try await transport.send(
            HTTPRequest(method: .get, url: scope.url(path: ["api", "v4", "old"]), credential: Self.token),
            limits: ResponseLimits(maximumBodyBytes: 1_024))
        #expect(response.statusCode == 200)
        #expect(server.requests.map(\.path) == ["/company/chat/api/v4/old", "/company/chat/api/v4/new"])
        #expect(server.requests.last?.headers["Authorization"] == "Bearer abcdefghijklmnopqrstuvwxyz")
        await transport.shutdown()
    }

    @Test func tokenExchangeRefusesEvenSameOriginRedirects() async throws {
        try await withServer({ _ in .redirect(307, to: "/another-endpoint") }) { server, transport in
            let request = HTTPRequest(method: .post, url: server.endpoint().url(path: ["api", "v4", "users", "login", "desktop_token"]),
                                      body: Data("one-time-code-fixture".utf8), allowsRedirects: false)
            await #expect(throws: APIError.redirectRefused) {
                _ = try await transport.send(request, limits: ResponseLimits(maximumBodyBytes: 1_024))
            }
            #expect(server.requests.count == 1)
        }
    }

    @Test func refusesCrossOriginRedirectAndNeverContactsTarget() async throws {
        let target = try await LocalHTTPServer.start { _ in .json("{}") }
        defer { target.stop() }
        let targetURL = target.baseURL.absoluteString + "/steal"
        let origin = try await LocalHTTPServer.start { _ in .redirect(307, to: targetURL) }
        defer { origin.stop() }
        let transport = URLSessionTransport(scope: origin.endpoint())
        await #expect(throws: APIError.redirectRefused) {
            _ = try await transport.send(
                HTTPRequest(method: .get, url: origin.endpoint().url(path: ["api", "v4", "users", "me"]),
                            credential: Self.token),
                limits: ResponseLimits(maximumBodyBytes: 1_024))
        }
        #expect(target.requests.isEmpty)
        await transport.shutdown()
    }

    @Test func refusesRedirectThatLeavesTheSubpath() async throws {
        let server = try await LocalHTTPServer.start { request in
            request.path.hasPrefix("/company/chat/") ? .redirect(to: "/other-app/api") : .json("{}")
        }
        defer { server.stop() }
        let scope = server.endpoint(pathSegments: ["company", "chat"])
        let transport = URLSessionTransport(scope: scope)
        await #expect(throws: APIError.redirectRefused) {
            _ = try await transport.send(HTTPRequest(method: .get, url: scope.url(path: ["api", "v4", "x"]),
                                                     credential: Self.token),
                                         limits: ResponseLimits(maximumBodyBytes: 1_024))
        }
        #expect(server.requests.count == 1)
        await transport.shutdown()
    }

    @Test(arguments: ["%2e%2e%2fother", "%2F..%2Fother", "..%5Cother"])
    func refusesEncodedSeparatorsInTraversal(segment: String) async throws {
        let escaped = "/company/chat/" + segment
        let server = try await LocalHTTPServer.start { request in
            request.path == "/company/chat/start" ? .redirect(to: escaped) : .json("{}")
        }
        defer { server.stop() }
        let scope = server.endpoint(pathSegments: ["company", "chat"])
        let transport = URLSessionTransport(scope: scope)
        // Refuse both directly constructed requests and redirects before the
        // bearer can reach a proxy-normalized sibling application path.
        let direct = try #require(URL(string: server.baseURL.absoluteString + escaped))
        #expect(throws: APIError.redirectRefused) {
            try URLSessionTransport.makeURLRequest(for: HTTPRequest(method: .get, url: direct, credential: Self.token),
                                                   scope: scope, userAgent: "MatterMac")
        }
        await #expect(throws: APIError.redirectRefused) {
            _ = try await transport.send(HTTPRequest(method: .get, url: scope.url(path: ["start"]), credential: Self.token),
                                         limits: ResponseLimits(maximumBodyBytes: 1_024))
        }
        #expect(server.requests.count == 1)
        await transport.shutdown()
    }

    @Test func refusesRedirectThatTurnsAWriteIntoAGet() async throws {
        try await withServer({ request in
            request.method == "POST" ? .redirect(303, to: "/api/v4/elsewhere") : .json("{}")
        }) { server, transport in
            await #expect(throws: APIError.redirectRefused) {
                _ = try await transport.send(
                    HTTPRequest(method: .post, url: server.endpoint().url(path: ["api", "v4", "posts"]), body: Data("{}".utf8),
                                credential: Self.token),
                    limits: ResponseLimits(maximumBodyBytes: 1_024))
            }
            #expect(server.requests.count == 1)
        }
    }

    @Test func connectionRefusedIsNotSent() async throws {
        // Start and stop a server to obtain a loopback port with no listener.
        let server = try await LocalHTTPServer.start { _ in .json("{}") }
        let endpoint = server.endpoint()
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let transport = URLSessionTransport(scope: endpoint)
        await #expect(throws: APIError.notSent(.cannotConnect)) {
            _ = try await transport.send(HTTPRequest(method: .post, url: endpoint.url(path: ["api", "v4", "posts"]),
                                                     body: Data("{}".utf8)),
                                         limits: ResponseLimits(maximumBodyBytes: 1_024))
        }
        await transport.shutdown()
    }

    @Test func timeoutAfterTransmissionIsOutcomeUnknown() async throws {
        try await withServer({ _ in LocalHTTPServer.Response(status: 200, body: .hang) }) { server, transport in
            var request = HTTPRequest(method: .post, url: server.endpoint().url(path: ["api", "v4", "posts"]),
                                      body: Data(#"{"message":"x"}"#.utf8), credential: Self.token)
            request.timeout = 1
            await #expect(throws: APIError.outcomeUnknown(.timedOut)) {
                _ = try await transport.send(request, limits: ResponseLimits(maximumBodyBytes: 1_024))
            }
            #expect(server.requests.count == 1)
        }
    }

    @Test func cancellationCancelsTheNetworkTask() async throws {
        try await withServer({ _ in LocalHTTPServer.Response(status: 200, body: .hang) }) { server, transport in
            let request = get(server, "slow")
            let task = Task { () async throws -> HTTPResponse in
                try await transport.send(request, limits: ResponseLimits(maximumBodyBytes: 1_024))
            }
            try await Task.sleep(for: .milliseconds(200))
            task.cancel()
            let result = await task.result
            #expect(throws: APIError.cancelled) { try result.get() }
            #expect(transport.sessionDelegate.activeTaskCount == 0)
        }
    }

    @Test func cancelledWriteThatWasTransmittedIsOutcomeUnknown() async throws {
        try await withServer({ _ in LocalHTTPServer.Response(status: 201, body: .hang) }) { server, transport in
            let request = HTTPRequest(method: .post, url: server.endpoint().url(path: ["api", "v4", "posts"]),
                                      body: Data("{}".utf8), credential: Self.token)
            let task = Task { () async throws -> HTTPResponse in
                try await transport.send(request, limits: ResponseLimits(maximumBodyBytes: 1_024))
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(server.requests.count == 1)
            task.cancel()
            let result = await task.result
            #expect(throws: APIError.outcomeUnknown(.other(code: URLError.cancelled.rawValue))) { try result.get() }
        }
    }

    @Test func requestOutsideScopeIsRefusedWithoutNetwork() async throws {
        try await withServer({ _ in .json("{}") }) { server, transport in
            let foreign = URL(string: "http://localhost:\(server.port)/api/v4/users/me")!
            await #expect(throws: APIError.redirectRefused) {
                _ = try await transport.send(HTTPRequest(method: .get, url: foreign, credential: Self.token),
                                             limits: ResponseLimits(maximumBodyBytes: 1_024))
            }
            #expect(server.requests.isEmpty)
        }
    }

    @Test func callsAfterShutdownFailFastAsCancelled() async throws {
        let server = try await LocalHTTPServer.start { _ in .json("{}") }
        defer { server.stop() }
        let transport = URLSessionTransport(scope: server.endpoint())
        await transport.shutdown()
        await transport.shutdown()  // idempotent
        #expect(transport.isShutDown)
        await #expect(throws: APIError.cancelled) {
            _ = try await transport.send(get(server, "x"), limits: ResponseLimits(maximumBodyBytes: 10))
        }
        #expect(server.requests.isEmpty)
    }
}
