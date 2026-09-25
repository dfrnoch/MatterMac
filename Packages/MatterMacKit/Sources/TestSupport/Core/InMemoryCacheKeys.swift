public import Foundation
public import MatterMacCore

/// Cache keys held in memory, for tests that must not touch the Keychain.
public actor InMemoryCacheKeys: CacheKeyStore {
    public private(set) var keys: [CacheAccount: Data] = [:]

    public init() {}

    public func key(for account: CacheAccount, create: Bool) -> Data? {
        if let key = keys[account] { return key }
        guard create else { return nil }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        keys[account] = key
        return key
    }

    public func removeKey(for account: CacheAccount) { keys[account] = nil }
    public func removeAllKeys() { keys.removeAll() }
}
