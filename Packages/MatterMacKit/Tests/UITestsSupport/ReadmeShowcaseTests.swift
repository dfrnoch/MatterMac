import AppKit
import CoreGraphics
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import MatterMacModels
@testable import MatterMacCore
import MattermostAPI
import MattermostRealtime
import UserNotifications
@testable import MatterMacPlatform
import TestSupport
@testable import MatterMacUI

/// README screenshots from a synthetic workspace. Opt-in: `MM_README_SHOWCASE=<dir>`.
///
/// Everything runs in process with the TestSupport fakes (no network, no server):
/// the fictional "Northwind Studio" company, its people, teams, channels and
/// messages are made up here, and every avatar, team icon and attached image is drawn
/// with Core Graphics below. Only this test's own windows are captured
/// (`screencapture -l`), never the screen.
///
/// The windows are real, focused windows on the main display: the test runner
/// becomes the active app (`NSRunningApplication.activate(from:)`) inside
/// `NSApp.run()`, so traffic lights, selection and Liquid Glass draw as in the app's
/// key window. Behind them, a borderless window shows the user's desktop wallpaper
/// (read with `NSWorkspace.desktopImageURL(for:)`, never changed) so the
/// behind-window materials blur the wallpaper and not other apps' windows. Each raw
/// capture (`<dir>/<name>.png`, transparent with the window shadow) is then
/// composited onto the matching crop of that wallpaper (`<dir>/final/<name>.png`,
/// or `.jpg` when a PNG would exceed 1 MB), 2000 px wide. The conversation is short
/// enough to fit between the toolbar and the composer, and every shot shows it from
/// its first message, so no message text ever sits under the title bar (whose
/// scroll edge effect this process does not render reliably).
///
/// This is an XCTest case on purpose: Swift Testing runs test bodies inside a main
/// queue job, where a nested AppKit event loop starves MainActor tasks and the app
/// never learns that it became active. xctest reads the locale and accent before
/// any test runs, so pass them as arguments (they apply to this process only):
///
///     swift build --package-path Packages/MatterMacKit --build-tests
///     MM_README_SHOWCASE=/tmp/mm-showcase xcrun xctest -AppleLocale en_US \
///       -AppleLanguages '(en)' -AppleAccentColor 4 \
///       -XCTest UITestsSupport.ReadmeShowcaseTests/testCaptureReadmeShowcase \
///       Packages/MatterMacKit/.build/out/Products/Debug/UITestsSupport.xctest
///
/// Activation takes focus from the frontmost app for about a minute and is handed
/// back at the end. If macOS refuses it, the run still captures and lists the
/// inactive shots.
///
/// `MM_README_SHOWCASE_ONLY=hero,thread` limits the run to shots whose names start
/// with one of the prefixes. `MM_README_APP_ICON` may name a built `MatterMac.app`
/// (default: `build/Build/Products/Debug/MatterMac.app` in the repository) whose icon
/// replaces the test runner's on the sign-in screen.
final class ReadmeShowcaseTests: XCTestCase {
    @MainActor func testCaptureReadmeShowcase() throws {
        guard let directory = ProcessInfo.processInfo.environment["MM_README_SHOWCASE"] else {
            throw XCTSkip("Set MM_README_SHOWCASE=<directory> to capture the README screenshots.")
        }
        let outcome = Outcome()
        let policy = NSApplication.shared.activationPolicy()
        Task { @MainActor in
            do { try await Showcase.captureAll(into: directory); outcome.result = .success(()) }
            catch { outcome.result = .failure(error) }
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: false)
            }
        }
        while outcome.result == nil { NSApp.run() }
        _ = NSApp.setActivationPolicy(policy)
        try outcome.result?.get()
    }

    @MainActor private final class Outcome { var result: Result<Void, any Error>? }
}

private struct ShowcaseFailure: Error, CustomStringConvertible {
    let description: String
}

/// The xctest tool has a bundle identifier, so the app would reach for the real
/// notification center; the showcase never asks for or posts notifications.
@MainActor private final class SilentNotifications: NotificationCenterTransport {
    func authorizationStatus() async -> SystemNotifications.Authorization { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func add(_ request: UNNotificationRequest, completion: @escaping @Sendable () -> Void) {}
    func remove(identifiers: [String]?) {}
}

private func need<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw ShowcaseFailure(description: "Missing " + what) }
    return value
}

@MainActor private func settleWindow(_ window: NSWindow, seconds: Double) async throws {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
    while ContinuousClock.now < deadline {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
    }
}

// MARK: - Capture flow

@MainActor private enum Showcase {
    static func captureAll(into directory: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        try FileManager.default.createDirectory(atPath: directory + "/final", withIntermediateDirectories: true)
        let only = environment["MM_README_SHOWCASE_ONLY"].map { $0.split(separator: ",").map(String.init) }
        func wanted(_ name: String) -> Bool { only.map { $0.contains { name.hasPrefix($0) } } ?? true }

        let previous = prepareProcess()
        let stage = Stage()
        defer {
            stage.close()
            handBackActivation(to: previous)
        }
        let camera = Camera(directory: directory, stage: stage, previous: previous)

        let f = try await ShowcaseFixture(stage: stage)
        defer { f.window.close() }
        let window = f.window
        let model = f.model
        let settings = f.app.environment.settings

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] where wanted("hero-\(name)") {
            window.appearance = NSAppearance(named: appearance)
            try await f.showConversation()
            try await camera.shoot(window, "hero-\(name)")
        }

        if wanted("thread") {
            window.appearance = NSAppearance(named: .darkAqua)
            model.openThread(root: ShowcaseData.threadRoot)
            try await f.settle { (model.thread?.items.count ?? 0) >= 5 }
            try await f.settle(seconds: 1.2)
            try await f.showConversation()
            try await camera.shoot(window, "thread-dark")
            model.closeThread()
            try await f.settle(seconds: 0.4)
        }

        if wanted("switcher") {
            window.appearance = NSAppearance(named: .darkAqua)
            try await f.showConversation()
            model.isQuickSwitcherVisible = true
            try await f.settle(seconds: 1.5)
            try await camera.shoot(window, "switcher-dark")
            model.isQuickSwitcherVisible = false
            try await f.settle(seconds: 0.6)
        }

        if wanted("media-viewer") {
            window.appearance = NSAppearance(named: .darkAqua)
            try await f.showConversation()
            let pane = try need(model.draftProvider as? ConversationController, "conversation pane")
            pane.timeline(perform: .previewImage(ShowcaseData.dashboardFile))
            let viewer = try need(pane.imageViewer, "image viewer")
            try await f.settle { viewer.state == .loaded }
            try await f.settle(seconds: 1.0)
            try await camera.shoot(window, "media-viewer-dark")
            viewer.close()
            try await f.settle(seconds: 0.6)
        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] where wanted("channel-info-\(name)") {
            window.appearance = NSAppearance(named: appearance)
            model.isChannelInfoVisible = true
            try await f.settle { f.service.calls.contains("channelMembers") }
            try await f.settle(seconds: 1.5)
            try await f.showConversation()
            try await camera.shoot(window, "channel-info-\(name)")
            model.isChannelInfoVisible = false
            try await f.settle(seconds: 0.4)
        }

