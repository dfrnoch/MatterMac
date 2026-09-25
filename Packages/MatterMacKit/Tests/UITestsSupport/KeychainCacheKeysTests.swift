import Foundation
import Testing
import MatterMacModels
import MatterMacCore
import MatterMacPlatform
import TestSupport

/// Real login-Keychain round trip for the cache keys, under a throwaway service name.
@Suite("Keychain cache keys", .enabled(if: ProcessInfo.processInfo.environment["MM_KEYCHAIN_TESTS"] == "1"))
struct KeychainCacheKeysTests {
    @Test func createsReadsAndRemovesPerAccountKeys() async throws {
        let keys = KeychainCacheKeys(service: "org.mattermac.tests.cache." + UUID().uuidString)
        let first = CacheAccount(endpoint: CoreFixtures.endpoint, user: CoreFixtures.me.id)
        let second = CacheAccount(endpoint: CoreFixtures.endpoint, user: CoreFixtures.bob.id)
        #expect(await keys.key(for: first, create: false) == nil)
        let created = try #require(await keys.key(for: first, create: true))
        #expect(created.count == 32)
        #expect(await keys.key(for: first, create: false) == created)
        let other = try #require(await keys.key(for: second, create: true))
        #expect(other != created)
        await keys.removeKey(for: first)
        #expect(await keys.key(for: first, create: false) == nil)
        #expect(await keys.key(for: second, create: false) == other)
        await keys.removeAllKeys()
        #expect(await keys.key(for: second, create: false) == nil)
    }
}
