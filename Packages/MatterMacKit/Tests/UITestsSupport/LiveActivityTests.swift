import AppKit
import Foundation
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
@testable import MatterMacUI

/// Opt-in: an activity report over MatterMac's real socket refreshes the account's
/// `last_activity_at` on the server, which is what keeps it from turning "away".
/// Nothing else that refreshes it (posting, viewing a channel) happens here.
@MainActor
@Suite("Live user activity", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveActivityTests {
    enum Failure: Error { case missingCredentials, login, deadline, status }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8067"])
    func activityRefreshesTheServersLastActivity(base: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_ALICE_PASSWORD"] else {
            throw Failure.missingCredentials
        }
        _ = NSApplication.shared
        let app = AppModel(environment: AppEnvironment(allowsInsecureLoopback: true,
            serviceFactory: DefaultMattermostServiceFactory(),
            makeRealtime: { MattermostRealtimeClient(endpoint: $0, credential: $1, currentUserID: $2) },
            markupParse: { MarkupParser.parse($0, limits: $1) }))
        guard await app.beginLogin(serverText: base) == nil, case .login(let login) = app.phase else { throw Failure.login }
        login.loginID = "alice"
        login.password = password
        await login.submit()
        guard let model = app.activeSession else { await app.shutdownAll(); throw Failure.login }
        defer { Task { await app.shutdownAll() } }
        let deadline = ContinuousClock.now + .seconds(15)
        while model.connection != .connected {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(50))
        }
        let status = StatusReader(base: base, userID: model.scope.user)
        try await status.signIn(password: password)
        try await Task.sleep(for: .seconds(2))
        let before = try await status.lastActivity()
        // Control: without a report, nothing else moves it.
        try await Task.sleep(for: .seconds(2))
        #expect(try await status.lastActivity() == before)
        model.userActivity(isActive: true)
        var after = before
        let reportDeadline = ContinuousClock.now + .seconds(5)
        while after <= before, ContinuousClock.now < reportDeadline {
            try await Task.sleep(for: .milliseconds(200))
            after = try await status.lastActivity()
        }
        #expect(after > before, "The server did not see the activity report")
        #expect(try await status.status() == "online")
    }

    /// Reads `/users/{id}/status` with a separate REST session of the same user.
    private final class StatusReader {
        let base: String
        let userID: UserID
        private var token = ""
        private let session = URLSession(configuration: .ephemeral)

        init(base: String, userID: UserID) {
            self.base = base
            self.userID = userID
        }

        func signIn(password: String) async throws {
            var request = URLRequest(url: URL(string: base + "/api/v4/users/login")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": "alice", "password": password])
            let (_, response) = try await session.data(for: request)
            guard let token = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Token") else { throw Failure.login }
            self.token = token
        }

        private func object() async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: base + "/api/v4/users/\(userID.rawValue)/status")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, _) = try await session.data(for: request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.status }
            return object
        }

        func lastActivity() async throws -> Int64 {
            guard let value = try await object()["last_activity_at"] as? NSNumber else { throw Failure.status }
            return value.int64Value
        }

        func status() async throws -> String? { try await object()["status"] as? String }
    }
}
