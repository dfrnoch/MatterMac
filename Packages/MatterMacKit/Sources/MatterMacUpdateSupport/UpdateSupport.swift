public import Foundation
import CryptoKit
import Security

/// Shared by the app and its embedded, unsandboxed update installer XPC service
/// (`Apps/MatterMac/UpdateInstaller`). Only Foundation and Security.
public enum UpdateSupport {
    /// The embedded XPC service's bundle identifier (`Contents/XPCServices`).
    public static let installerServiceName = "dev.frnoch.mattermac.UpdateInstaller"
    public static let bundleIdentifier = "dev.frnoch.mattermac"
    public static let teamIdentifier = "ZJ37A69485"

    /// What a downloaded update must satisfy: MatterMac's bundle identifier, signed
    /// with the project's Developer ID, and notarized by Apple.
    public static let updateRequirement = """
        identifier "\(bundleIdentifier)" and anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)" \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized
        """

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidSignature(OSStatus)
        case notAnApplication
        case wrongBundle
        case notNewer
        case unsupportedSystem
        case replaceFailed(String)
        case relaunchFailed(Int32)
        case archiveUnreadable
        case checksumMismatch

        public var description: String {
            switch self {
            case .invalidSignature(let status): "The update is not signed and notarized for MatterMac (\(status))."
            case .notAnApplication: "The update does not contain an application."
            case .wrongBundle: "The update is not MatterMac."
            case .notNewer: "The update is not newer than this version."
            case .unsupportedSystem: "The update needs a newer version of macOS."
            case .replaceFailed(let reason): "MatterMac could not replace the app: \(reason)"
            case .relaunchFailed(let code): "MatterMac could not schedule its relaunch (\(code))."
            case .archiveUnreadable: "The update archive could not be read or unpacked."
            case .checksumMismatch: "The update archive is damaged (checksum mismatch)."
            }
        }
    }

    /// Validates the app's whole signature (nested code included) against
    /// `requirement` without executing it.
    public static func verifySignature(of app: URL, requirement: String) throws(Failure) {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw .invalidSignature(status) }
        var compiled: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else { throw .invalidSignature(status) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(code, flags, compiled)
        guard status == errSecSuccess else { throw .invalidSignature(status) }
    }

    public struct BundleInfo: Sendable {
        public var identifier: String
        public var build: Int
        public var minimumSystem: OperatingSystemVersion
    }

    public static func bundleInfo(of app: URL) throws(Failure) -> BundleInfo {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "APPL" else { throw .notAnApplication }
        guard let identifier = info["CFBundleIdentifier"] as? String,
              let buildText = info["CFBundleVersion"] as? String, let build = Int(buildText) else { throw .wrongBundle }
        let parts = ((info["LSMinimumSystemVersion"] as? String) ?? "14.0").split(separator: ".").compactMap { Int($0) }
        let minimum = OperatingSystemVersion(majorVersion: parts.first ?? 14, minorVersion: parts.count > 1 ? parts[1] : 0,
                                             patchVersion: parts.count > 2 ? parts[2] : 0)
        return BundleInfo(identifier: identifier, build: build, minimumSystem: minimum)
    }

    /// Everything the installer checks before touching the installed app: both
    /// bundles are MatterMac, the update satisfies `requirement`, is newer, and runs
    /// on this system.
    public static func validate(update: URL, replacing installed: URL, requirement: String) throws(Failure) {
        let new = try bundleInfo(of: update)
        let old = try bundleInfo(of: installed)
        guard new.identifier == bundleIdentifier, old.identifier == bundleIdentifier else { throw .wrongBundle }
        guard new.build > old.build else { throw .notNewer }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(new.minimumSystem) else { throw .unsupportedSystem }
        try verifySignature(of: update, requirement: requirement)
    }

    /// The largest update archive MatterMac downloads or installs.
    public static let maximumArchiveBytes: Int64 = 400 * 1_048_576

    public static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `ditto` keeps the signed bundle's symlinks, permissions and extended attributes.
    public static func unzip(_ archive: URL, into directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The installer's whole job, from an archive it receives as an open file (the
    /// app's container is closed to other processes): copies it into `workDirectory`
    /// (bounded), checks its SHA-256, unpacks it, validates the app against
    /// `requirement` and the installed copy, and swaps it in.
    public static func installArchive(from source: FileHandle, expectedSHA256: String, replacing installed: URL,
                                      requirement: String, workDirectory: URL) throws(Failure) {
        let manager = FileManager.default
        try? manager.removeItem(at: workDirectory)
        defer { try? manager.removeItem(at: workDirectory) }
        let archive = workDirectory.appendingPathComponent("update.zip")
        do {
            try manager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            guard manager.createFile(atPath: archive.path, contents: nil) else { throw Failure.archiveUnreadable }
            let destination = try FileHandle(forWritingTo: archive)
            defer { try? destination.close() }
            try source.seek(toOffset: 0)
            var written: Int64 = 0
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                written += Int64(chunk.count)
                guard written <= maximumArchiveBytes else { throw Failure.archiveUnreadable }
                try destination.write(contentsOf: chunk)
            }
        } catch {
            throw .archiveUnreadable
        }
        guard sha256(of: archive) == expectedSHA256.lowercased() else { throw .checksumMismatch }
        let unpacked = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        guard unzip(archive, into: unpacked) else { throw .archiveUnreadable }
        let update = unpacked.appendingPathComponent("MatterMac.app", isDirectory: true)
        guard manager.fileExists(atPath: update.path) else { throw .notAnApplication }
        try validate(update: update, replacing: installed, requirement: requirement)
        try replace(installed: installed, with: update)
    }

    /// Swaps the installed bundle for the update in one step (the old bundle is
    /// removed), keeping the installed location and name.
    public static func replace(installed: URL, with update: URL) throws(Failure) {
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: update, backupItemName: nil,
                                                      options: [.usingNewMetadataOnly])
        } catch {
            throw .replaceFailed((error as NSError).localizedDescription)
        }
    }

    /// Starts a detached helper that waits for `process` to exit, then opens `app`
    /// with `arguments` (a fresh instance). It outlives the caller.
    public static func scheduleRelaunch(of app: URL, after process: pid_t, arguments: [String]) throws(Failure) {
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; shift; exec /usr/bin/open -n \"$@\""
        var openArguments = [app.path]
        if !arguments.isEmpty { openArguments += ["--args"] + arguments }
        let argv = ["/bin/sh", "-c", script, "sh", String(process)] + openArguments
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var cArguments = argv.map { strdup($0) } + [nil]
        defer { for pointer in cArguments { free(pointer) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", nil, &attributes, &cArguments, environ)
        guard status == 0 else { throw .relaunchFailed(status) }
    }
}

/// The installer service's interface (NSXPC; the app is the only client).
@objc public protocol UpdateInstalling {
    /// Installs the update archive `archive` (an open file: the app's container is
    /// not readable by other processes) with SHA-256 `sha256` over the app at
    /// `installedPath`, then schedules a relaunch once process `pid` has exited.
    /// Replies with `nil` on success, else a user-facing explanation.
    func installUpdate(fromArchive archive: FileHandle, sha256: String, replacingAppAtPath installedPath: String,
                       relaunchAfterProcess pid: Int32, arguments: [String],
                       withReply reply: @escaping @Sendable (String?) -> Void)
}
