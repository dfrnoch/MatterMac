public import Foundation
import os
public import MatterMacUpdateSupport

/// Which releases a copy of MatterMac follows.
public enum UpdateChannel: String, CaseIterable, Sendable, Identifiable {
    /// Production releases only.
    case stable
    /// Nightly pre-releases and production releases, whichever is newer.
    case nightly

    public var id: String { rawValue }
}

/// `update.json`, attached to every GitHub release by `.github/workflows/release.yml`.
public struct UpdateManifest: Codable, Sendable, Equatable {
    public var schema: Int
    /// Shown to the user, e.g. `1.0.0-nightly.20260923.45` or `1.0.1`.
    public var label: String
    /// `CFBundleVersion`: monotonic across channels; the only thing compared.
    public var build: Int
    public var channel: String
    public var zip: String
    public var zipSHA256: String
    public var zipSize: Int64
    public var dmg: String
    public var minimumSystemVersion: String

    static let maximumBytes = 64 * 1_024
    /// The largest update archive MatterMac downloads.
    public static let maximumArchiveBytes: Int64 = 400 * 1_048_576

    /// Plain file names and a hex digest: nothing that could become a path or URL.
    var isWellFormed: Bool {
        func isFileName(_ name: String) -> Bool {
            !name.isEmpty && name.count <= 200 && !name.hasPrefix(".")
                && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
        return schema == 1 && build > 0 && label.count <= 80 && isFileName(zip) && isFileName(dmg)
            && zip.hasSuffix(".zip") && dmg.hasSuffix(".dmg")
            && zipSHA256.count == 64 && zipSHA256.allSatisfy(\.isHexDigit)
            && zipSize > 0 && zipSize <= Self.maximumArchiveBytes
    }
}

/// A release newer than the running app, with the URLs of its files.
public struct AvailableUpdate: Sendable, Equatable {
    public var manifest: UpdateManifest
    public var archiveURL: URL
    public var diskImageURL: URL?
    /// The release page (notes), opened only when the user asks.
    public var releasePage: URL
    public var isPrerelease: Bool

    public init(manifest: UpdateManifest, archiveURL: URL, diskImageURL: URL?, releasePage: URL, isPrerelease: Bool) {
        self.manifest = manifest
        self.archiveURL = archiveURL
        self.diskImageURL = diskImageURL
        self.releasePage = releasePage
        self.isPrerelease = isPrerelease
    }
}

/// Bounded HTTP for the updater (injectable for tests).
public protocol UpdateHTTP: Sendable {
    func data(from url: URL, maximumBytes: Int) async throws -> Data
    /// Downloads to a new file in `directory`; returns its URL.
    func download(from url: URL, into directory: URL, maximumBytes: Int64) async throws -> URL
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case network
    case tooLarge
    case malformedFeed
    case checksumMismatch
    case extractionFailed
    case install(String)

    public var description: String {
        switch self {
        case .network: String(localized: "MatterMac could not reach GitHub to check for updates.")
        case .tooLarge: String(localized: "The update is larger than MatterMac accepts.")
        case .malformedFeed: String(localized: "The update information on GitHub is not valid.")
        case .checksumMismatch: String(localized: "The downloaded update is damaged (checksum mismatch).")
        case .extractionFailed: String(localized: "The downloaded update could not be unpacked.")
        case .install(let reason): reason
        }
    }
}

/// Reads MatterMac's GitHub releases (public, unauthenticated API). Only release
/// metadata and `update.json` are fetched here; nothing about the user is sent
/// beyond what any HTTPS request carries (IP address, User-Agent).
public struct GitHubUpdateFeed: Sendable {
    public var repository: String
    public var http: any UpdateHTTP
    /// Development only: a base URL serving `releases.json` in GitHub's format.
    public var overrideReleasesURL: URL?

    public init(repository: String = "dfrnoch/MatterMac", http: any UpdateHTTP, overrideReleasesURL: URL? = nil) {
        self.repository = repository
        self.http = http
        self.overrideReleasesURL = overrideReleasesURL
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
        }
        var tag_name: String
        var html_url: URL
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]
    }

    var releasesURL: URL {
        overrideReleasesURL ?? URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    }

    /// The newest release on `channel` whose build is greater than `currentBuild`.
    public func latest(for channel: UpdateChannel, newerThan currentBuild: Int) async throws(UpdateError) -> AvailableUpdate? {
        let data: Data
        do { data = try await http.data(from: releasesURL, maximumBytes: 4 * 1_048_576) } catch { throw .network }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { throw .malformedFeed }
        let eligible = releases.filter { !$0.draft && (channel == .nightly || !$0.prerelease) }
        var best: AvailableUpdate?
        // Newest first as GitHub lists them; a handful of manifests at most.
        for release in eligible.prefix(8) {
            guard let manifestAsset = release.assets.first(where: { $0.name == "update.json" }) else { continue }
            let manifestData: Data
            do { manifestData = try await http.data(from: manifestAsset.browser_download_url, maximumBytes: UpdateManifest.maximumBytes) }
            catch { throw .network }
            guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestData), manifest.isWellFormed,
                  let archive = release.assets.first(where: { $0.name == manifest.zip }) else { continue }
            guard manifest.build > currentBuild, manifest.build > (best?.manifest.build ?? 0) else { continue }
            best = AvailableUpdate(manifest: manifest, archiveURL: archive.browser_download_url,
                                   diskImageURL: release.assets.first { $0.name == manifest.dmg }?.browser_download_url,
                                   releasePage: release.html_url, isPrerelease: release.prerelease)
        }
        return best
    }
}