        if wanted("search") {
            window.appearance = NSAppearance(named: .darkAqua)
            model.isSearchVisible = true
            let editor = try await f.fieldEditor()
            editor.insertText("screenshots", replacementRange: editor.selectedRange())
            try await f.settle { (model.search?.items.count ?? 0) > 0 }
            // The narrower conversation reflows; show it from its first message again.
            try await f.showConversation()
            try await camera.shoot(window, "search-dark")
            model.isSearchVisible = false
            model.clearSearch()
            try await f.settle(seconds: 0.4)
        }

        let themes: [(String, AppTheme, NSAppearance.Name)] = [
            ("themes-dusk-dark", .preset(.dusk), .darkAqua),
            ("themes-lagoon-light", .preset(.lagoon), .aqua),
            ("themes-ember-dark", .preset(.ember), .darkAqua),
            ("themes-aurora-dark", .preset(.aurora), .darkAqua),
            ("themes-dawn-light", .preset(.dawn), .aqua),
        ]
        for (name, theme, appearance) in themes where wanted(name) {
            window.appearance = NSAppearance(named: appearance)
            settings.theme = theme
            try await f.showConversation()
            try await camera.shoot(window, name)
        }
        settings.theme = .system

        if wanted("settings-theme") {
            let settingsWindow = stage.makeWindow(size: NSSize(width: 540, height: 860), title: "Appearance")
            defer { settingsWindow.close() }
            settings.theme = .preset(.dusk)
            settingsWindow.contentViewController = NSHostingController(rootView: AppearanceSettingsTab(settings: settings)
                .themeAccentTint()
                .environment(\.matterMacTheme, settings.theme)
                .frame(width: 540, height: 860))
            settingsWindow.setContentSize(NSSize(width: 540, height: 860))
            stage.place(settingsWindow)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)]
                where wanted("settings-theme-\(name)") {
                settingsWindow.appearance = NSAppearance(named: appearance)
                try await settleWindow(settingsWindow, seconds: 1.0)
                try await camera.shoot(settingsWindow, "settings-theme-\(name)")
            }
            settings.theme = .system
        }

        if wanted("sign-in") {
            try await captureSignIn(stage: stage, camera: camera, wanted: wanted)
        }
        if !camera.inactive.names.isEmpty {
            print("README showcase: inactive captures:", camera.inactive.names.joined(separator: ", "))
        }
        await f.close()
    }

    private static func captureSignIn(stage: Stage, camera: Camera, wanted: (String) -> Bool) async throws {
        let service = FakeMattermostService(endpoint: ShowcaseData.endpoint, me: ShowcaseData.me)
        let app = AppModel(environment: AppEnvironment(serviceFactory: ShowcaseFactory(services: [service]),
            makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) }))
        app.notifications = SystemNotifications(center: SilentNotifications())
        let endpoint = try ServerURLNormalizer.normalize("https://chat.northwind.example", allowInsecureLoopback: false)
        let version = ServerVersion(major: 11, minor: 11, patch: 1)
        let discovery = DiscoveryResult(endpoint: endpoint, version: version,
            capabilities: ServerCapabilities(version: version, siteName: "Northwind Studio",
                login: LoginOptions(email: true, username: true, openID: true,
                                    ssoProviderLabels: [.openID: "Northwind SSO"])))
        let window = stage.makeWindow(size: ShowcaseData.windowSize, title: "MatterMac")
        defer { window.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] where wanted("sign-in-\(name)") {
            window.appearance = NSAppearance(named: appearance)
            let login = LoginModel(discovery: discovery, app: app)
            login.loginID = "alex.morgan@northwind.example"
            login.password = "not-a-real-password"
            window.contentViewController = NSHostingController(rootView: ZStack {
                OnboardingBackdrop(stage: 2)
                LoginView(login: login, app: app)
            }
            .frame(minWidth: 760, minHeight: 500)
            .tint(Showcase.appAccent))
            window.setContentSize(ShowcaseData.windowSize)
            stage.place(window)
            try await settleWindow(window, seconds: 1.2)
            // A caret after the address rather than the whole field selected.
            if let editor = window.firstResponder as? NSTextView {
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            }
            try await camera.shoot(window, "sign-in-\(name)")
        }
        window.contentViewController = nil
        await app.shutdownAll()
    }

    /// English dates, the blue system accent and the app icon, for this test process
    /// only. Returns the app that was frontmost, to hand activation back to.
    static func prepareProcess() -> NSRunningApplication? {
        UserDefaults.standard.setVolatileDomain([
            "AppleLocale": "en_US", "AppleLanguages": ["en"], "AppleAccentColor": 4,
            "AppleHighlightColor": "0.698039 0.843137 1.000000 Blue",
        ], forName: UserDefaults.argumentDomain)
        _ = NSApp.setActivationPolicy(.regular)
        let environment = ProcessInfo.processInfo.environment
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let icon = environment["MM_README_APP_ICON"]
            ?? repository.appendingPathComponent("build/Build/Products/Debug/MatterMac.app").path
        if FileManager.default.fileExists(atPath: icon) {
            NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: icon)
        }
        let front = NSWorkspace.shared.frontmostApplication
        let previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        activate(from: previous)
        return previous
    }

    /// Windows draw as active (colored traffic lights, accent selection) only while
    /// this process is the active app.
    static func activate(from previous: NSRunningApplication?) {
        guard !NSApp.isActive else { return }
        if let previous { _ = NSRunningApplication.current.activate(from: previous, options: []) }
        NSApp.activate()
    }

    static func handBackActivation(to previous: NSRunningApplication?) {
        guard let previous, NSApp.isActive else { return }
        _ = previous.activate(from: NSRunningApplication.current, options: [])
    }

    /// The app's AccentColor asset (the test runner has none).
    static let appAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.408, green: 0.643, blue: 0.941, alpha: 1)
            : NSColor(srgbRed: 0.141, green: 0.282, blue: 0.627, alpha: 1)
    })
}

// MARK: - Stage and camera

/// The main display with the user's wallpaper behind the capture windows.
@MainActor private final class Stage {
    let screen: NSScreen
    /// The wallpaper as the desktop shows it: filling the screen, at backing scale.
    let wallpaper: CGImage?
    private var backdrop: NSWindow?
    private var windows: [NSWindow] = []
    /// Final images: the window centered with a margin of about 6%.
    static let canvas = NSSize(width: 1_440, height: 980)
    static let outputWidth = 2_000

