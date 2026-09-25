import Foundation
public import MatterMacModels

/// The on-device cache (`ContentCache`): the directory is restored before the first
/// request so the sidebar appears at once, and a channel opened without a retained
/// window first shows its cached latest posts. The server's answers replace both.
/// Writes are coalesced (at most one pass every few seconds) and encoded off the
/// session actor. Unsent work is never written: pending sends live outside the store.
extension ServerSession {
    struct CachedDirectory: Codable, Sendable {
        var directory: DirectoryStore.CacheSnapshot
        var selectedTeam: TeamID?
        var activeChannel: ChannelID?
        var cachedChannels: [ChannelID]
    }

    struct CachedChannel: Codable, Sendable {
        /// Oldest → newest.
        var posts: [Post]
        /// Thread roots the posts reply to, for "replied to" context.
        var related: [Post]
        var hasOlder: Bool
    }

    static let directoryCacheName = "directory"
    static func channelCacheName(_ id: ChannelID) -> String { "channel/" + id.rawValue }
    static let cacheWriteDelay: Duration = .seconds(4)

    var cacheAccount: CacheAccount { CacheAccount(endpoint: endpoint, user: me.id) }

    // MARK: Restoring

    /// Registers with the cache and restores the cached directory (session start).
    func restoreFromCache() async {
        guard let cache = deps.contentCache else { return }
        await cache.register(scope, as: cacheAccount)
        guard isActiveSessionAlive, let data = await cache.data(.directory, Self.directoryCacheName, scope: scope) else {
            return
        }
        guard let cached = await Self.decode(CachedDirectory.self, from: data), isActiveSessionAlive,
              directory.teams.isEmpty else { return }
        directory.restore(cached.directory)
        directory.pin(me)
        if let team = cached.selectedTeam, directory.teams[team] != nil { selectedTeam = team }
        if let channel = cached.activeChannel, directory.channels[channel] != nil { restoredChannel = channel }
        cachedChannels = Array(cached.cachedChannels.prefix(budget.diskCache.channelsPerAccount))
        deps.diagnostics.record(.lifecycle, .info, "directory restored from cache")
        markDirty([.sidebar, .settings])
    }

    /// Shows the channel's cached posts while its first page loads. Only an empty
    /// window of a channel the user is still a member of is seeded.
    func seedWindowFromCache(_ target: TimelineTarget, generation: UInt64) async {
        guard let cache = deps.contentCache, case .channel(let id) = target, cachedChannels.contains(id),
              windows[target]?.isEmpty == true else { return }
        guard let data = await cache.data(.channel, Self.channelCacheName(id), scope: scope),
              let cached = await Self.decode(CachedChannel.self, from: data) else { return }
        guard isActiveSessionAlive, var window = windows[target], window.isEmpty,
              window.initialLoad == .loading(generation: generation), directory.memberships[id] != nil else { return }
        let crt = collapsedThreadsActive
        let posts = cached.posts.filter { $0.channelID == id }
        for post in posts + cached.related where post.channelID == id { store.upsert(post) }
        let entries = posts.filter { !crt || $0.rootID == nil }.map { HistoryWindow.Entry(id: $0.id, createAt: $0.createAt) }
        guard !entries.isEmpty else { return }
        for added in window.seed(with: entries, hasOlder: cached.hasOlder) { store.retain(added) }
        windows[target] = window
        enforceRetention()
        markDirty([.timeline])
    }

    // MARK: Writing

    func scheduleCacheWrite(directory: Bool = false, channel: ChannelID? = nil) {
        guard deps.contentCache != nil, isActiveSessionAlive else { return }
        if directory { cacheDirectoryPending = true }
        if let channel { cacheChannelsPending.insert(channel) }
        guard !isRunning(.cacheWrite) else { return }
        run(.cacheWrite) { session in
            try? await session.deps.clock.sleep(for: Self.cacheWriteDelay)
            guard !Task.isCancelled else { return }
            await session.writePendingCache()
        }
    }

    /// Writes everything worth keeping now (the app is quitting).
    public func persistCache() async {
        guard deps.contentCache != nil, isActiveSessionAlive else { return }
        tasks[.cacheWrite]?.cancel()
        cacheDirectoryPending = true
        for case .channel(let id) in windows.keys { cacheChannelsPending.insert(id) }
        await writePendingCache()
    }

    func writePendingCache() async {
        guard let cache = deps.contentCache, isActiveSessionAlive else { return }
        let scope = scope
        let channels = cacheChannelsPending
        cacheChannelsPending = []
        var removed: [ChannelID] = []
        for id in channels {
            guard let value = cachedChannelValue(id) else { continue }
            cachedChannels.removeAll { $0 == id }
            cachedChannels.insert(id, at: 0)
            while cachedChannels.count > budget.diskCache.channelsPerAccount { removed.append(cachedChannels.removeLast()) }
            cacheDirectoryPending = true
            if let data = await Self.encode(value), isActiveSessionAlive {
                await cache.store(data, .channel, Self.channelCacheName(id), scope: scope)
            }
        }
        for id in removed { await cache.remove(.channel, Self.channelCacheName(id), scope: scope) }
        guard cacheDirectoryPending, isActiveSessionAlive else { return }
        cacheDirectoryPending = false
        let value = CachedDirectory(directory: directory.cacheSnapshot(), selectedTeam: selectedTeam,
                                    activeChannel: activeChannel ?? restoredChannel, cachedChannels: cachedChannels)
        if let data = await Self.encode(value), isActiveSessionAlive {
            await cache.store(data, .directory, Self.directoryCacheName, scope: scope)
        }
    }

    /// The newest posts of a channel window that is current (loaded from the server
    /// and at the live edge); `nil` when there is nothing trustworthy to keep.
    func cachedChannelValue(_ id: ChannelID) -> CachedChannel? {
        guard let window = windows[.channel(id)], window.isLoaded, !window.isCached, !window.hasNewer,
              directory.memberships[id] != nil else { return nil }
        let kept = window.entries.suffix(budget.diskCache.postsPerChannel)
        let ids = Set(kept.map(\.id))
        let posts = kept.compactMap { store.post($0.id) }
        guard !posts.isEmpty else { return nil }
        let roots = Set(posts.compactMap(\.rootID)).subtracting(ids).compactMap { store.post($0) }
        return CachedChannel(posts: posts, related: roots, hasOlder: window.hasOlder || kept.count < window.entries.count)
    }

    /// Drops a channel's cached posts (membership revoked, channel gone).
    func removeCachedChannel(_ id: ChannelID) {
        guard let cache = deps.contentCache, cachedChannels.contains(id) else { return }
        cachedChannels.removeAll { $0 == id }
        cacheChannelsPending.remove(id)
        cacheDirectoryPending = true
        let scope = scope
        Task { await cache.remove(.channel, Self.channelCacheName(id), scope: scope) }
    }

    // MARK: Coding

    @concurrent
    static func encode<Value: Encodable & Sendable>(_ value: Value) async -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(value)
    }

    @concurrent
    static func decode<Value: Decodable & Sendable>(_ type: Value.Type, from data: Data) async -> Value? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
