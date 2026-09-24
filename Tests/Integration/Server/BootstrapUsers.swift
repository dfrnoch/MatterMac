// Development-only. Credentials arrive through the ignored environment file,
// never process arguments. This helper only accepts repository loopback servers.
import Foundation
import Darwin

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum BootstrapFailure: Error { case configuration, response, request }
struct User: Decodable {
    let id: String
    let username: String
    let roles: String
}

@MainActor
func bootstrapUsers() async throws {
    let endpoints = ["mm11": "http://127.0.0.1:8065", "mm11sub": "http://127.0.0.1:8066/company/chat", "mm10": "http://127.0.0.1:8067"]
    guard CommandLine.arguments.count == 2, let endpoint = endpoints[CommandLine.arguments[1]] else {
        throw BootstrapFailure.configuration
    }
    let fixtureUsers = [("mmadmin", "admin", "ADMIN"), ("alice", "alice", "ALICE"),
                        ("bob", "bob", "BOB"), ("carol", "carol", "CAROL")]
    var passwords: [String: String] = [:]
    for (username, _, key) in fixtureUsers {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_\(key)_PASSWORD"],
              !password.isEmpty, password.utf8.count <= 256 else { throw BootstrapFailure.configuration }
        passwords[username] = password
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var token: String?

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: URL(string: endpoint + "/api/v4/" + path)!)
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw BootstrapFailure.response }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 128 * 1_024 else { throw BootstrapFailure.response }
            data.append(byte)
        }
        return (response, data)
    }

    func create(_ username: String, emailName: String) async throws -> User {
        let (response, data) = try await request("POST", "users", body: [
            "username": username, "email": emailName + "@mattermac.test", "password": passwords[username]!,
            "email_verified": true, "disable_welcome_email": true,
        ])
        guard response.statusCode == 201 else { throw BootstrapFailure.request }
        return try JSONDecoder().decode(User.self, from: data)
    }

    let loginBody: [String: Any] = ["login_id": "mmadmin", "password": passwords["mmadmin"]!]
    var createdAdmin: User?
    var login = try await request("POST", "users/login", body: loginBody)
    if login.0.statusCode == 401 {
        // Only an uninitialized server accepts creation of its first administrator.
        // An existing admin with a mismatched password fails; no password is reset.
        let admin = try await create("mmadmin", emailName: "admin")
        guard admin.username == "mmadmin", admin.roles.split(separator: " ").contains("system_admin") else {
            throw BootstrapFailure.response
        }
        createdAdmin = admin
        login = try await request("POST", "users/login", body: loginBody)
    }
    guard login.0.statusCode == 200, let value = login.0.value(forHTTPHeaderField: "Token"),
          !value.isEmpty else { throw BootstrapFailure.request }
    token = value
    do {
        let admin = try JSONDecoder().decode(User.self, from: login.1)
        guard admin.username == "mmadmin", admin.roles.split(separator: " ").contains("system_admin") else {
            throw BootstrapFailure.response
        }
        func verifyNewUser(_ user: User) async throws {
            guard !user.id.isEmpty, user.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
                throw BootstrapFailure.response
            }
            let (response, _) = try await request("POST", "users/" + user.id + "/email/verify/member")
            guard response.statusCode == 200 else { throw BootstrapFailure.request }
        }
        if let createdAdmin { try await verifyNewUser(createdAdmin) }
        for (username, emailName, _) in fixtureUsers.dropFirst() {
            let (response, data) = try await request("GET", "users/username/" + username)
            switch response.statusCode {
            case 200:
                guard try JSONDecoder().decode(User.self, from: data).username == username else {
                    throw BootstrapFailure.response
                }
            case 404:
                let user = try await create(username, emailName: emailName)
                guard user.username == username, user.roles == "system_user" else { throw BootstrapFailure.response }
                try await verifyNewUser(user)
            default: throw BootstrapFailure.request
            }
        }
    } catch {
        _ = try? await request("POST", "users/logout")
        throw error
    }
    let (logout, _) = try await request("POST", "users/logout")
    guard logout.statusCode == 200 else { throw BootstrapFailure.request }
}

do {
    try await bootstrapUsers()
} catch {
    // Never print server bodies, decoded users, credentials, or raw system errors.
    FileHandle.standardError.write(Data("Local user provisioning failed. Check server readiness and the ignored test environment file.\n".utf8))
    exit(1)
}