    init() {
        screen = NSScreen.main ?? NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        wallpaper = NSWorkspace.shared.desktopImageURL(for: screen)
            .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            .map { Stage.fill($0, width: Int(size.width * scale), height: Int(size.height * scale)) }
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false,
                                screen: screen)
        backdrop.isReleasedWhenClosed = false
        backdrop.isRestorable = false
        backdrop.ignoresMouseEvents = true
        backdrop.hasShadow = false
        backdrop.backgroundColor = .black
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.contents = wallpaper
        view.layer?.contentsGravity = .resize
        backdrop.contentView = view
        backdrop.setFrame(screen.frame, display: true)
        backdrop.orderFront(nil)
        self.backdrop = backdrop
        // The pointer rests in a screen corner, outside every capture window, so no
        // row shows its hover actions.
        let primary = NSScreen.screens.first?.frame ?? screen.frame
        CGWarpMouseCursorPosition(CGPoint(x: screen.frame.minX + 4, y: primary.maxY - screen.frame.minY - 4))
    }

    static func fill(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = ShowcaseArt.context(width, height)
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        return context.makeImage()!
    }

    func makeWindow(size: NSSize, title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false, screen: screen)
        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        windows.append(window)
        place(window)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Centered on the main display, fully visible.
    func place(_ window: NSWindow) {
        let frame = window.frame
        let origin = NSPoint(x: (screen.frame.midX - frame.width / 2).rounded(),
                             y: (screen.frame.midY - frame.height / 2).rounded())
        window.setFrameOrigin(origin)
    }

    func close() {
        for window in windows { window.close() }
        windows.removeAll()
        backdrop?.close()
        backdrop = nil
    }

    /// The raw capture (window and shadow) over the wallpaper around the window.
    func composite(_ capture: CGImage, window frame: NSRect) -> CGImage? {
        guard let body = Stage.opaqueRect(capture) else { return nil }
        let scale = screen.backingScaleFactor
        let canvas = NSRect(x: frame.midX - Stage.canvas.width / 2, y: frame.midY - Stage.canvas.height / 2,
                            width: Stage.canvas.width, height: Stage.canvas.height)
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        let context = ShowcaseArt.context(width, height)
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let wallpaper {
            context.draw(wallpaper, in: CGRect(x: -(canvas.minX - screen.frame.minX) * scale,
                                               y: -(canvas.minY - screen.frame.minY) * scale,
                                               width: CGFloat(wallpaper.width), height: CGFloat(wallpaper.height)))
        }
        // Align the opaque window body with the window's place on screen.
        let windowX = (frame.minX - canvas.minX) * scale, windowY = (frame.minY - canvas.minY) * scale
        let bodyBottom = CGFloat(capture.height) - body.maxY
        context.draw(capture, in: CGRect(x: windowX - body.minX, y: windowY - bodyBottom,
                                         width: CGFloat(capture.width), height: CGFloat(capture.height)))
        guard let full = context.makeImage() else { return nil }
        let outHeight = Int((CGFloat(Stage.outputWidth) * canvas.height / canvas.width).rounded())
        let output = ShowcaseArt.context(Stage.outputWidth, outHeight)
        output.interpolationQuality = .high
        output.draw(full, in: CGRect(x: 0, y: 0, width: Stage.outputWidth, height: outHeight))
        return output.makeImage()
    }

    /// The fully opaque window body inside a capture with shadow, top-left origin.
    static func opaqueRect(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        let context = ShowcaseArt.context(width, height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // Rows in the bitmap run top to bottom.
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
        let midX = width / 2, midY = height / 2
        guard let top = (0..<height).first(where: { alpha(midX, $0) >= 250 }),
              let bottom = (0..<height).last(where: { alpha(midX, $0) >= 250 }),
              let left = (0..<width).first(where: { alpha($0, midY) >= 250 }),
              let right = (0..<width).last(where: { alpha($0, midY) >= 250 }) else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}

@MainActor private final class InactiveShots { var names: [String] = [] }

/// Captures one window (with its shadow) as `<name>.png` and composites it.
@MainActor private struct Camera {
    let directory: String
    let stage: Stage
    let previous: NSRunningApplication?
    let inactive = InactiveShots()

    func shoot(_ window: NSWindow, _ name: String) async throws {
        Showcase.activate(from: previous)
        window.makeKeyAndOrderFront(nil)
        try await settleWindow(window, seconds: 0.5)
        // Activation can be refused (another app keeps focus): capture anyway and say so.
        if !(NSApp.isActive && window.isKeyWindow) {
            inactive.names.append(name)
            print("README showcase: \(name) was captured while the window was not the active key window")
        }
        let raw = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), raw.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let source = CGImageSourceCreateWithURL(raw as CFURL, nil),
              let capture = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let final = stage.composite(capture, window: window.frame) else {
            throw ShowcaseFailure(description: "\(name): capture failed")
        }
        let base = URL(fileURLWithPath: directory).appendingPathComponent("final").appendingPathComponent(name)
        let png = try Camera.encode(final, type: .png, quality: nil)
        if png.count <= 1_000_000 {
            try png.write(to: base.appendingPathExtension("png"))
        } else {
            try Camera.encode(final, type: .jpeg, quality: 0.85).write(to: base.appendingPathExtension("jpg"))
        }
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double?) throws -> Data {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil) else {
            throw ShowcaseFailure(description: "encoder")
        }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw ShowcaseFailure(description: "encoder") }
        return bytes as Data
    }
}

private struct ShowcaseFactory: MattermostServiceFactory {
    let services: [FakeMattermostService]
    func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
    func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService {
        services.first { $0.endpoint == endpoint } ?? services[0]
    }
}

// MARK: - Fixture

@MainActor private final class ShowcaseFixture {
    let service: FakeMattermostService
    let community: FakeMattermostService
    let realtime = FakeRealtimeConnection()
    let app: AppModel
    let model: SessionViewModel
    let window: NSWindow

    init(stage: Stage) async throws {
        service = FakeMattermostService(endpoint: ShowcaseData.endpoint, me: ShowcaseData.me)
        community = FakeMattermostService(endpoint: ShowcaseData.communityEndpoint, me: ShowcaseData.me)
        ShowcaseData.populate(service)
        let realtime = self.realtime
        app = AppModel(environment: AppEnvironment(serviceFactory: ShowcaseFactory(services: [service, community]),
            makeRealtime: { endpoint, _, _ in endpoint == ShowcaseData.endpoint ? realtime : FakeRealtimeConnection() },
            markupParse: { text, limits in MarkupParser.parse(text, limits: limits) }))
        app.notifications = SystemNotifications(center: SilentNotifications())
        let credential = try need(BearerCredential(token: "fixture-token", kind: .session), "credential")
        let slot = try app.registry.add(endpoint: ShowcaseData.endpoint,
            login: LoginResult(credential: credential, user: ShowcaseData.me),
            capabilities: ServerCapabilities(version: ServerVersion(major: 11, minor: 11, patch: 1), siteName: "Northwind Studio",
                                             collapsedThreads: .alwaysOn))
        // A second signed-in server, shown in the rail (never started).
        _ = try app.registry.add(endpoint: ShowcaseData.communityEndpoint,
            login: LoginResult(credential: credential, user: ShowcaseData.me),
            capabilities: ServerCapabilities(siteName: "Open Maps Collective"))
        app.activate(slot.id)
        model = SessionViewModel(slot: slot, app: app)
        await slot.session.start()
        await realtime.push(.state(.connected(resumed: false)))

        window = stage.makeWindow(size: ShowcaseData.windowSize, title: "MatterMac")
        window.contentViewController = NSHostingController(rootView: MainWindowView(app: app, session: model)
            .frame(minWidth: 760, minHeight: 500))
        window.setContentSize(ShowcaseData.windowSize)
        stage.place(window)

        let channel = ShowcaseData.productLaunch.id
        try await settle { self.model.sidebar?.sections.contains { $0.rows.contains { $0.channelID == channel } } == true }
        model.select(channel: channel)
        try await settle { self.model.header?.channelID == channel && (self.model.timeline?.items.count ?? 0) > 6 }
        guard model.header?.channelID == channel else { throw ShowcaseFailure(description: "The launch channel did not open") }
        try await settle { self.model.connection == .connected }
        try await settle(seconds: 1.5)
    }

