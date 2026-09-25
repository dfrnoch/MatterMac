public import AppKit
public import Observation
public import MatterMacPlatform
public import MatterMacUpdateSupport

/// Automatic updates from MatterMac's GitHub releases (decision 0034).
///
/// Checks shortly after launch and every six hours while `checksForUpdates` is on
/// (Settings › General), and whenever the user chooses Check for Updates…. A newer
/// release on the chosen channel is downloaded into the app's Caches, its SHA-256,
/// Developer ID signature, notarization, bundle identifier and build are checked,
/// and a "Restart to Update" banner appears. The embedded installer service then
/// swaps the app bundle and reopens MatterMac once it has quit. When the app cannot
/// replace itself (translocated, read-only), the DMG is offered instead.
@MainActor
@Observable
public final class AppUpdater {
    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case downloading(label: String)
        case ready(label: String)
        case installing(label: String)
        case failed(message: String)
    }

    public struct Configuration: Sendable {
        public var installedApp: URL
        public var currentBuild: Int
        public var currentLabel: String
        public var workDirectory: URL
        public var requirement: String
        public var relaunchArguments: [String]
        public var overrideReleasesURL: URL?
        public var firstCheckDelay: Duration
        /// Development only: install as soon as an update is ready (no banner click).
        public var installsWhenReady: Bool

        public init(installedApp: URL, currentBuild: Int, currentLabel: String, workDirectory: URL,
                    requirement: String = UpdateSupport.updateRequirement, relaunchArguments: [String],
                    overrideReleasesURL: URL? = nil, firstCheckDelay: Duration = .seconds(20),
                    installsWhenReady: Bool = false) {
            self.firstCheckDelay = firstCheckDelay
            self.installsWhenReady = installsWhenReady
            self.installedApp = installedApp
            self.currentBuild = currentBuild
            self.currentLabel = currentLabel
            self.workDirectory = workDirectory
            self.requirement = requirement
            self.relaunchArguments = relaunchArguments
            self.overrideReleasesURL = overrideReleasesURL
        }
    }

    public private(set) var phase: Phase = .idle {
        didSet {
            // Development end-to-end runs (`-MatterMacUpdateAutoInstall`) report each
            // step on stderr; no content or account data is involved.
            if configuration.installsWhenReady {
                FileHandle.standardError.write(Data("MatterMac update: \(phase)\n".utf8))
            }
        }
    }
    /// The newest known release on the channel (also while downloading or ready).
    public private(set) var available: AvailableUpdate?
    /// Set when the banner was dismissed for this update ("Later").
    public private(set) var dismissedBuild: Int?
    /// A result worth telling the user: the answer to Check for Updates…, or why an
    /// install failed. Shown as a banner until dismissed.
    public private(set) var notice: String?
    /// The notice follows a failed install: offer the disk image instead.
    public private(set) var offersDiskImage = false
    public let configuration: Configuration

    @ObservationIgnored private let settings: LocalSettings
    @ObservationIgnored private let http: any UpdateHTTP
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var prepared: PreparedUpdate?
    /// Untyped `throws`: stored typed-throws closures need the macOS 15 runtime.
    @ObservationIgnored var install: @MainActor (PreparedUpdate, URL, [String]) async throws -> Void = { update, installed, arguments in
        try await UpdateInstallerClient.install(update, replacing: installed, arguments: arguments)
    }
    /// Quits like ⌘Q. Scheduled on the run loop rather than called from the task:
    /// `terminate` waits for the app's async shutdown, which needs the main actor
    /// the task is holding (verified: calling it directly never finished quitting).
    @ObservationIgnored var terminate: @MainActor () -> Void = {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    static let firstCheckDelay: Duration = .seconds(20)
    static let checkInterval: Duration = .seconds(6 * 60 * 60)

    public init(settings: LocalSettings, http: any UpdateHTTP, configuration: Configuration) {
        self.settings = settings
        self.http = http
        self.configuration = configuration
    }

    /// Nightly builds follow nightlies unless the user chose otherwise.
    public var channel: UpdateChannel {
        get { settings.updateChannel ?? (configuration.currentLabel.contains("-nightly.") ? .nightly : .stable) }
        set {
            settings.updateChannel = newValue
            check(userInitiated: false)
        }
    }

    /// The version the banner offers, when it should be shown.
    public var bannerLabel: String? {
        guard let available, available.manifest.build != dismissedBuild else { return nil }
        switch phase {
        case .ready, .installing: return available.manifest.label
        default: return nil
        }
    }

    // MARK: Scheduling

    public func start() {
        guard schedule == nil else { return }
        // A previous download (installed or abandoned) is not reused across launches.
        try? FileManager.default.removeItem(at: configuration.workDirectory)
        schedule = Task { [weak self] in
            try? await Task.sleep(for: self?.configuration.firstCheckDelay ?? Self.firstCheckDelay)
            while !Task.isCancelled {
                guard let self else { return }
                if settings.checksForUpdates { check(userInitiated: false) }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    public func stop() {
        schedule?.cancel()
        schedule = nil
        work?.cancel()
        work = nil
    }

    // MARK: Checking and downloading

    /// Checks the feed, then downloads and verifies a newer release.
    public func check(userInitiated: Bool) {
        if userInitiated {
            dismissedBuild = nil
            dismissNotice()
        }
        switch phase {
        case .checking, .downloading, .installing: return
        case .ready where available.map({ $0.manifest.build > configuration.currentBuild }) == true && !userInitiated: return
        default: break
        }
        work?.cancel()
        phase = .checking
        let feed = GitHubUpdateFeed(http: http, overrideReleasesURL: configuration.overrideReleasesURL)
        let channel = channel
        let current = configuration.currentBuild
        work = Task { [weak self] in
            do {
                let update = try await feed.latest(for: channel, newerThan: current)
                guard let self, !Task.isCancelled else { return }
                guard let update else {
                    available = nil
                    phase = .upToDate(.now)
                    if userInitiated {
                        notice = String(localized: "MatterMac \(configuration.currentLabel) is up to date.")
                    }
                    return
                }
                if let ready = prepared, available?.manifest.build == update.manifest.build,
                   FileManager.default.fileExists(atPath: ready.archive.path) {
                    phase = .ready(label: update.manifest.label)
                    return
                }
                available = update
                phase = .downloading(label: update.manifest.label)
                let ready = try await UpdatePreparer.prepare(update, http: http, workDirectory: configuration.workDirectory,
                                                             installedApp: configuration.installedApp,
                                                             requirement: configuration.requirement)
                guard !Task.isCancelled else { return }
                prepared = ready
                phase = .ready(label: update.manifest.label)
                if configuration.installsWhenReady { restartToUpdate() }
            } catch let error as UpdateError {
                guard let self, !Task.isCancelled else { return }
                phase = .failed(message: error.description)
                if userInitiated { notice = error.description }
            } catch {}
        }
    }

    public func dismissBanner() {
        dismissedBuild = available?.manifest.build
    }

    public func dismissNotice() {
        notice = nil
        offersDiskImage = false
    }

    // MARK: Installing

    /// Whether MatterMac can replace its own bundle where it runs from: not from the
    /// disk image or a translocated copy. (Write access is not checked here: the
    /// sandbox always denies it; the installer service reports a real failure.)
    public var canInstallInPlace: Bool {
        let path = configuration.installedApp.path
        return !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
    }

    /// Installs the prepared update and quits; the installer reopens MatterMac.
    public func restartToUpdate() {
        guard case .ready(let label) = phase, let app = prepared else { return }
        guard canInstallInPlace else {
            failInstall(String(localized: """
                MatterMac cannot update itself where it is. Move it to the Applications folder, \
                or install the new version from the disk image.
                """))
            return
        }
        phase = .installing(label: label)
        let installed = configuration.installedApp
        let arguments = configuration.relaunchArguments
        work = Task { [weak self] in
            do {
                try await self?.install(app, installed, arguments)
                self?.terminate()
            } catch let error as UpdateError {
                self?.failInstall(error.description)
            } catch {
                self?.failInstall(String(localized: "The update could not be installed."))
            }
        }
    }

    private func failInstall(_ message: String) {
        phase = .failed(message: message)
        dismissedBuild = available?.manifest.build
        notice = message
        offersDiskImage = available?.diskImageURL != nil
    }

    /// Opens the release's disk image in the browser (manual install fallback).
    public func downloadDiskImage() {
        guard let url = available?.diskImageURL ?? available?.releasePage else { return }
        NSWorkspace.shared.open(url)
    }

    public func openReleaseNotes() {
        guard let url = available?.releasePage else { return }
        NSWorkspace.shared.open(url)
    }
}
