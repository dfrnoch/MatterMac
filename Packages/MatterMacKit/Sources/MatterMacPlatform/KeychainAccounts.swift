import Foundation
import Security
public import MatterMacModels

/// The only persistent app state: verified sign-ins, in the Mac's login Keychain.
public actor KeychainAccounts {
    public struct Account: Sendable, CustomReflectable {
        public let endpoint: ServerEndpoint
        public let userID: UserID
        public let credential: BearerCredential
        public init(endpoint: ServerEndpoint, userID: UserID, credential: BearerCredential) {
            self.endpoint = endpoint; self.userID = userID; self.credential = credential
        }
        public var customMirror: Mirror { Mirror(self, children: ["account": "<redacted>"]) }
    }

    public enum Failure: Error, Sendable { case keychain(Int32), invalidData, capacity }
    private struct Record: Codable {
        let server: String
        let user: String
        let token: String
        let personalAccessToken: Bool
    }
    private struct Envelope: Codable { let version: Int; let accounts: [Record] }
    private let service: String
    private let budget: ResourceBudget
    private let allowsInsecureLoopback: Bool

    public init(service: String = "org.mattermac.MatterMac.accounts", budget: ResourceBudget = .standard,
                allowsInsecureLoopback: Bool = false) {
        self.service = service; self.budget = budget; self.allowsInsecureLoopback = allowsInsecureLoopback
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "accounts-v1",
         kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> [Account] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data, data.count <= budget.rememberedAccountBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              envelope.accounts.count <= budget.connectedSessions else { throw Failure.invalidData }
        var accounts: [Account] = []
        for record in envelope.accounts {
            guard let endpoint = try? ServerURLNormalizer.normalize(record.server, allowInsecureLoopback: allowsInsecureLoopback),
                  endpoint.description == record.server, let user = UserID(rawValue: record.user),
                  let credential = BearerCredential(token: record.token, kind: record.personalAccessToken ? .personalAccessToken : .session),
                  !accounts.contains(where: { $0.endpoint == endpoint && $0.userID == user })
            else { throw Failure.invalidData }
            accounts.append(Account(endpoint: endpoint, userID: user, credential: credential))
        }
        return accounts
    }

    public func save(_ account: Account) throws {
        var accounts = try load()
        accounts.removeAll { $0.endpoint == account.endpoint && $0.userID == account.userID }
        guard accounts.count < budget.connectedSessions else { throw Failure.capacity }
        accounts.append(account)
        try write(accounts)
    }

    public func remove(endpoint: ServerEndpoint, userID: UserID) throws {
        let accounts = try load()
        let remaining = accounts.filter { $0.endpoint != endpoint || $0.userID != userID }
        guard remaining.count != accounts.count else { return }
        try write(remaining)
    }

    private func write(_ accounts: [Account]) throws {
        if accounts.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
            return
        }
        let records = accounts.map {
            Record(server: $0.endpoint.description, user: $0.userID.rawValue,
                   token: String($0.credential.authorizationHeaderValue.dropFirst("Bearer ".count)),
                   personalAccessToken: $0.credential.kind == .personalAccessToken)
        }
        let data = try JSONEncoder().encode(Envelope(version: 1, accounts: records))
        guard data.count <= budget.rememberedAccountBytes else { throw Failure.capacity }
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