    func close() async {
        model.prepareForSignOut()
        app.environment.drafts.discardAll(for: model.scope)
        await app.registry.removeAll()
        await app.shutdownAll()
    }

    func settle(timeout: Double = 5, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1_000))
        while !condition(), ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func settle(seconds: Double) async throws {
        try await settleWindow(window, seconds: seconds)
    }

    /// The channel from its first message: the whole history fits between the
    /// toolbar and the composer in the main shots, and nothing is ever left
    /// scrolled under the title bar (whose edge effect this process does not always
    /// render).
    func showConversation() async throws {
        try await settle(seconds: 0.6)
        guard let pane = model.draftProvider as? ConversationController else { return }
        pane.timeline.scrollToLiveEdge()
        try await settle(seconds: 0.4)
        let clip = pane.timeline.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        pane.timeline.scrollView.reflectScrolledClipView(clip)
        pane.timeline.hoverMouseExited()
        try await settle(seconds: 1.0)
    }

    /// The focused text field's editor (search pane).
    func fieldEditor() async throws -> NSTextView {
        try await settle { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
        try await settle(seconds: 0.3)
        return try need(window.firstResponder as? NSTextView, "search field")
    }
}

// MARK: - Synthetic workspace

/// The fictional Northwind Studio: people, teams, channels and a day of messages
/// about launching its (fictional) "Aurora 2.0" app. No real people or companies.
private enum ShowcaseData {
    static let windowSize = NSSize(width: 1280, height: 880)

    static let endpoint = ServerEndpoint(scheme: .https, host: "chat.northwind.example", port: nil, pathSegments: [])
    static let communityEndpoint = ServerEndpoint(scheme: .https, host: "chat.openmaps.example", port: nil, pathSegments: [])

    static func id(_ prefix: String, _ n: Int) -> String { CoreFixtures.id(prefix, n) }

    // People. `look` indexes the portrait styles below.
    struct Person {
        let user: User
        let look: Portrait
    }

    static let me = User(id: UserID(unchecked: id("alex", 1)), username: "alex", firstName: "Alex", lastName: "Morgan",
                         position: "Product Designer", lastPictureUpdate: MattermostTimestamp(milliseconds: 1),
                         customStatus: CustomStatus(emoji: "rocket", text: "Launch week"))

    static func person(_ n: Int, _ username: String, _ first: String, _ last: String, _ position: String,
                       _ look: Portrait) -> Person {
        Person(user: User(id: UserID(unchecked: id("user", n)), username: username, firstName: first, lastName: last,
                          position: position, lastPictureUpdate: MattermostTimestamp(milliseconds: Int64(n))), look: look)
    }

    static let maya = person(1, "maya", "Maya", "Chen", "Design Lead",
        Portrait(hues: (0.95, 0.06), skin: (0.96, 0.80, 0.68), hair: (0.12, 0.10, 0.12), style: .long, shirt: (0.16, 0.55, 0.56)))
    static let jonas = person(2, "jonas", "Jonas", "Weber", "Engineering Manager",
        Portrait(hues: (0.55, 0.62), skin: (0.98, 0.84, 0.74), hair: (0.86, 0.68, 0.40), style: .short, shirt: (0.16, 0.22, 0.42)))
    static let priya = person(3, "priya", "Priya", "Nair", "Product Manager",
        Portrait(hues: (0.78, 0.90), skin: (0.72, 0.52, 0.38), hair: (0.10, 0.07, 0.07), style: .bun, shirt: (0.90, 0.68, 0.22)))
    static let sam = person(4, "sam", "Sam", "Okafor", "Marketing",
        Portrait(hues: (0.08, 0.13), skin: (0.46, 0.31, 0.23), hair: (0.08, 0.06, 0.06), style: .curly, shirt: (0.22, 0.52, 0.34)))
    static let nora = person(5, "nora", "Nora", "Lindqvist", "Data Analyst",
        Portrait(hues: (0.42, 0.50), skin: (0.98, 0.86, 0.78), hair: (0.62, 0.30, 0.17), style: .long, shirt: (0.93, 0.45, 0.42)))
    static let leo = person(6, "leo", "Leo", "Martins", "QA Engineer",
        Portrait(hues: (0.66, 0.74), skin: (0.86, 0.65, 0.48), hair: (0.32, 0.20, 0.12), style: .short, shirt: (0.85, 0.86, 0.90)))
    static let ava = person(7, "ava", "Ava", "Patel", "iOS Engineer",
        Portrait(hues: (0.02, 0.10), skin: (0.80, 0.60, 0.45), hair: (0.18, 0.11, 0.08), style: .long, shirt: (0.30, 0.32, 0.62)))
    static let ethan = person(8, "ethan", "Ethan", "Brooks", "Backend Engineer",
        Portrait(hues: (0.33, 0.45), skin: (0.95, 0.78, 0.66), hair: (0.45, 0.30, 0.18), style: .short, shirt: (0.55, 0.20, 0.28)))
    static let hana = person(9, "hana", "Hana", "Sato", "Illustrator",
        Portrait(hues: (0.86, 0.96), skin: (0.97, 0.84, 0.72), hair: (0.08, 0.08, 0.10), style: .bun, shirt: (0.35, 0.60, 0.85)))
    static let lucas = person(10, "lucas", "Lucas", "Ferreira", "Support Lead",
        Portrait(hues: (0.12, 0.17), skin: (0.70, 0.50, 0.36), hair: (0.12, 0.09, 0.08), style: .curly, shirt: (0.20, 0.36, 0.60)))
    static let zoe = person(11, "zoe", "Zoe", "Adams", "Copywriter",
        Portrait(hues: (0.50, 0.58), skin: (0.99, 0.87, 0.80), hair: (0.93, 0.78, 0.50), style: .long, shirt: (0.60, 0.36, 0.70)))
    static let people = [maya, jonas, priya, sam, nora, leo, ava, ethan, hana, lucas, zoe]
    static let myLook = Portrait(hues: (0.57, 0.66), skin: (0.93, 0.75, 0.60), hair: (0.26, 0.17, 0.11), style: .short,
                                 shirt: (0.22, 0.24, 0.28))

