import AppKit
import Foundation

/// In-app attention for incoming alerts (SPEC §7/§19 "in-app badges and optional
/// in-app sounds"): a named system sound and a single Dock bounce. Neither writes
/// anything or involves Notification Center. Sounds are played by the app itself,
/// so they follow Mattermost's Do Not Disturb status (Core suppresses alerts then)
/// but not macOS Focus, which only filters Notification Center.
@MainActor
public protocol AttentionRequesting: AnyObject {
    func playSound(named name: String)
    /// One informational Dock bounce; AppKit ignores it while the app is active.
    func requestAttention()
}

@MainActor
public final class SystemAttention: AttentionRequesting {
    /// Bursts of messages play one sound at most this often.
    static let minimumSoundInterval: Duration = .milliseconds(900)
    private var lastSound: ContinuousClock.Instant?
    /// At most one sound object is retained (the one playing).
    private var current: NSSound?

    public init() {}

    public func playSound(named name: String) {
        // No app bundle (command-line test host): stay silent.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let now = ContinuousClock.now
        if let lastSound, now - lastSound < Self.minimumSoundInterval { return }
        guard SystemSounds.names.contains(name), let sound = NSSound(named: NSSound.Name(name)) else { return }
        lastSound = now
        current?.stop()
        current = sound
        sound.play()
    }

    public func requestAttention() {
        guard Bundle.main.bundleIdentifier != nil, !NSApplication.shared.isActive else { return }
        NSApplication.shared.requestUserAttention(.informationalRequest)
    }
}

/// The macOS alert sounds (`/System/Library/Sounds`), by `NSSound` name.
public enum SystemSounds {
    /// Names found on this Mac, sorted; falls back to the long-standing macOS set.
    public static let names: [String] = {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let names = found.filter { ["aiff", "aif", "caf", "wav"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.isEmpty && $0.utf8.count <= 64 }
        let unique = Array(Set(names)).sorted().prefix(64)
        return unique.isEmpty ? fallback : Array(unique)
    }()

    static let fallback = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
                           "Sosumi", "Submarine", "Tink"]

    /// The default selection, close to the official client's short "Bing".
    public static var defaultName: String { names.contains("Glass") ? "Glass" : names.first ?? "Glass" }
}
