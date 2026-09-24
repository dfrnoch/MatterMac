import AppKit
public import Foundation
import Network
public import MatterMacModels
import UniformTypeIdentifiers

/// Explicit external navigation (SPEC §14, §19). Only `SafeLink` destinations
/// (http/https/mailto) can be opened, and only from an explicit user action. No
/// credentials are ever attached; the system browser handles the URL.
@MainActor
public enum ExternalLinks {
    public static func open(_ link: SafeLink) {
        NSWorkspace.shared.open(link.url)
    }

    /// Opens a URL on the user's own server in the browser (e.g. an unsupported
    /// plugin or call). Labeled as external in the UI by the caller.
    public static func openInBrowser(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
public enum Pasteboard {
    public static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    public static func copy(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        board.setString(url.absoluteString, forType: .string)
    }
}

/// Native open/save panels. Returned URLs come from user selection; security-scoped
/// access is started by the caller for the duration of the transfer only and is never
/// persisted (no bookmarks).
@MainActor
public enum FilePanels {
    public struct ChosenFile: Sendable, Hashable {
        public let url: URL
        public let name: String
        public let size: Int64
    }

    public static func chooseAttachments(limit: Int) -> [ChosenFile] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = limit > 1
        panel.resolvesAliases = true
        panel.message = String(localized: "Choose files to attach. MatterMac reads them directly when sending and does not copy them.")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.prefix(limit).compactMap(describe)
    }

    public static func describe(_ url: URL) -> ChosenFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .nameKey]),
              values.isRegularFile == true
        else { return nil }
        return ChosenFile(url: url, name: values.name ?? url.lastPathComponent, size: Int64(values.fileSize ?? 0))
    }

    /// Asks where to save a download. The suggested name is sanitized: no path
    /// separators, no leading dots, no control characters.
    public static func chooseDownloadDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitizedFileName(suggestedName)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = String(localized: "MatterMac will save the file here. This is an explicit export outside the app’s session-only memory.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func chooseExportDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitizedFileName(suggestedName)
        panel.allowedContentTypes = [.plainText]
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func sanitizedFileName(_ raw: String) -> String {
        var name = raw.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f && scalar != "/" && scalar != ":" && scalar != "\\"
        }.map(String.init).joined()
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "download" }
        if name.utf8.count > 200 { name = String(name.prefix(200)) }
        return name
    }
}

/// Observes system events relevant to connection recovery and read state: sleep/wake,
/// network path changes, app activation, and window visibility. A path change is a
/// *hint* to try reconnecting, never proof the server is reachable (SPEC §17).
@MainActor
public final class SystemEventMonitor {
    public var onWake: (() -> Void)?
    public var onNetworkPathChange: ((_ isSatisfied: Bool) -> Void)?
    public var onActivationChange: ((_ isActive: Bool) -> Void)?

    private var observers: [any NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status?

    public init() {}

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake?() }
        })
        let app = NotificationCenter.default
        observers.append(app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onActivationChange?(true) }
        })
        observers.append(app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onActivationChange?(false) }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor in self?.pathChanged(status) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "org.mattermac.path", qos: .utility))
    }

    private func pathChanged(_ status: NWPath.Status) {
        defer { lastPathStatus = status }
        guard let previous = lastPathStatus, previous != status else { return }
        onNetworkPathChange?(status == .satisfied)
    }

    public func stop() {
        pathMonitor.cancel()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // `deinit` cannot touch main-actor state; owners call `stop()` explicitly.
}
