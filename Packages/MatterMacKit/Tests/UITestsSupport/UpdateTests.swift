import AppKit
import CryptoKit
import Foundation
import Testing
import os
import MatterMacPlatform
import MatterMacUpdateSupport
@testable import MatterMacUI

/// In-app updates (decision 0034): release selection, the manifest the release
/// workflow writes, archive and signature checks, the bundle swap, and the
/// updater's states. No network: a fake HTTP serves GitHub-shaped responses.
@MainActor
@Suite("In-app updates", .serialized)
struct UpdateTests {
    final class FakeHTTP: UpdateHTTP, Sendable {
        let files: OSAllocatedUnfairLock<[String: Data]>
        let requests = OSAllocatedUnfairLock<[String]>(initialState: [])
        init(_ files: [String: Data]) { self.files = OSAllocatedUnfairLock(initialState: files) }
        func data(from url: URL, maximumBytes: Int) async throws -> Data {
            requests.withLock { $0.append(url.absoluteString) }
            guard let data = files.withLock({ $0[url.absoluteString] }) else { throw UpdateError.network }
            guard data.count <= maximumBytes else { throw UpdateError.tooLarge }
            return data
        }
        func download(from url: URL, into directory: URL, maximumBytes: Int64) async throws -> URL {
            let data = try await self.data(from: url, maximumBytes: Int(maximumBytes))
            let file = directory.appendingPathComponent("update.zip")
            try data.write(to: file)
            return file
        }
    }

    static let feedURL = URL(string: "https://updates.test/releases.json")!

    static func release(_ tag: String, prerelease: Bool, draft: Bool = false, manifest: Bool = true) -> [String: Any] {
        var assets: [[String: Any]] = [["name": "MatterMac-\(tag).zip", "browser_download_url": "https://updates.test/\(tag).zip"],
                                       ["name": "MatterMac-\(tag).dmg", "browser_download_url": "https://updates.test/\(tag).dmg"]]
        if manifest { assets.append(["name": "update.json", "browser_download_url": "https://updates.test/\(tag).json"]) }
        return ["tag_name": "v\(tag)", "html_url": "https://updates.test/releases/\(tag)", "draft": draft,
                "prerelease": prerelease, "assets": assets]
    }

    /// Exactly what `release.yml` prints into update.json.
    static func manifest(_ label: String, build: Int, sha: String = String(repeating: "a", count: 64), size: Int = 1_000) -> Data {
        Data(String(format: #"{"schema":1,"label":"%@","build":%d,"channel":"%@","zip":"%@","zipSHA256":"%@","zipSize":%d,"dmg":"%@","minimumSystemVersion":"14.0"}"#,
                    label, build, label.contains("nightly") ? "nightly" : "production", "MatterMac-\(label).zip", sha,
                    size, "MatterMac-\(label).dmg").utf8)
    }

    func feed(releases: [[String: Any]], manifests: [String: Data], extra: [String: Data] = [:]) throws -> FakeHTTP {
        var files = extra
        files[Self.feedURL.absoluteString] = try JSONSerialization.data(withJSONObject: releases)
        for (tag, data) in manifests { files["https://updates.test/\(tag).json"] = data }
        return FakeHTTP(files)
    }

    @Test func channelsPickTheNewestEligibleBuild() async throws {
        let http = try feed(releases: [
            Self.release("1.1.0-nightly.20260926.52", prerelease: true),
            Self.release("1.2.0-draft", prerelease: false, draft: true),
            Self.release("1.0.1", prerelease: false),
            Self.release("1.0.0", prerelease: false),
            Self.release("1.0.0-nightly.20260920.40", prerelease: true, manifest: false),
        ], manifests: [
            "1.1.0-nightly.20260926.52": Self.manifest("1.1.0-nightly.20260926.52", build: 52),
            "1.2.0-draft": Self.manifest("1.2.0", build: 99),
            "1.0.1": Self.manifest("1.0.1", build: 50),
            "1.0.0": Self.manifest("1.0.0", build: 45),
        ])
        let feed = GitHubUpdateFeed(http: http, overrideReleasesURL: Self.feedURL)
        let stable = try await feed.latest(for: .stable, newerThan: 45)
        #expect(stable?.manifest.label == "1.0.1")
        #expect(stable?.archiveURL.absoluteString == "https://updates.test/1.0.1.zip")
        #expect(stable?.isPrerelease == false)
        let nightly = try await feed.latest(for: .nightly, newerThan: 45)
        #expect(nightly?.manifest.build == 52)
        #expect(nightly?.isPrerelease == true)
        #expect(try await feed.latest(for: .stable, newerThan: 50) == nil, "Nothing newer")
        #expect(!http.requests.withLock { $0 }.contains("https://updates.test/1.2.0-draft.json"), "Drafts are skipped")
    }

