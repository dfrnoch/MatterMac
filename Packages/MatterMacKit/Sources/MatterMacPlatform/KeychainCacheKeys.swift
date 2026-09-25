public import Foundation
import Security
public import MatterMacCore

/// One random 256-bit key per cached account, in the Mac's login Keychain (never
/// synchronized). `ContentCache` encrypts every cached file with it; deleting the key
/// on Sign Out makes any leftover cached bytes unreadable.
public actor KeychainCacheKeys: CacheKeyStore {
    private let service: String
    /// Deleting every key is bounded even if the Keychain keeps reporting matches.
    private static let maximumDeletions = 64

    public init(service: String = "org.mattermac.MatterMac.cache-keys") {
        self.service = service
    }

    private func query(_ account: CacheAccount?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: false]
        if let account { query[kSecAttrAccount as String] = account.identifier }
        return query
    }

    public func key(for account: CacheAccount, create: Bool) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard create, status == errSecItemNotFound || status == errSecSuccess else { return nil }
        if status == errSecSuccess { SecItemDelete(query(account) as CFDictionary) } // malformed key
        var bytes = Data(count: 32)
        let generated = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard generated == errSecSuccess else { return nil }
        var item = query(account)
        item[kSecValueData as String] = bytes
        item[kSecAttrLabel as String] = "MatterMac cache key"
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return nil }
        return bytes
    }

    public func removeKey(for account: CacheAccount) {
        SecItemDelete(query(account) as CFDictionary)
    }

    public func removeAllKeys() {
        var deletions = 0
        while deletions < Self.maximumDeletions, SecItemDelete(query(nil) as CFDictionary) == errSecSuccess {
            deletions += 1
        }
    }
}
