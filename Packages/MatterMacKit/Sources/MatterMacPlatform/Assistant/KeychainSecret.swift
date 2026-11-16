import Foundation
import Security

/// One user-entered secret (the Claude API key) in the Mac's login Keychain, never
/// synchronized. Read at request time; never shown again after it is saved.
public struct KeychainSecret: Sendable {
    private let service: String
    private let account: String
    /// Longest secret accepted.
    public static let maximumBytes = 512

    public init(service: String = "org.mattermac.MatterMac.assistant", account: String) {
        self.service = service
        self.account = account
    }

    public static let claudeAPIKey = KeychainSecret(account: "claude-api-key")

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    public func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              data.count <= Self.maximumBytes, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    public var exists: Bool { read() != nil }

    /// Saves a secret of printable ASCII without spaces; anything else is refused.
    @discardableResult
    public func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumBytes,
              trimmed.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrLabel as String] = "MatterMac assistant key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