    @Test func malformedManifestsAndFeedsAreRejected() async throws {
        let bad: [String: Data] = [
            "a": Data(#"{"schema":1,"label":"x","build":60,"channel":"production","zip":"../evil.zip","zipSHA256":"\#(String(repeating: "a", count: 64))","zipSize":10,"dmg":"x.dmg","minimumSystemVersion":"14.0"}"#.utf8),
            "b": Self.manifest("1.0.2", build: 61, sha: "not-hex"),
            "c": Self.manifest("1.0.3", build: 62, size: Int(UpdateManifest.maximumArchiveBytes) + 1),
        ]
        let http = try feed(releases: ["a", "b", "c"].map { Self.release($0, prerelease: false) }, manifests: bad)
        #expect(try await GitHubUpdateFeed(http: http, overrideReleasesURL: Self.feedURL).latest(for: .stable, newerThan: 1) == nil)
        let broken = FakeHTTP([Self.feedURL.absoluteString: Data("not json".utf8)])
        await #expect(throws: UpdateError.malformedFeed) {
            try await GitHubUpdateFeed(http: broken, overrideReleasesURL: Self.feedURL).latest(for: .stable, newerThan: 1)
        }
    }

    // MARK: Archives and bundles

    /// A minimal ad-hoc-signed MatterMac-shaped bundle.
    static func makeApp(at url: URL, build: Int, identifier: String = "dev.frnoch.mattermac") throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
                                   "CFBundleExecutable": "MatterMac", "CFBundleVersion": String(build),
                                   "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: contents.appendingPathComponent("MacOS/MatterMac"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, url.path])
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mattermac-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func zip(_ app: URL, to archive: URL) throws {
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The ad-hoc test bundles satisfy an identifier-only requirement.
    static let testRequirement = #"identifier "dev.frnoch.mattermac""#

    @Test func preparedUpdatesAreCheckedBeforeUse() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/MatterMac.app")
        try Self.makeApp(at: installed, build: 45)
        let staged = root.appendingPathComponent("staged/MatterMac.app")
        try Self.makeApp(at: staged, build: 52)
        let archive = root.appendingPathComponent("update.zip")
        try Self.zip(staged, to: archive)
        let bytes = try Data(contentsOf: archive)
        func update(sha: String) -> AvailableUpdate {
            let manifest = try! JSONDecoder().decode(UpdateManifest.self,
                                                     from: Self.manifest("1.0.1", build: 52, sha: sha, size: bytes.count))
            return AvailableUpdate(manifest: manifest, archiveURL: URL(string: "https://updates.test/u.zip")!,
                                   diskImageURL: nil, releasePage: URL(string: "https://updates.test/r")!, isPrerelease: false)
        }
        let http = FakeHTTP(["https://updates.test/u.zip": bytes])
        let work = root.appendingPathComponent("work")
        await #expect(throws: UpdateError.checksumMismatch) {
            try await UpdatePreparer.prepare(update(sha: String(repeating: "0", count: 64)), http: http,
                                             workDirectory: work, installedApp: installed, requirement: Self.testRequirement)
        }
        // The real requirement (Developer ID, notarized) rejects an ad-hoc bundle.
        await #expect(throws: UpdateError.self) {
            try await UpdatePreparer.prepare(update(sha: Self.sha256(bytes)), http: http, workDirectory: work,
                                             installedApp: installed)
        }
        let prepared = try await UpdatePreparer.prepare(update(sha: Self.sha256(bytes)), http: http, workDirectory: work,
                                                        installedApp: installed, requirement: Self.testRequirement)
        let app = prepared.app
        #expect(try UpdateSupport.bundleInfo(of: app).build == 52)
        #expect(prepared.sha256 == Self.sha256(bytes))

        // Not newer, or not MatterMac: refused.
        #expect(throws: UpdateSupport.Failure.notNewer) {
            try UpdateSupport.validate(update: installed, replacing: app, requirement: Self.testRequirement)
        }
        let other = root.appendingPathComponent("other/MatterMac.app")
        try Self.makeApp(at: other, build: 99, identifier: "com.example.other")
        #expect(throws: UpdateSupport.Failure.wrongBundle) {
            try UpdateSupport.validate(update: other, replacing: installed, requirement: Self.testRequirement)
        }

        // The installer path: from an open archive, with a wrong checksum refused,
        // then the swap keeps the installed location.
        let handle = try FileHandle(forReadingFrom: prepared.archive)
        defer { try? handle.close() }
        let installerWork = root.appendingPathComponent("installer")
        #expect(throws: UpdateSupport.Failure.checksumMismatch) {
            try UpdateSupport.installArchive(from: handle, expectedSHA256: String(repeating: "0", count: 64),
                                             replacing: installed, requirement: Self.testRequirement,
                                             workDirectory: installerWork)
        }
        #expect(try UpdateSupport.bundleInfo(of: installed).build == 45)
        try UpdateSupport.installArchive(from: handle, expectedSHA256: prepared.sha256, replacing: installed,
                                         requirement: Self.testRequirement, workDirectory: installerWork)
        #expect(try UpdateSupport.bundleInfo(of: installed).build == 52)
        #expect(!FileManager.default.fileExists(atPath: installerWork.path), "The installer cleans up")
    }

    // MARK: The updater

    @Test func updaterDownloadsVerifiesAndInstallsThenQuits() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/MatterMac.app")
        try Self.makeApp(at: installed, build: 45)
        let staged = root.appendingPathComponent("staged/MatterMac.app")
        try Self.makeApp(at: staged, build: 52)
        let archive = root.appendingPathComponent("update.zip")
        try Self.zip(staged, to: archive)
        let bytes = try Data(contentsOf: archive)
        let tag = "1.0.1"
        let http = try feed(releases: [Self.release(tag, prerelease: false)],
                            manifests: [tag: Self.manifest(tag, build: 52, sha: Self.sha256(bytes), size: bytes.count)],
                            extra: ["https://updates.test/\(tag).zip": bytes])
        let settings = LocalSettings()
        let updater = AppUpdater(settings: settings, http: http, configuration: .init(
            installedApp: installed, currentBuild: 45, currentLabel: "1.0.0", workDirectory: root.appendingPathComponent("work"),
            requirement: Self.testRequirement, relaunchArguments: ["-Flag", "YES"], overrideReleasesURL: Self.feedURL))
        #expect(updater.channel == .stable)
        var installs: [(PreparedUpdate, URL, [String])] = []
        var terminated = false
        updater.install = { update, installed, arguments in installs.append((update, installed, arguments)) }
        updater.terminate = { terminated = true }

        updater.check(userInitiated: false)
        #expect(await wait { updater.phase == .ready(label: tag) })
        #expect(updater.bannerLabel == tag)
        updater.dismissBanner()
        #expect(updater.bannerLabel == nil, "Later hides the banner for this update")
        updater.check(userInitiated: true)
        #expect(await wait { updater.bannerLabel == tag })

        updater.restartToUpdate()
        #expect(await wait { terminated })
        #expect(installs.count == 1)
        #expect(installs.first?.1 == installed)
        #expect(installs.first?.2 == ["-Flag", "YES"])
        #expect(installs.first.map { (try? UpdateSupport.bundleInfo(of: $0.0.app))?.build } == 52)
        #expect(installs.first.map { FileManager.default.fileExists(atPath: $0.0.archive.path) } == true)
    }

    @Test func updaterReportsUpToDateFailuresAndTheDiskImageFallback() async throws {
        let tag = "1.0.1"
        let http = try feed(releases: [Self.release(tag, prerelease: false)],
                            manifests: [tag: Self.manifest(tag, build: 52)])
        let settings = LocalSettings()
        func updater(build: Int, label: String) -> AppUpdater {
            AppUpdater(settings: settings, http: http, configuration: .init(
                installedApp: URL(fileURLWithPath: "/Applications/MatterMac.app"), currentBuild: build, currentLabel: label,
                workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString)"),
                requirement: Self.testRequirement, relaunchArguments: [], overrideReleasesURL: Self.feedURL))
        }
        let current = updater(build: 52, label: "1.0.1")
        current.check(userInitiated: true)
        #expect(await wait { current.notice == "MatterMac 1.0.1 is up to date." })
        #expect(current.bannerLabel == nil)

        // The archive is missing from the feed: the download fails and says so.
        let behind = updater(build: 45, label: "1.0.0-nightly.20260920.45")
        #expect(behind.channel == .nightly, "Nightly builds follow nightlies by default")
        behind.check(userInitiated: true)
        #expect(await wait { if case .failed = behind.phase { true } else { false } })
        #expect(behind.notice == UpdateError.network.description)
        settings.updateChannel = .stable
        #expect(behind.channel == .stable)
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }
}
