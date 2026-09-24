import Foundation
import Testing
import os
import MatterMacModels
import MatterMacCore
import MatterMacPlatform
import MattermostAPI
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Keychain sign-in lifecycle", .enabled(if: ProcessInfo.processInfo.environment["MM_KEYCHAIN_TESTS"] == "1"))
struct KeychainSignInTests {
    private func store() -> KeychainAccounts {
        KeychainAccounts(service: "org.mattermac.tests." + UUID().uuidString)
    }

    private func app(_ accounts: KeychainAccounts, mode: OSAllocatedUnfairLock<String>, calls: OSAllocatedUnfairLock<[String]>) -> AppModel {
        let factory = DefaultMattermostServiceFactory(budget: .standard, diagnostics: nil,
            retryPolicy: .standard, clock: ImmediateClock()) { _ in
            FakeHTTPTransport { request in
                calls.withLock { $0.append(request.url.path) }
                let state = mode.withLock { $0 }
                if state == "offline" { return .failure(.notSent(.cannotConnect)) }
                if request.url.path.hasSuffix("/system/ping") { return .json(#"{"status":"OK"}"#) }
                if request.url.path.hasSuffix("/config/client") { return .json(#"{"Version":"10.11.9"}"#) }
                if request.url.path.hasSuffix("/users/me") {
                    if state == "expired" { return .appError(401, id: "api.context.session_expired.app_error") }
                    let id = state == "mismatch" ? CoreFixtures.bob.id : CoreFixtures.me.id
                    return .json("{\"id\":\"\(id.rawValue)\",\"username\":\"fixture\"}")
                }
                if request.url.path.hasSuffix("/users/logout") { return .json(#"{"status":"OK"}"#) }
                return .json("[]")
            }
        }
        return AppModel(environment: AppEnvironment(accounts: accounts, serviceFactory: factory,
            makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { MarkupParser.parse($0, limits: $1) }))
    }

    @Test(arguments: [BearerCredential.Kind.session, .personalAccessToken])
    func loginQuitRestoreSignOut(_ kind: BearerCredential.Kind) async throws {
        let accounts = store()
        let mode = OSAllocatedUnfairLock(initialState: "valid")
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let first = app(accounts, mode: mode, calls: calls)
        let discovery = try await first.loginCoordinator.discover(CoreFixtures.endpoint)
        let credential = BearerCredential(token: "synthetic-keychain-fixture", kind: kind)!
        try await first.completeLogin(LoginResult(credential: credential, user: CoreFixtures.me), discovery: discovery)
        let saved = try await accounts.load()
        #expect(saved.count == 1 && saved.first?.credential == credential)
        await first.shutdownAll(preservingSavedSignIns: true)
        #expect(!calls.withLock { $0.contains(where: { $0.hasSuffix("/users/logout") }) })
        let second = app(accounts, mode: mode, calls: calls)
        await second.restoreSavedAccounts()
        #expect(second.activeSession?.scope.user == CoreFixtures.me.id)
        let slot = try #require(second.activeSlotID)
        #expect(await second.signOut(slot))
        #expect(try await accounts.load().isEmpty)
        #expect(calls.withLock { $0.filter { $0.hasSuffix("/users/logout") }.count } == (kind == .session ? 1 : 0))
        await second.shutdownAll()
    }

    @Test(arguments: ["offline", "expired", "mismatch"])
    func restoreFailureAndRetry(_ scenario: String) async throws {
        let accounts = store()
        try await accounts.save(.init(endpoint: CoreFixtures.endpoint, userID: CoreFixtures.me.id,
                                      credential: BearerCredential(token: "synthetic-fixture", kind: .session)!))
        let mode = OSAllocatedUnfairLock(initialState: scenario)
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let model = app(accounts, mode: mode, calls: calls)
        await model.restoreSavedAccounts()
        #expect(model.slots.isEmpty)
        #expect(try await accounts.load().count == (scenario == "offline" ? 1 : 0))
        #expect(!calls.withLock { $0.contains(where: { $0.hasSuffix("/users/logout") }) })
        if scenario == "offline" {
            #expect(model.canRetrySavedSignIn)
            mode.withLock { $0 = "valid" }
            await model.restoreSavedAccounts(retry: true)
            let session = try #require(model.activeSession)
            await session.handleNotice(.signedOutByServer)
            #expect(try await accounts.load().isEmpty)
        }
        await model.shutdownAll(preservingSavedSignIns: true)
    }

    @Test func boundedAccountsUpdateAndScopedRemoval() async throws {
        let service = "org.mattermac.tests." + UUID().uuidString
        var budget = ResourceBudget.standard
        budget.connectedSessions = 2
        let accounts = KeychainAccounts(service: service, budget: budget)
        let a = KeychainAccounts.Account(endpoint: CoreFixtures.endpoint, userID: CoreFixtures.me.id,
                                        credential: BearerCredential(token: "first", kind: .session)!)
        let b = KeychainAccounts.Account(endpoint: CoreFixtures.endpoint, userID: CoreFixtures.bob.id,
                                        credential: BearerCredential(token: "second", kind: .personalAccessToken)!)
        try await accounts.save(a)
        try await accounts.save(b)
        try await accounts.save(a)
        await #expect(throws: KeychainAccounts.Failure.self) {
            try await accounts.save(.init(endpoint: ServerURLNormalizer.normalize("https://another.example.test", allowInsecureLoopback: false),
                                          userID: CoreFixtures.me.id, credential: a.credential))
        }
        let fresh = KeychainAccounts(service: service, budget: budget)
        #expect(try await fresh.load().count == 2)
        try await fresh.remove(endpoint: a.endpoint, userID: a.userID)
        #expect(try await accounts.load().first?.credential == b.credential)
        try await fresh.remove(endpoint: b.endpoint, userID: b.userID)
        #expect(try await accounts.load().isEmpty)
    }

    // Two invocations exercise an actual process boundary, with synthetic data only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM_KEYCHAIN_PROCESS_PHASE"] != nil))
    func processRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        let service = try #require(env["MM_KEYCHAIN_TEST_SERVICE"])
        #expect(service.hasPrefix("org.mattermac.tests."))
        guard service.hasPrefix("org.mattermac.tests.") else { return }
        let accounts = KeychainAccounts(service: service)
        let record = KeychainAccounts.Account(endpoint: CoreFixtures.endpoint, userID: CoreFixtures.me.id,
                                              credential: BearerCredential(token: "synthetic-restart", kind: .session)!)
        if env["MM_KEYCHAIN_PROCESS_PHASE"] == "write" { try await accounts.save(record) }
        else {
            let saved = try await accounts.load()
            #expect(saved.count == 1 && saved.first?.credential == record.credential)
            try await accounts.remove(endpoint: record.endpoint, userID: record.userID)
            #expect(try await accounts.load().isEmpty)
        }
    }
}
