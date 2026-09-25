import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

@MainActor @Suite("Connect cancellation", .serialized)
struct ConnectCancellationTests {
    @Test(arguments: ["cancel", "task", "shutdown", "replace"], [false, true])
    func staleDiscoveryCannotReopenLogin(action: String, fails: Bool) async throws {
        let started = Gate(), release = Gate()
        let factory = Factory(started: started, release: release, fails: fails)
        let app = AppModel(environment: AppEnvironment(serviceFactory: factory,
            makeRealtime: { _, _, _ in FakeRealtimeConnection() },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
        let probe = Task { await app.beginLogin(serverText: CoreFixtures.endpoint.description) }
        await started.wait()
        let newer = try ServerURLNormalizer.normalize("https://new.example.test", allowInsecureLoopback: false)
        switch action {
        case "cancel": app.cancelLogin()
        case "task": probe.cancel()
        case "shutdown": await app.shutdownAll()
        default: #expect(await app.beginLogin(serverText: newer.description) == nil)
        }
        await release.open()
        #expect(await probe.value == nil)
        if action == "replace" {
            guard case .login(let login) = app.phase else { Issue.record("New login disappeared"); return }
            #expect(login.discovery.endpoint == newer)
        } else if case .login = app.phase {
            Issue.record("Cancelled discovery reopened login")
        }
        app.cancelLogin()
        await app.shutdownAll()
    }

    private struct Factory: MattermostServiceFactory {
        let started: Gate
        let release: Gate
        let fails: Bool
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService {
            Discovery(endpoint: endpoint, started: started, release: release, fails: fails)
        }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService {
            FakeMattermostService(endpoint: endpoint, me: CoreFixtures.me)
        }
    }

    /// Intentionally ignores cancellation while ping is suspended.
    private struct Discovery: MattermostDiscoveryService {
        let endpoint: ServerEndpoint
        let started: Gate
        let release: Gate
        let fails: Bool
        func ping() async throws(APIError) -> ServerVersion? {
            if endpoint == CoreFixtures.endpoint {
                await started.open()
                await release.wait()
                if fails { throw .notSent(.offline) }
            }
            return nil
        }
        func limitedConfiguration() async throws(APIError) -> ServerCapabilities { ServerCapabilities() }
        func login(_ request: LoginRequest) async throws(LoginFailure) -> LoginResult { throw .invalidCredentials }
        func loginWithDesktopCode(_ code: DesktopLoginCode) async throws(APIError) -> LoginResult { throw .cancelled }
        func shutdown() async {}
    }
}
