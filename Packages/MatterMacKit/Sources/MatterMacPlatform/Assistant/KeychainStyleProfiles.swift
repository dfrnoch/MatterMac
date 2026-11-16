import Foundation
import Security
public import MatterMacCore

/// Learned writing-style profiles, one Keychain item per account (never
/// synchronized). A profile describes how the user writes and may quote short
/// phrases of theirs, so it is kept like a credential and deleted at Sign Out.
public struct KeychainStyleProfiles: StyleProfileStore {
    private let service: String
    /// Largest stored item (a profile is at most `StyleProfile.maximumCharacters`).
    static let maximumBytes = 16 * 1_024

    public init(service: String = "org.mattermac.MatterMac.style-profiles") {
        self.service = service
    }

    private func query(_ account: CacheAccount) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account.identifier, kSecAttrSynchronizable as String: false]
    }

    public func profile(for account: CacheAccount) -> StyleProfile? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              data.count <= Self.maximumBytes,
              let profile = try? JSONDecoder().decode(StyleProfile.self, from: data), !profile.text.isEmpty,
              profile.text.count <= StyleProfile.maximumCharacters else { return nil }
        return profile
    }

    public func save(_ profile: StyleProfile, for account: CacheAccount) {
        guard let data = try? JSONEncoder().encode(profile), data.count <= Self.maximumBytes else { return }
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MatterMac writing style"
        SecItemAdd(item as CFDictionary, nil)
    }

    public func removeProfile(for account: CacheAccount) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
