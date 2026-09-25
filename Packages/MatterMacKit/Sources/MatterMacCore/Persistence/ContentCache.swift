public import Foundation
import CryptoKit
public import MatterMacModels

/// The on-disk identity of a signed-in account: server and user. Runtime slot
/// numbers (`AccountScope.server`) change between launches; this does not. The value
/// is a SHA-256 digest, so directory names reveal neither the server nor the user.
public struct CacheAccount: Hashable, Sendable, CustomStringConvertible {
    public let identifier: String

    public init(endpoint: ServerEndpoint, user: UserID) {
        identifier = ContentCache.digest(endpoint.description + "\n" + user.rawValue)
    }

    public var description: String { identifier }
}

/// Holds one 256-bit key per cached account (the app uses the Keychain). Removing an
/// account's key makes its cached files unreadable even before they are deleted.
public protocol CacheKeyStore: Sendable {
    /// The account's key; with `create`, a missing key is generated and saved.
    func key(for account: CacheAccount, create: Bool) async -> Data?
    func removeKey(for account: CacheAccount) async
    func removeAllKeys() async
}

/// Encrypted, bounded on-device cache for content that makes MatterMac fast to open:
/// image bytes (avatars, team icons, thumbnails, previews, custom emoji), the
/// directory (teams, channels, memberships, categories, profiles) and the latest
/// messages of recently opened channels.
///
/// - Every file is sealed with AES-GCM under its account's key; the kind and name are
///   authenticated, so a file cannot be moved to another entry. A file that fails to
///   open is deleted.
/// - Two cost-tracked LRUs bound the cache: media bytes and structured content bytes,
///   each with an entry count. Recency survives relaunch through file modification
///   dates. Nothing here is unsent work: evicting any entry only costs a refetch.
/// - Cached content is a starting point, never the truth: sessions show it at once
///   and replace it with the server's answer.
/// - Sign Out removes the account's directory and key; Clear Cache removes everything.
public actor ContentCache {
    public enum Kind: String, Sendable, CaseIterable {
        case image
        case directory
        case channel

        var isMedia: Bool { self == .image }
    }

    struct Entry {
        var bytes: Int
    }

    public struct Usage: Sendable, Hashable {
        public var mediaBytes: Int
        public var contentBytes: Int
        public var files: Int
        public var totalBytes: Int { mediaBytes + contentBytes }
    }

    /// Where the cache lives and who holds its keys.
    public struct Storage: Sendable {
        public var directory: URL
        public var keys: any CacheKeyStore
        public init(directory: URL, keys: any CacheKeyStore) {
            self.directory = directory
            self.keys = keys
        }
    }

    static let magic = Data("MMC1".utf8)
    static let formatVersion = "1"

    private let root: URL
    private let keys: any CacheKeyStore
    private let budget: ResourceBudget
    private let diagnostics: DiagnosticRing
    private var media: CostLRU<String, Entry>
    private var content: CostLRU<String, Entry>
    private var accounts: [AccountScope: CacheAccount] = [:]
    private var symmetricKeys: [CacheAccount: SymmetricKey] = [:]
    private var isPrepared = false
    private var lastTouched: [String: ContinuousClock.Instant] = [:]

    /// `storage.directory` is the cache root (the app uses its Caches directory); it is
    /// created on first use and excluded from backups.
    public init(storage: Storage, budget: ResourceBudget, diagnostics: DiagnosticRing) {
        root = storage.directory.appendingPathComponent("v" + Self.formatVersion, isDirectory: true)
        self.keys = storage.keys
        self.budget = budget
        self.diagnostics = diagnostics
        media = CostLRU(countLimit: max(1, budget.diskCache.mediaEntries), costLimit: max(1, budget.diskCache.mediaBytes))
        content = CostLRU(countLimit: max(1, budget.diskCache.contentEntries), costLimit: max(1, budget.diskCache.contentBytes))
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Accounts

    /// Associates a running session's scope with its on-disk account and loads (or
    /// creates) the account's key. Until this returns, the scope reads and writes
    /// nothing; afterwards no read or write waits for the key store.
    public func register(_ scope: AccountScope, as account: CacheAccount) async {
        prepareIfNeeded()
        if symmetricKeys[account] == nil {
            guard let data = await keys.key(for: account, create: true), data.count == 32 else {
                diagnostics.record(.lifecycle, .warning, "cache key unavailable")
                return
            }
            symmetricKeys[account] = SymmetricKey(data: data)
        }
        accounts[scope] = account
    }

    public func unregister(_ scope: AccountScope) {
        guard let account = accounts.removeValue(forKey: scope) else { return }
        if !accounts.values.contains(account) { symmetricKeys[account] = nil }
    }

    /// Deletes an account's cached files and its key (Sign Out, a server-ended
    /// session, a rejected saved sign-in).
    public func removeAll(for account: CacheAccount) async {
        prepareIfNeeded()
        accounts = accounts.filter { $0.value != account }
        symmetricKeys[account] = nil
        let prefix = account.identifier + "/"
        media.removeAll { key, _ in key.hasPrefix(prefix) }
        content.removeAll { key, _ in key.hasPrefix(prefix) }
        lastTouched = lastTouched.filter { !$0.key.hasPrefix(prefix) }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(account.identifier, isDirectory: true))
        await keys.removeKey(for: account)
        diagnostics.record(.lifecycle, .info, "account cache removed")
    }

    public func removeAll(for scope: AccountScope) async {
        guard let account = accounts[scope] else { return }
        await removeAll(for: account)
    }

    /// Deletes every cached file and key (Settings ▸ Clear Cache). Running sessions
    /// keep their in-memory content and start writing again with new keys.
    public func removeEverything() async {
        prepareIfNeeded()
        let running = accounts
        accounts.removeAll()
        symmetricKeys.removeAll()
        media.removeAll()
        content.removeAll()
        lastTouched.removeAll()
        try? FileManager.default.removeItem(at: root)
        await keys.removeAllKeys()
        diagnostics.record(.lifecycle, .info, "cache cleared")
        for (scope, account) in running { await register(scope, as: account) }
    }

    public var usage: Usage {
        prepareIfNeeded()
        return Usage(mediaBytes: media.totalCost, contentBytes: content.totalCost, files: media.count + content.count)
    }

    // MARK: Reading and writing

    public func data(_ kind: Kind, _ name: String, scope: AccountScope) -> Data? {
        prepareIfNeeded()
        guard let account = accounts[scope] else { return nil }
        let path = relativePath(account, kind, name)
        let present = kind.isMedia ? media.value(for: path) != nil : content.value(for: path) != nil
        guard present, let key = symmetricKeys[account] else { return nil }
        let url = root.appendingPathComponent(path)
        guard let sealed = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            forget(path, kind: kind, deleting: false)
            return nil
        }
        guard let plain = Self.open(sealed, key: key, context: kind.rawValue + "/" + name) else {
            diagnostics.record(.lifecycle, .warning, "cache entry unreadable")
            forget(path, kind: kind, deleting: true)
            return nil
        }
        touch(path, url: url)
        return plain
    }

    public func store(_ data: Data, _ kind: Kind, _ name: String, scope: AccountScope) {
        prepareIfNeeded()
        guard let account = accounts[scope], data.count <= budget.diskCache.perObjectBytes,
              let key = symmetricKeys[account],
              let sealed = Self.seal(data, key: key, context: kind.rawValue + "/" + name) else { return }
        let path = relativePath(account, kind, name)
        let url = root.appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: url, options: [.atomic])
        } catch {
            diagnostics.record(.lifecycle, .warning, "cache write failed")
            return
        }
        let evicted: [(key: String, value: Entry)]?
        if kind.isMedia {
            evicted = media.set(Entry(bytes: sealed.count), for: path, cost: sealed.count)
        } else {
            evicted = content.set(Entry(bytes: sealed.count), for: path, cost: sealed.count)
        }
        guard let evicted else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        for (old, _) in evicted {
            lastTouched[old] = nil
            try? FileManager.default.removeItem(at: root.appendingPathComponent(old))
        }
    }

    public func remove(_ kind: Kind, _ name: String, scope: AccountScope) {
        prepareIfNeeded()
        guard let account = accounts[scope] else { return }
        forget(relativePath(account, kind, name), kind: kind, deleting: true)
    }

    // MARK: Internals

    private func relativePath(_ account: CacheAccount, _ kind: Kind, _ name: String) -> String {
        account.identifier + "/" + kind.rawValue + "/" + Self.digest(name)
    }

    private func forget(_ path: String, kind: Kind, deleting: Bool) {
        if kind.isMedia { media.removeValue(for: path) } else { content.removeValue(for: path) }
        lastTouched[path] = nil
        if deleting { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
    }

    /// Recency survives relaunch through the modification date; it is updated at
    /// most every ten minutes per file.
    private func touch(_ path: String, url: URL) {
        let now = ContinuousClock.now
        if let last = lastTouched[path], now - last < .seconds(600) { return }
        if lastTouched.count > budget.diskCache.mediaEntries + budget.diskCache.contentEntries { lastTouched.removeAll() }
        lastTouched[path] = now
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Builds the index from the files on disk, oldest first, so the LRUs start in
    /// the order the files were last used. Unknown files are removed.
    private func prepareIfNeeded() {
        guard !isPrepared else { return }
        isPrepared = true
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
        // Older cache formats are discarded.
        if let siblings = try? manager.contentsOfDirectory(at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            for sibling in siblings where sibling.lastPathComponent != root.lastPathComponent { try? manager.removeItem(at: sibling) }
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var found: [(path: String, kind: Kind, bytes: Int, date: Date)] = []
        let rootPath = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard let resource = try? url.resourceValues(forKeys: Set(keys)), resource.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
            let parts = path.split(separator: "/")
            guard parts.count == 3, let kind = Kind(rawValue: String(parts[1])) else {
                try? manager.removeItem(at: url)
                continue
            }
            found.append((path, kind, resource.fileSize ?? 0, resource.contentModificationDate ?? .distantPast))
        }
        for file in found.sorted(by: { $0.date < $1.date }) {
            let evicted = file.kind.isMedia
                ? media.set(Entry(bytes: file.bytes), for: file.path, cost: file.bytes)
                : content.set(Entry(bytes: file.bytes), for: file.path, cost: file.bytes)
            for (old, _) in evicted ?? [(file.path, Entry(bytes: 0))] {
                try? manager.removeItem(at: root.appendingPathComponent(old))
            }
        }
    }

    static func seal(_ data: Data, key: SymmetricKey, context: String) -> Data? {
        guard let box = try? AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)),
              let combined = box.combined else { return nil }
        return magic + combined
    }

    static func open(_ sealed: Data, key: SymmetricKey, context: String) -> Data? {
        guard sealed.count > magic.count, sealed.prefix(magic.count) == magic,
              let box = try? AES.GCM.SealedBox(combined: sealed.dropFirst(magic.count)) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }
}
