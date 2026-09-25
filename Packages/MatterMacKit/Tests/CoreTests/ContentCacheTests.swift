import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("On-device content cache")
struct ContentCacheTests {
    let scope = AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id)
    var account: CacheAccount { CacheAccount(endpoint: CoreFixtures.endpoint, user: CoreFixtures.me.id) }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mattermac-cache-\(UUID().uuidString)", isDirectory: true)
    }

    func makeCache(_ directory: URL, keys: InMemoryCacheKeys, budget: ResourceBudget = .standard) -> ContentCache {
        ContentCache(storage: .init(directory: directory, keys: keys), budget: budget,
                     diagnostics: DiagnosticRing(byteBudget: 1_024))
    }

    func files(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    @Test func encryptsSurvivesRelaunchAndIgnoresUnregisteredScopes() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryCacheKeys()
        let secret = Data("A clear, native conversation about the release".utf8)
        let cache = makeCache(directory, keys: keys)
        await cache.store(secret, .channel, "channel/one", scope: scope)
        #expect(await cache.usage.files == 0, "Nothing is written before the scope is registered")
        await cache.register(scope, as: account)
        await cache.store(secret, .channel, "channel/one", scope: scope)
        #expect(await cache.data(.channel, "channel/one", scope: scope) == secret)
        // On disk: one file under a digest directory, with no plaintext or names.
        let stored = files(in: directory)
        #expect(stored.count == 1)
        let bytes = try Data(contentsOf: try #require(stored.first))
        #expect(bytes.range(of: Data("release".utf8)) == nil)
        #expect(!stored[0].path.contains("channel/one") && !stored[0].path.contains(CoreFixtures.me.id.rawValue))
        #expect(stored[0].path.contains(account.identifier))

        // A new instance (relaunch) rebuilds its index from disk.
        let relaunched = makeCache(directory, keys: keys)
        await relaunched.register(scope, as: account)
        #expect(await relaunched.data(.channel, "channel/one", scope: scope) == secret)
        #expect(await relaunched.usage.files == 1)
        // The name is authenticated: another entry's name does not open this file.
        #expect(await relaunched.data(.channel, "channel/two", scope: scope) == nil)
    }

    @Test func unreadableFilesAreDeletedAndSignOutRemovesFilesAndKey() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryCacheKeys()
        let cache = makeCache(directory, keys: keys)
        await cache.register(scope, as: account)
        await cache.store(Data([1, 2, 3]), .image, "profile/a/1", scope: scope)
        await cache.store(Data([4, 5, 6]), .directory, "directory", scope: scope)
        #expect(await keys.keys[account] != nil)

        // Tampered bytes fail authentication and the file is removed.
        let file = try #require(files(in: directory).first { $0.pathComponents.contains("image") })
        var sealed = try Data(contentsOf: file)
        sealed[sealed.count - 1] ^= 0xff
        try sealed.write(to: file)
        #expect(await cache.data(.image, "profile/a/1", scope: scope) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Without the key (a new key store), nothing can be read.
        let otherKeys = InMemoryCacheKeys()
        let stranger = makeCache(directory, keys: otherKeys)
        await stranger.register(scope, as: account)
        #expect(await stranger.data(.directory, "directory", scope: scope) == nil)

        await cache.removeAll(for: account)
        #expect(files(in: directory).isEmpty)
        #expect(await keys.keys[account] == nil)
        #expect(await cache.data(.directory, "directory", scope: scope) == nil)
        await cache.store(Data([7]), .directory, "directory", scope: scope)
        #expect(files(in: directory).isEmpty, "A signed-out scope writes nothing")
    }

    @Test func mediaAndContentAreBoundedLeastRecentlyUsedFirst() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var budget = ResourceBudget.standard
        budget.diskCache.mediaBytes = 3 * 1_100
        budget.diskCache.contentEntries = 2
        budget.diskCache.perObjectBytes = 2_000
        let cache = makeCache(directory, keys: InMemoryCacheKeys(), budget: budget)
        await cache.register(scope, as: account)
        let image = Data(repeating: 7, count: 1_000)
        for n in 1...3 { await cache.store(image, .image, "thumbnail/\(n)", scope: scope) }
        _ = await cache.data(.image, "thumbnail/1", scope: scope) // most recently used now
        await cache.store(image, .image, "thumbnail/4", scope: scope)
        #expect(await cache.data(.image, "thumbnail/2", scope: scope) == nil)
        #expect(await cache.data(.image, "thumbnail/1", scope: scope) == image)
        #expect(await cache.data(.image, "thumbnail/4", scope: scope) == image)
        await cache.store(Data(repeating: 1, count: 3_000), .image, "preview/huge", scope: scope)
        #expect(await cache.data(.image, "preview/huge", scope: scope) == nil, "Over the per-object limit")

        for n in 1...3 { await cache.store(Data([UInt8(n)]), .channel, "channel/\(n)", scope: scope) }
        #expect(await cache.data(.channel, "channel/1", scope: scope) == nil)
        #expect(await cache.usage.files == 3 + 2)
        #expect(files(in: directory).count == 5)

        await cache.removeEverything()
        #expect(files(in: directory).isEmpty)
        // Running scopes keep working with a new key.
        await cache.store(Data([9]), .channel, "channel/9", scope: scope)
        #expect(await cache.data(.channel, "channel/9", scope: scope) == Data([9]))
    }

    @Test func imagesComeFromDiskAfterRelaunchButProxiedImagesNeverDo() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryCacheKeys()
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let png = CoreFixtures.png(width: 64, height: 64)
        service.withState { $0.imageHandler = { _, _ in png } }
        let avatar = ImageResource.profileImage(CoreFixtures.bob.id, revision: 5)
        let proxied = ImageResource.proxiedImage(url: "https://example.org/a.png")
        do {
            let cache = makeCache(directory, keys: keys)
            await cache.register(scope, as: account)
            let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024), cache: cache)
            #expect(await pipeline.image(for: .init(scope: scope, resource: avatar, maxPixelSize: 32), using: service) != nil)
            #expect(await pipeline.image(for: .init(scope: scope, resource: proxied, maxPixelSize: 32), using: service) != nil)
            #expect(await cache.usage.files == 1)
        }
        #expect(service.calls.filter { $0 == "imageData" }.count == 2)
        let cache = makeCache(directory, keys: keys)
        await cache.register(scope, as: account)
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024), cache: cache)
        // A different display size decodes the same cached bytes.
        let image = await pipeline.image(for: .init(scope: scope, resource: avatar, maxPixelSize: 48), using: service)
        #expect(image?.image.width == 48)
        #expect(service.calls.filter { $0 == "imageData" }.count == 2, "The avatar came from disk")
        _ = await pipeline.image(for: .init(scope: scope, resource: proxied, maxPixelSize: 32), using: service)
        #expect(service.calls.filter { $0 == "imageData" }.count == 3, "Proxied images are always fetched")
    }
}