    // Teams, listed by name like the server does (the first is selected; others carry unread state).
    static let northwind = Team(id: TeamID(unchecked: id("team", 1)), name: "northwind", displayName: "Northwind",
                                iconRevision: 1)
    static let field = Team(id: TeamID(unchecked: id("team", 2)), name: "trail-runners", displayName: "Trail Runners",
                            iconRevision: 1)
    static let harbor = Team(id: TeamID(unchecked: id("team", 3)), name: "northwind-labs", displayName: "Northwind Labs",
                             iconRevision: 1)
    static let guild = Team(id: TeamID(unchecked: id("team", 4)), name: "volunteer-circle", displayName: "Volunteer Circle",
                            iconRevision: 1)
    static let teams = [northwind, field, harbor, guild]

    static func channel(_ n: Int, _ name: String, _ display: String, _ type: ChannelType = .open,
                        header: String = "", purpose: String = "") -> Channel {
        Channel(id: ChannelID(unchecked: id("ch", n)), teamID: northwind.id, type: type, name: name, displayName: display,
                header: header, purpose: purpose)
    }
    static let productLaunch = channel(1, "product-launch", "Product Launch",
        header: "Aurora 2.0 ships Monday — checklist, assets and daily status",
        purpose: "Coordinating the Aurora 2.0 launch across product, design, engineering and marketing.")
    static let designCrit = channel(2, "design-crit", "Design Crit", .private)
    static let announcements = channel(3, "announcements", "Announcements")
    static let engineering = channel(4, "engineering", "Engineering")
    static let general = channel(5, "general", "General")
    static let marketing = channel(6, "marketing", "Marketing")
    static let random = channel(7, "random", "Random")

    // Timestamps: yesterday afternoon and this morning (both a day earlier when the
    // capture runs before the morning messages would have been written).
    static let morning: Date = {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: .now)
        if Date.now < day.addingTimeInterval(11 * 3_600) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        return day.addingTimeInterval(9 * 3_600)
    }()
    static func at(_ hours: Double, dayOffset: Int = 0) -> MattermostTimestamp {
        let date = morning.addingTimeInterval(TimeInterval(dayOffset) * 86_400 + (hours - 9) * 3_600)
        return MattermostTimestamp(milliseconds: Int64(date.timeIntervalSince1970 * 1_000))
    }
    static func time(_ h: Int, _ m: Int, yesterday: Bool = false) -> MattermostTimestamp {
        at(Double(h) + Double(m) / 60, dayOffset: yesterday ? -1 : 0)
    }

    static let dashboardFile = FileInfo(id: FileID(unchecked: id("file", 1)), postID: PostID(unchecked: id("post", 4)),
        channelID: productLaunch.id, name: "aurora-beta-dashboard.png", fileExtension: "png", size: 486_213,
        mimeType: "image/png", width: 2_400, height: 960, hasPreviewImage: true)
    static let pressKit = FileInfo(id: FileID(unchecked: id("file", 2)), postID: PostID(unchecked: id("post", 5)),
        channelID: productLaunch.id, name: "Aurora-2.0-Press-Kit.pdf", fileExtension: "pdf", size: 4_381_204,
        mimeType: "application/pdf")
    static let threadRoot = PostID(unchecked: id("post", 6))

    static func post(_ n: Int, _ author: User, _ at: MattermostTimestamp, _ message: String, root: Int? = nil,
                     reactions: [(String, [User])] = [], files: [FileInfo] = [], replies: Int = 0,
                     lastReply: MattermostTimestamp = .zero, pinned: Bool = false, edited: Bool = false) -> Post {
        let id = PostID(unchecked: Self.id("post", n))
        let list = reactions.flatMap { name, users in
            users.enumerated().map { index, user in
                Reaction(userID: user.id, postID: id, emojiName: name,
                         createAt: MattermostTimestamp(milliseconds: at.milliseconds + Int64(index + 1) * 1_000))
            }
        }
        return Post(id: id, channelID: productLaunch.id, userID: author.id,
                    rootID: root.map { PostID(unchecked: Self.id("post", $0)) }, message: message, createAt: at,
                    editAt: edited ? MattermostTimestamp(milliseconds: at.milliseconds + 90_000) : .zero,
                    isPinned: pinned, fileIDs: files.map(\.id), files: files, reactions: list,
                    hasReactions: !list.isEmpty, replyCount: replies, lastReplyAt: lastReply)
    }

    static var posts: [Post] {
        let (maya, jonas, priya, sam, nora, leo) = (maya.user, jonas.user, priya.user, sam.user, nora.user, leo.user)
        return [
            post(4, nora, time(9, 5), """
                Beta metrics after week 3 :chart_with_upwards_trend: daily active testers are up **211%**. \
                The full dashboard, for the launch deck:
                """, reactions: [("fire", [priya, sam, me]), ("rocket", [jonas, maya])], files: [dashboardFile]),
            post(5, maya, time(9, 21), """
                Final App Store screenshots and the press kit are ready for review. \
                Preview page: https://northwind.example/press/aurora
                """, reactions: [("heart_eyes", [zoe.user, sam]), ("raised_hands", [priya])], files: [pressKit],
                pinned: true),
            post(6, sam, time(9, 34), "Can we lock the launch announcement copy by noon? :eyes:",
                 reactions: [("eyes", [priya, maya])], replies: 4, lastReply: time(10, 48)),
            post(7, priya, time(9, 41), "Yes — the draft is in the launch doc, comments welcome.", root: 6),
            post(8, maya, time(9, 52), "Added the hero image and alt text :art:", root: 6),
            post(9, jonas, time(10, 30), """
                Engineering sign-off :white_check_mark: The flags for launch day:
                ```swift
                let launch = FeatureFlags(
                    onboardingV2: true,
                    sharedWorkspaces: .rollout(percent: 25)
                )
                ```
                """, root: 6, reactions: [("100", [sam])], edited: true),
            post(10, sam, time(10, 48), "Perfect, locking it at 12:00. Thanks all! :tada:", root: 6,
                 reactions: [("tada", [priya, maya, me])]),
            post(11, leo, time(10, 2), """
                Launch checklist:
                - [x] Release notes
                - [x] Localized screenshots
                - [ ] Status page update
                - [ ] Announce in ~general
                """),
            post(12, priya, time(10, 15), "@alex could you give the release notes a final read before we freeze? :pray:",
                 reactions: [("white_check_mark", [me])]),
        ]
    }

    static func populate(_ service: FakeMattermostService) {
        let posts = Self.posts
        let roots = posts.filter { $0.rootID == nil }
        let lastRoot = roots.map(\.createAt.milliseconds).max() ?? 0
        let avatars = Dictionary(uniqueKeysWithValues: people.map { ($0.user.id, ShowcaseArt.portrait($0.look)) }
            + [(me.id, ShowcaseArt.portrait(myLook))])
        let icons: [TeamID: Data] = [northwind.id: ShowcaseArt.teamIcon(.wind), field.id: ShowcaseArt.teamIcon(.leaf),
                                     harbor.id: ShowcaseArt.teamIcon(.wave), guild.id: ShowcaseArt.teamIcon(.rings)]
        let dashboard = ShowcaseArt.dashboardPNG()
        let myID = me.id
        service.withState { state in
            state.teams = teams
            state.collapsedThreadsConfig = "always_on"
            state.preferences = [
                Preference(category: "display_settings", name: "name_format", value: "full_name"),
                Preference(category: "favorite_channel", name: productLaunch.id.rawValue, value: "true"),
                Preference(category: "favorite_channel", name: designCrit.id.rawValue, value: "true"),
            ]
            for person in people { state.users[person.user.id] = person.user }
            state.users[myID] = me
            state.me = me
            for post in posts { state.posts[post.id] = post }
            state.statuses = [
                myID: .online, maya.user.id: .online, jonas.user.id: .away, priya.user.id: .doNotDisturb,
                sam.user.id: .online, nora.user.id: .online, leo.user.id: .offline, ava.user.id: .online,
                ethan.user.id: .away, hana.user.id: .offline, lucas.user.id: .online, zoe.user.id: .online,
            ]

            func add(_ channel: Channel, lastPost: MattermostTimestamp, total: Int64 = 0, read: Int64? = nil,
                     viewed: MattermostTimestamp? = nil, mentions: Int64 = 0, muted: Bool = false) {
                var channel = channel
                channel.totalMessageCount = total
                channel.totalMessageCountRoot = total
                channel.lastPostAt = lastPost
                channel.lastRootPostAt = lastPost
                state.channels[channel.id] = channel
                state.memberships[channel.id] = ChannelMembership(
                    channelID: channel.id, userID: myID, lastViewedAt: viewed ?? lastPost,
                    messageCount: read ?? total, messageCountRoot: read ?? total,
                    mentionCount: mentions, mentionCountRoot: mentions, markUnread: muted ? .mention : .all)
            }
            // The launch channel was last read before the checklist.
            add(productLaunch, lastPost: MattermostTimestamp(milliseconds: lastRoot), total: Int64(roots.count),
                read: Int64(roots.count - 2), viewed: time(9, 35))
            add(designCrit, lastPost: time(10, 20), total: 9, read: 6, mentions: 2)
            add(announcements, lastPost: time(8, 30), total: 4, read: 3, muted: true)
            add(engineering, lastPost: time(10, 25), total: 30, read: 24)
            add(general, lastPost: time(8, 55), total: 12)
            add(marketing, lastPost: time(9, 10), total: 7)
            add(random, lastPost: time(8, 40), total: 20)

            // Direct and group messages, most recent first in the sidebar.
            let direct: [(Person, MattermostTimestamp, Int64)] = [
                (maya, time(10, 22), 1), (jonas, time(10, 5), 0), (priya, time(9, 58), 0),
                (sam, time(9, 12), 0), (nora, time(16, 5, yesterday: true), 0), (leo, time(15, 0, yesterday: true), 0),
            ]
            for (index, (person, last, mentions)) in direct.enumerated() {
                let dm = Channel(id: ChannelID(unchecked: id("dm", index + 1)), teamID: nil, type: .direct,
                                 name: [myID.rawValue, person.user.id.rawValue].sorted().joined(separator: "__"),
                                 displayName: "")
                add(dm, lastPost: last, total: 10 + mentions, read: 10, mentions: mentions)
            }
            let group = Channel(id: ChannelID(unchecked: id("gm", 1)), teamID: nil, type: .group,
                                name: "gm-launch-crew", displayName: "alex, hana, maya, zoe")
            add(group, lastPost: time(9, 45), total: 6)

            state.threads = [UserThread(root: posts[5], replyCount: 4, lastReplyAt: time(10, 48), lastViewedAt: time(9, 45),
                                        unreadReplies: 2, unreadMentions: 0, participants: [sam.user, priya.user, maya.user, jonas.user])]
            // Collapsed reply threads: channel pages hold root posts only.
            state.postsHandler = { channel, query in
                let page = roots.filter { $0.channelID == channel }.sorted { $0.createAt > $1.createAt }
                if case .latest = query { return PostPage(posts: page) }
                return PostPage(posts: [])
            }
            state.imageHandler = { resource, _ in
                switch resource {
                case .profileImage(let user, _):
                    if let data = avatars[user] { return data }
                case .teamIcon(let team, _):
                    if let data = icons[team] { return data }
                case .fileThumbnail, .filePreview:
                    return dashboard
                default:
                    break
                }
                throw CancellationError()
            }
        }
        service.withDirectory { state in
            state.favorites = [productLaunch.id, designCrit.id]
            state.memberCounts[productLaunch.id] = people.count + 1
            state.teamUnreads = [
                TeamUnread(teamID: field.id, messageCount: 5, mentionCount: 0, messageCountRoot: 5),
                TeamUnread(teamID: harbor.id, messageCount: 8, mentionCount: 3, messageCountRoot: 8, mentionCountRoot: 3),
            ]
        }
        service.withProfile { state in
            state.files = [dashboardFile, pressKit]
        }
    }
}