/// A downloaded, checked update: the archive (handed to the installer) and its
/// unpacked app (already validated).
public struct PreparedUpdate: Sendable, Equatable {
    public var archive: URL
    public var app: URL
    public var sha256: String
}

/// Downloads, checks and unpacks an update inside the app's container.
public enum UpdatePreparer {
    /// Checks the archive's SHA-256, then the unpacked app's signature
    /// (`requirement`), bundle identifier, build and minimum system. The installer
    /// repeats every check on its own copy.
    public static func prepare(_ update: AvailableUpdate, http: any UpdateHTTP, workDirectory: URL,
                               installedApp: URL, requirement: String = UpdateSupport.updateRequirement)
        async throws(UpdateError) -> PreparedUpdate
    {
        let manager = FileManager.default
        try? manager.removeItem(at: workDirectory)
        do { try manager.createDirectory(at: workDirectory, withIntermediateDirectories: true) } catch { throw .extractionFailed }
        let archive: URL
        do {
            archive = try await http.download(from: update.archiveURL, into: workDirectory,
                                              maximumBytes: min(update.manifest.zipSize, UpdateManifest.maximumArchiveBytes))
        } catch UpdateError.tooLarge { throw .tooLarge } catch { throw .network }
        guard await sha256(of: archive) == update.manifest.zipSHA256.lowercased() else {
            try? manager.removeItem(at: workDirectory)
            throw .checksumMismatch
        }
        let unpacked = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        guard await unzip(archive, into: unpacked) else { throw .extractionFailed }
        let app = unpacked.appendingPathComponent("MatterMac.app", isDirectory: true)
        guard manager.fileExists(atPath: app.path) else { throw .extractionFailed }
        do {
            try UpdateSupport.validate(update: app, replacing: installedApp, requirement: requirement)
        } catch {
            throw .install(error.description)
        }
        return PreparedUpdate(archive: archive, app: app, sha256: update.manifest.zipSHA256.lowercased())
    }

    @concurrent
    static func sha256(of file: URL) async -> String? { UpdateSupport.sha256(of: file) }

    @concurrent
    static func unzip(_ archive: URL, into directory: URL) async -> Bool { UpdateSupport.unzip(archive, into: directory) }
}

/// Ephemeral, cache-free sessions for the updater (no cookies, no credentials).
public final class URLSessionUpdateHTTP: UpdateHTTP {
    private let session: URLSession

    public init(userAgent: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/vnd.github+json"]
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    public func data(from url: URL, maximumBytes: Int) async throws -> Data {
        guard url.scheme == "https" || url.host() == "localhost" else { throw UpdateError.network }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw UpdateError.network }
        if http.expectedContentLength > maximumBytes { throw UpdateError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw UpdateError.tooLarge }
        }
        return data
    }

    public func download(from url: URL, into directory: URL, maximumBytes: Int64) async throws -> URL {
        guard url.scheme == "https" || url.host() == "localhost" else { throw UpdateError.network }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw UpdateError.network }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? Int64.max
        guard size <= maximumBytes else { throw UpdateError.tooLarge }
        let destination = directory.appendingPathComponent("update.zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// Talks to the embedded installer XPC service.
public enum UpdateInstallerClient {
    public static func install(_ update: PreparedUpdate, replacing installed: URL, arguments: [String]) async throws(UpdateError) {
        guard let archive = try? FileHandle(forReadingFrom: update.archive) else {
            throw .install(String(localized: "The downloaded update is missing. Check for updates again."))
        }
        defer { try? archive.close() }
        let connection = NSXPCConnection(serviceName: UpdateSupport.installerServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: (any UpdateInstalling).self)
        connection.resume()
        defer { connection.invalidate() }
        let result: String? = await withCheckedContinuation { continuation in
            let once = ReplyOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                once.resume(String(localized: "The MatterMac update installer could not be started."))
            } as? any UpdateInstalling
            guard let proxy else {
                once.resume(String(localized: "The MatterMac update installer is missing."))
                return
            }
            proxy.installUpdate(fromArchive: archive, sha256: update.sha256, replacingAppAtPath: installed.path,
                                relaunchAfterProcess: ProcessInfo.processInfo.processIdentifier,
                                arguments: arguments) { message in once.resume(message) }
        }
        if let result { throw .install(result) }
    }

    /// Resumes a continuation exactly once (the reply or the error handler).
    private final class ReplyOnce: Sendable {
        private let state: OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>
        init(_ continuation: CheckedContinuation<String?, Never>) { state = OSAllocatedUnfairLock(initialState: continuation) }
        func resume(_ value: String?) {
            let continuation = state.withLock { current -> CheckedContinuation<String?, Never>? in
                defer { current = nil }
                return current
            }
            continuation?.resume(returning: value)
        }
    }
}