// MARK: - Core Graphics art

/// A flat, illustrated stand-in for a profile photo.
private struct Portrait: Sendable {
    enum Style: Sendable { case short, long, bun, curly }
    let hues: (Double, Double)
    let skin: (Double, Double, Double)
    let hair: (Double, Double, Double)
    let style: Style
    let shirt: (Double, Double, Double)
}

private enum ShowcaseArt {
    enum Glyph { case wind, leaf, wave, rings }

    static func rgb(_ c: (Double, Double, Double), _ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
    }
    static func hsb(_ h: Double, _ s: Double, _ b: Double, _ alpha: Double = 1) -> CGColor {
        NSColor(hue: CGFloat(h.truncatingRemainder(dividingBy: 1)), saturation: CGFloat(s), brightness: CGFloat(b),
                alpha: CGFloat(alpha)).cgColor
    }
    static func shade(_ c: (Double, Double, Double), _ factor: Double) -> (Double, Double, Double) {
        (c.0 * factor, c.1 * factor, c.2 * factor)
    }

    static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func png(_ context: CGContext) -> Data {
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    static func linear(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func portrait(_ look: Portrait) -> Data {
        let s: CGFloat = 256
        let c = context(Int(s), Int(s))
        linear(c, [hsb(look.hues.0, 0.32, 0.98), hsb(look.hues.1, 0.55, 0.86)],
               from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
        // Soft light behind the head.
        c.setFillColor(CGColor(gray: 1, alpha: 0.18))
        c.fillEllipse(in: CGRect(x: s * 0.12, y: s * 0.30, width: s * 0.76, height: s * 0.76))
        let skin = rgb(look.skin), hair = rgb(look.hair)
        // Hair that falls behind the shoulders.
        if look.style == .long {
            c.setFillColor(hair)
            c.addPath(CGPath(roundedRect: CGRect(x: s * 0.28, y: s * 0.26, width: s * 0.44, height: s * 0.50),
                             cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil))
            c.fillPath()
        }
        // Shoulders and neck.
        c.setFillColor(rgb(look.shirt))
        c.fillEllipse(in: CGRect(x: s * 0.12, y: -s * 0.30, width: s * 0.76, height: s * 0.62))
        c.setFillColor(rgb(shade(look.skin, 0.9)))
        c.addPath(CGPath(roundedRect: CGRect(x: s * 0.43, y: s * 0.24, width: s * 0.14, height: s * 0.18),
                         cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
        c.fillPath()
        // Collar.
        c.setFillColor(rgb(shade(look.shirt, 0.82)))
        c.fillEllipse(in: CGRect(x: s * 0.40, y: s * 0.22, width: s * 0.20, height: s * 0.08))
        // Head and ears.
        c.setFillColor(skin)
        c.fillEllipse(in: CGRect(x: s * 0.30, y: s * 0.49, width: s * 0.06, height: s * 0.10))
        c.fillEllipse(in: CGRect(x: s * 0.64, y: s * 0.49, width: s * 0.06, height: s * 0.10))
        c.fillEllipse(in: CGRect(x: s * 0.33, y: s * 0.36, width: s * 0.34, height: s * 0.42))
        // Cheeks.
        c.setFillColor(CGColor(srgbRed: 0.95, green: 0.45, blue: 0.45, alpha: 0.16))
        c.fillEllipse(in: CGRect(x: s * 0.36, y: s * 0.46, width: s * 0.07, height: s * 0.05))
        c.fillEllipse(in: CGRect(x: s * 0.57, y: s * 0.46, width: s * 0.07, height: s * 0.05))
        // Hair on top.
        c.setFillColor(hair)
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: s * 0.62, width: s, height: s))
        c.fillEllipse(in: CGRect(x: s * 0.31, y: s * 0.55, width: s * 0.38, height: s * 0.29))
        c.restoreGState()
        switch look.style {
        case .short:
            c.fillEllipse(in: CGRect(x: s * 0.40, y: s * 0.66, width: s * 0.26, height: s * 0.13))
        case .long:
            c.fillEllipse(in: CGRect(x: s * 0.30, y: s * 0.52, width: s * 0.09, height: s * 0.20))
            c.fillEllipse(in: CGRect(x: s * 0.61, y: s * 0.52, width: s * 0.09, height: s * 0.20))
        case .bun:
            c.fillEllipse(in: CGRect(x: s * 0.41, y: s * 0.77, width: s * 0.18, height: s * 0.16))
        case .curly:
            for (x, y) in [(0.32, 0.66), (0.40, 0.72), (0.50, 0.74), (0.60, 0.72), (0.68, 0.66)] {
                c.fillEllipse(in: CGRect(x: s * (x - 0.08), y: s * (y - 0.06), width: s * 0.16, height: s * 0.14))
            }
        }
        return png(c)
    }

    static func teamIcon(_ glyph: Glyph) -> Data {
        let s: CGFloat = 256
        let c = context(Int(s), Int(s))
        let (top, bottom): (CGColor, CGColor) = switch glyph {
        case .wind: (hsb(0.58, 0.55, 0.98), hsb(0.68, 0.78, 0.78))
        case .leaf: (hsb(0.30, 0.55, 0.88), hsb(0.44, 0.80, 0.60))
        case .wave: (hsb(0.52, 0.65, 0.95), hsb(0.58, 0.85, 0.62))
        case .rings: (hsb(0.95, 0.50, 1.0), hsb(0.06, 0.75, 0.92))
        }
        linear(c, [top, bottom], from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
        let white = CGColor(gray: 1, alpha: 1)
        c.setStrokeColor(white)
        c.setFillColor(white)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        switch glyph {
        case .wind:
            c.setLineWidth(s * 0.075)
            for (y, length, curl) in [(0.66, 0.46, true), (0.50, 0.58, false), (0.34, 0.36, true)] {
                let path = CGMutablePath()
                let start = CGPoint(x: s * 0.2, y: s * y)
                let end = CGPoint(x: s * (0.2 + length), y: s * y)
                path.move(to: start)
                path.addLine(to: end)
                if curl {
                    path.addArc(center: CGPoint(x: end.x, y: end.y + s * 0.07), radius: s * 0.07,
                                startAngle: -.pi / 2, endAngle: .pi * 0.9, clockwise: false)
                }
                c.addPath(path)
                c.strokePath()
            }
        case .leaf:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: s * 0.24, y: s * 0.24))
            path.addCurve(to: CGPoint(x: s * 0.78, y: s * 0.78), control1: CGPoint(x: s * 0.22, y: s * 0.66),
                          control2: CGPoint(x: s * 0.52, y: s * 0.80))
            path.addCurve(to: CGPoint(x: s * 0.24, y: s * 0.24), control1: CGPoint(x: s * 0.80, y: s * 0.50),
                          control2: CGPoint(x: s * 0.62, y: s * 0.22))
            c.addPath(path)
            c.fillPath()
            c.setStrokeColor(bottom)
            c.setLineWidth(s * 0.035)
            c.move(to: CGPoint(x: s * 0.28, y: s * 0.28))
            c.addLine(to: CGPoint(x: s * 0.66, y: s * 0.66))
            c.strokePath()
        case .wave:
            c.fillEllipse(in: CGRect(x: s * 0.54, y: s * 0.56, width: s * 0.2, height: s * 0.2))
            c.setLineWidth(s * 0.07)
            for y in [0.40, 0.24] {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: s * 0.16, y: s * y))
                for step in 1...4 {
                    let x0 = 0.16 + Double(step - 1) * 0.17
                    path.addQuadCurve(to: CGPoint(x: s * (x0 + 0.17), y: s * y),
                                      control: CGPoint(x: s * (x0 + 0.085), y: s * (y + (step % 2 == 1 ? 0.09 : -0.09))))
                }
                c.addPath(path)
                c.strokePath()
            }
        case .rings:
            c.setLineWidth(s * 0.065)
            for (x, y) in [(0.40, 0.58), (0.60, 0.58), (0.50, 0.40)] {
                c.strokeEllipse(in: CGRect(x: s * (x - 0.17), y: s * (y - 0.17), width: s * 0.34, height: s * 0.34))
            }
        }
        return png(c)
    }

    // A synthetic analytics dashboard: KPI cards, a line chart and bars (no real data).
    static func dashboardPNG() -> Data {
        let scale: CGFloat = 1.5
        let (w, h): (CGFloat, CGFloat) = (1_600, 640)
        let c = context(Int(w * scale), Int(h * scale))
        c.scaleBy(x: scale, y: scale)
        let ink = rgb((0.11, 0.13, 0.20)), muted = rgb((0.45, 0.48, 0.58)), faint = rgb((0.88, 0.90, 0.94))
        let blue = rgb((0.24, 0.42, 0.96)), green = rgb((0.13, 0.62, 0.42))
        linear(c, [rgb((0.97, 0.975, 1.0)), rgb((0.93, 0.95, 0.99))], from: CGPoint(x: 0, y: h), to: CGPoint(x: w, y: 0))

        func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: CGColor, x: CGFloat, y: CGFloat,
                  alignRight: Bool = false, monospaced: Bool = false) {
            let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                                  : NSFont.systemFont(ofSize: size, weight: weight)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            c.textPosition = CGPoint(x: alignRight ? x - CGFloat(width) : x, y: y)
            CTLineDraw(line, c)
        }
        func card(_ rect: CGRect) {
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: rgb((0.20, 0.25, 0.45), 0.10))
            c.addPath(CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil))
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fillPath()
            c.restoreGState()
        }
        func pill(_ rect: CGRect, _ color: CGColor) {
            c.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
            c.setFillColor(color)
            c.fillPath()
        }

        // Header.
        text("Aurora 2.0 · Beta health", 34, .bold, ink, x: 64, y: h - 84)
        text("Weeks 1–3 · 4,212 testers in 38 countries", 18, .regular, muted, x: 64, y: h - 116)
        pill(CGRect(x: w - 64 - 210, y: h - 104, width: 210, height: 44), rgb((0.13, 0.62, 0.42), 0.12))
        c.setFillColor(green)
        c.fillEllipse(in: CGRect(x: w - 64 - 190, y: h - 88, width: 12, height: 12))
        text("Ready for launch", 18, .semibold, green, x: w - 64 - 168, y: h - 88)

        // KPI cards.
        let kpis = [("Daily active testers", "3,860", "+211%"), ("Crash-free sessions", "99.8%", "+0.7 pts"),
                    ("Average session", "9m 47s", "+58%"), ("Beta rating", "4.8 ★", "1,204 reviews")]
        let cardWidth = (w - 128 - 3 * 24) / 4
        for (index, kpi) in kpis.enumerated() {
            let x = 64 + CGFloat(index) * (cardWidth + 24)
            let rect = CGRect(x: x, y: h - 290, width: cardWidth, height: 140)
            card(rect)
            text(kpi.0, 17, .medium, muted, x: x + 28, y: rect.maxY - 44)
            text(kpi.1, 42, .bold, ink, x: x + 28, y: rect.maxY - 86, monospaced: true)
            let positive = kpi.2.hasPrefix("+")
            let deltaColor = positive ? green : muted
            pill(CGRect(x: x + 28, y: rect.minY + 12, width: positive ? 96 : 132, height: 28),
                 positive ? rgb((0.13, 0.62, 0.42), 0.12) : rgb((0.45, 0.48, 0.58), 0.10))
            text(kpi.2, 15, .semibold, deltaColor, x: x + 40, y: rect.minY + 20)
        }

        // Line chart: daily active testers over 21 days.
        let chart = CGRect(x: 64, y: 44, width: 960, height: 290)
        card(chart)
        text("Daily active testers", 20, .semibold, ink, x: chart.minX + 32, y: chart.maxY - 48)
        text("Last 21 days", 16, .regular, muted, x: chart.maxX - 32, y: chart.maxY - 46, alignRight: true)
        let plot = CGRect(x: chart.minX + 84, y: chart.minY + 56, width: chart.width - 120, height: chart.height - 140)
        let values: [CGFloat] = [1_240, 1_310, 1_420, 1_380, 1_560, 1_720, 1_690, 1_880, 2_050, 2_010, 2_260, 2_480,
                                 2_420, 2_690, 2_880, 2_950, 3_120, 3_310, 3_260, 3_590, 3_860]
        let maxValue: CGFloat = 4_000
        c.setLineWidth(1)
        for step in 0...4 {
            let y = plot.minY + plot.height * CGFloat(step) / 4
            c.setStrokeColor(faint)
            c.move(to: CGPoint(x: plot.minX, y: y))
            c.addLine(to: CGPoint(x: plot.maxX, y: y))
            c.strokePath()
            text(step == 0 ? "0" : "\(step)k", 14, .regular, muted, x: plot.minX - 16, y: y - 5, alignRight: true)
        }
        for (index, label) in ["Week 1", "Week 2", "Week 3"].enumerated() {
            text(label, 14, .regular, muted, x: plot.minX + plot.width * (CGFloat(index) + 0.5) / 3 - 22, y: chart.minY + 28)
        }
        let points = values.enumerated().map { index, value in
            CGPoint(x: plot.minX + plot.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: plot.minY + plot.height * value / maxValue)
        }
        let line = CGMutablePath()
        line.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            let midX = (previous.x + point.x) / 2
            line.addCurve(to: point, control1: CGPoint(x: midX, y: previous.y), control2: CGPoint(x: midX, y: point.y))
        }
        let area = line.mutableCopy()!
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        area.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
        area.closeSubpath()
        c.saveGState()
        c.addPath(area)
        c.clip()
        linear(c, [rgb((0.24, 0.42, 0.96), 0.28), rgb((0.24, 0.42, 0.96), 0.02)],
               from: CGPoint(x: 0, y: plot.maxY), to: CGPoint(x: 0, y: plot.minY))
        c.restoreGState()
        c.addPath(line)
        c.setStrokeColor(blue)
        c.setLineWidth(5)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        c.strokePath()
        let last = points[points.count - 1]
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fillEllipse(in: CGRect(x: last.x - 11, y: last.y - 11, width: 22, height: 22))
        c.setFillColor(blue)
        c.fillEllipse(in: CGRect(x: last.x - 7, y: last.y - 7, width: 14, height: 14))
        pill(CGRect(x: last.x - 112, y: last.y - 16, width: 84, height: 32), ink)
        text("3,860", 16, .bold, CGColor(gray: 1, alpha: 1), x: last.x - 96, y: last.y - 6, monospaced: true)

        // Bars: top feedback themes.
        let bars = CGRect(x: chart.maxX + 24, y: 44, width: w - 64 - chart.maxX - 24, height: 290)
        card(bars)
        text("Top feedback themes", 20, .semibold, ink, x: bars.minX + 32, y: bars.maxY - 48)
        let themes: [(String, CGFloat)] = [("Onboarding", 0.42), ("Search", 0.27), ("Sync", 0.16), ("Widgets", 0.09),
                                           ("Other", 0.06)]
        let trackWidth = bars.width - 64
        for (index, theme) in themes.enumerated() {
            let y = bars.maxY - 92 - CGFloat(index) * 42
            text(theme.0, 16, .medium, ink, x: bars.minX + 32, y: y + 16)
            text("\(Int(theme.1 * 100))%", 16, .semibold, muted, x: bars.maxX - 32, y: y + 16, alignRight: true, monospaced: true)
            pill(CGRect(x: bars.minX + 32, y: y - 6, width: trackWidth, height: 12), faint)
            pill(CGRect(x: bars.minX + 32, y: y - 6, width: max(12, trackWidth * theme.1 / 0.42), height: 12),
                 rgb((0.24, 0.42, 0.96), 1 - Double(index) * 0.15))
        }
        return png(c)
    }
}
