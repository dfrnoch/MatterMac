import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

/// The ⌘K palette in the real shell: sections, keyboard navigation, opening and
/// closing. `MM_SWITCHER_SNAPSHOTS=<dir>` also captures only the test window, in
/// light and dark appearance, with synthetic fixture data.
@MainActor
@Suite("Quick switcher palette", .serialized)
struct QuickSwitcherUITests {
    // MARK: Presentation logic

    private func item(_ n: Int, _ section: QuickSwitchItem.Section, type: ChannelType = .open,
                      mentions: Int = 0, unread: Bool = false, subtitle: String = "") -> QuickSwitchItem {
        QuickSwitchItem(kind: .channel(CoreFixtures.channel(n).id), title: "Item \(n)", subtitle: subtitle,
                        channelType: type, isUnread: unread || mentions > 0, mentionCount: mentions, section: section)
    }

    @Test func groupsFollowResultOrderWithHeaders() {
        let empty = QuickSwitcherGroup.groups([item(1, .unread), item(2, .unread), item(3, .recent)])
        #expect(empty.map(\.title) == ["Unread", "Recent"])
        #expect(empty.map { $0.items.count } == [2, 1])
        #expect(empty.map(\.isFirst) == [true, false])
        // Ranked matches carry a header only when people follow them.
        #expect(QuickSwitcherGroup.groups([item(1, .matches), item(2, .matches)]).map(\.title) == [nil])
        let mixed = QuickSwitcherGroup.groups([item(1, .matches), item(2, .people)])
        #expect(mixed.map(\.title) == ["Conversations", "People"])
        #expect(QuickSwitcherGroup.groups([]).isEmpty)
    }

    @Test func accessibilityLabelsDescribeKindAndState() {
        #expect(QuickSwitcherText.accessibilityLabel(item(1, .unread, mentions: 3)) == "Item 1, channel, 3 mentions")
        #expect(QuickSwitcherText.accessibilityLabel(item(2, .recent, type: .private, unread: true, subtitle: "Design"))
                == "Item 2, private channel, Design, unread")
        let person = QuickSwitchItem(kind: .user(CoreFixtures.bob.id), title: "Bob", subtitle: "@bob", channelType: .direct,
                                     isUnread: false, section: .people, presence: .online)
        #expect(QuickSwitcherText.accessibilityLabel(person) == "Bob, person, @bob, Online")
        #expect(QuickSwitcherText.badge(7) == "7")
        #expect(QuickSwitcherText.badge(120) == "99+")
    }

    @Test func metricsKeepThePaletteInsideSmallWindows() {
        #expect(QuickSwitcherMetrics.topInset(forHeight: 500) == 12)
        #expect(QuickSwitcherMetrics.topInset(forHeight: 900) == 96)
        #expect(QuickSwitcherMetrics.panelHeight(forAvailable: 2_000) == QuickSwitcherMetrics.maxHeight)
        #expect(QuickSwitcherMetrics.panelHeight(forAvailable: 420) == 404)
    }

    // MARK: In the shell

    @Test func typingNavigatingOpeningAndClosing() async throws {
        let f = try await Fixture(onScreen: false)
        defer { f.close() }
        f.model.isQuickSwitcherVisible = true
        let editor = try await f.fieldEditor()
        try await f.settle { f.titles().count > 0 }
        // No query: unread first (mentions, then newest), then recently viewed; the
        // open channel and archived channels are left out.
        let palette = try #require(f.probe.model)
        #expect(f.titles().prefix(3) == ["Olivia Bennett", "Design Reviews", "Release Planning"])
        #expect(palette.results.prefix(3).allSatisfy { $0.section == .unread })
        #expect(palette.results.dropFirst(3).first?.section == .recent)
        #expect(!f.titles().contains("Town Square") && !f.titles().contains("Marketing Launch"))
        #expect(palette.selection == palette.results.first?.kind)

        editor.insertText("so", replacementRange: editor.selectedRange())
        try await f.settle { f.titles().contains("Sophie Turner") }
        #expect(palette.query == "so")
        #expect(f.titles() == ["Sofia Martinez", "Noah Kim, Sofia Martinez, Emma Thompson",
                               "Olivia Bennett, Marcus Chen, Priya Raman, Liam Walker, Noah Kim, Emma Thompson",
                               "Emma Thompson", "Sophie Turner"])
        #expect(palette.results.last?.section == .people)
        #expect(f.selectedTitle() == "Sofia Martinez")
        // Arrow keys move the selection (clamped); Return opens it.
        f.key(125, "\u{F701}")
        try await f.settle { f.selectedTitle() != "Sofia Martinez" }
        #expect(f.selectedTitle() == "Noah Kim, Sofia Martinez, Emma Thompson")
        f.key(126, "\u{F700}")
        f.key(126, "\u{F700}")
        try await f.settle(iterations: 5)
        #expect(f.selectedTitle() == "Sofia Martinez")
        f.key(125, "\u{F701}")
        try await f.settle(iterations: 5)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await f.settle { !f.model.isQuickSwitcherVisible }
        #expect(f.model.selectedChannel == SwitcherData.group.id)

        // Escape closes without navigating, and a new presentation starts empty.
        f.model.isQuickSwitcherVisible = true
        _ = try await f.fieldEditor()
        try await f.settle { f.probe.model !== palette && f.titles().first == "Olivia Bennett" }
        #expect(f.probe.model?.query == "")
        f.key(53, "\u{1B}")
        try await f.settle { !f.model.isQuickSwitcherVisible }
        #expect(f.model.selectedChannel == SwitcherData.group.id)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM_SWITCHER_SNAPSHOTS"] != nil))
    func captureSwitcher() async throws {
        let directory = ProcessInfo.processInfo.environment["MM_SWITCHER_SNAPSHOTS"]!
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let f = try await Fixture(onScreen: true)
        defer { f.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            f.window.appearance = NSAppearance(named: appearance)
            f.model.isQuickSwitcherVisible = true
            let editor = try await f.fieldEditor()
            try await f.settle { f.titles().count > 0 }
            try await f.settle(iterations: 25)
            try f.capture(directory + "/switcher-recent-\(name).png")
            editor.insertText("so", replacementRange: editor.selectedRange())
            try await f.settle { f.titles().contains("Sophie Turner") }
            f.key(125, "\u{F701}")
            try await f.settle(iterations: 25)
            try f.capture(directory + "/switcher-query-\(name).png")
            editor.selectAll(nil)
            editor.insertText("qqq", replacementRange: editor.selectedRange())
            try await f.settle { f.probe.model?.hasQuery == true && f.titles().isEmpty }
            try await f.settle(iterations: 25)
            try f.capture(directory + "/switcher-empty-\(name).png")
            f.model.isQuickSwitcherVisible = false
            try await f.settle(iterations: 15)
        }
    }

    // MARK: Fixture

    @MainActor private final class Fixture {
        let service: FakeMattermostService
        let app: AppModel
        let model: SessionViewModel
        let window: NSWindow
        let probe = QuickSwitcherProbe()

        init(onScreen: Bool) async throws {
            _ = NSApplication.shared
            let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
            service.withState { state in
                let me = SwitcherData.me
                state.teams = [SwitcherData.northwind, SwitcherData.studio]
                state.preferences = [Preference(category: "display_settings", name: "name_format", value: "full_name")]
                func add(_ channel: Channel, viewed: Int64, total: Int64 = 0, mentions: Int64 = 0, muted: Bool = false) {
                    var channel = channel
                    channel.totalMessageCount = total
                    channel.totalMessageCountRoot = total
                    channel.lastPostAt = MattermostTimestamp(milliseconds: 1_700_000_000_000 + viewed)
                    state.channels[channel.id] = channel
                    state.memberships[channel.id] = ChannelMembership(
                        channelID: channel.id, userID: me, lastViewedAt: MattermostTimestamp(milliseconds: viewed),
                        mentionCount: mentions, mentionCountRoot: mentions, markUnread: muted ? .mention : .all)
                }
                func channel(_ n: Int, _ name: String, _ type: ChannelType = .open, team: Team = SwitcherData.northwind,
                             archived: Bool = false) -> Channel {
                    Channel(id: ChannelID(unchecked: CoreFixtures.id("ch", n)), teamID: team.id, type: type,
                            name: name.lowercased().replacingOccurrences(of: " ", with: "-"), displayName: name,
                            deleteAt: MattermostTimestamp(milliseconds: archived ? 1 : 0))
                }
                add(channel(1, "Town Square"), viewed: 990)
                add(channel(2, "Design Reviews"), viewed: 400, total: 6, mentions: 3)
                add(channel(3, "Release Planning", .private), viewed: 300, total: 2)
                add(channel(4, "Customer Support"), viewed: 700)
                add(channel(5, "iOS Engineering", .private), viewed: 650)
                add(channel(6, "Off-Topic"), viewed: 200)
                add(channel(7, "Announcements"), viewed: 100, total: 3, muted: true)
                add(channel(8, "Brand Refresh", team: SwitcherData.studio), viewed: 600)
                add(channel(9, "Marketing Launch", archived: true), viewed: 980)
                for (index, user) in [SwitcherData.olivia, SwitcherData.marcus, SwitcherData.priya, SwitcherData.liam, SwitcherData.sofia, SwitcherData.noah, SwitcherData.emma]
                    .enumerated() {
                    state.users[user.id] = user
                    let dm = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", index + 1)), teamID: nil, type: .direct,
                                     name: [me.rawValue, user.id.rawValue].sorted().joined(separator: "__"), displayName: "")
                    let viewed: Int64 = [500, 880, 820, 150, 760, 90, 60][index]
                    add(dm, viewed: viewed, total: index == 0 ? 2 : 0, mentions: index == 0 ? 2 : 0)
                }
                state.users[SwitcherData.sophie.id] = SwitcherData.sophie
                add(SwitcherData.group, viewed: 860)
                add(SwitcherData.largeGroup, viewed: 870)
                state.statuses = [SwitcherData.olivia.id: .online, SwitcherData.marcus.id: .away, SwitcherData.priya.id: .doNotDisturb,
                                  SwitcherData.liam.id: .offline, SwitcherData.sofia.id: .online, SwitcherData.noah.id: .online,
                                  SwitcherData.emma.id: .away, SwitcherData.sophie.id: .online]
                state.imageHandler = { resource, _ in
                    guard case .profileImage(let user, let revision) = resource, revision > 0 else {
                        throw CancellationError()
                    }
                    return SwitcherData.avatar(seed: user.rawValue.utf8.reduce(7) { $0 &* 31 &+ Int($1) })
                }
            }
            self.service = service
            app = AppModel(environment: AppEnvironment(serviceFactory: Factory(fake: service),
                makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) }))
            let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
                login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
                capabilities: ServerCapabilities())
            model = SessionViewModel(slot: slot, app: app)
            await slot.session.start()
            let origin = onScreen ? NSPoint(x: 80, y: 80) : NSPoint(x: -30_000, y: -30_000)
            window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 1100, height: 720)),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentViewController = NSHostingController(rootView: MainWindowView(app: app, session: model)
                .environment(\.quickSwitcherProbe, probe)
                .frame(minWidth: 760, minHeight: 500))
            window.setContentSize(NSSize(width: 1100, height: 720))
            if onScreen {
                _ = NSApp.setActivationPolicy(.regular)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } else {
                window.orderFrontRegardless()
            }
            let townSquare = ChannelID(unchecked: CoreFixtures.id("ch", 1))
            try await settle { self.model.sidebar?.sections.contains { $0.rows.contains { $0.channelID == townSquare } } == true }
            model.select(channel: townSquare)
            try await settle { self.model.header?.channelID == townSquare }
            try #require(model.header?.channelID == townSquare)
            try await settle(iterations: 20)
        }

        func close() {
            window.close()
            model.prepareForSignOut()
        }

        func settle(iterations: Int = 150, until condition: () -> Bool = { false }) async throws {
            for _ in 0..<iterations {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// The palette field's editor, once the field has focus.
        func fieldEditor() async throws -> NSTextView {
            func editor() -> NSTextView? {
                guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                      (editor.delegate as? NSTextField)?.placeholderString == "Switch to a channel or person…"
                else { return nil }
                return editor
            }
            try await settle { editor() != nil && probe.model?.hasLoaded == true }
            return try #require(editor())
        }

        /// Result titles of the palette on screen, in order.
        func titles() -> [String] { probe.model?.results.map(\.title) ?? [] }

        func selectedTitle() -> String? {
            guard let palette = probe.model else { return nil }
            return palette.results.first { $0.kind == palette.selection }?.title
        }

        func key(_ code: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code) else { continue }
                window.sendEvent(event)
            }
        }

        /// Captures only this window.
        func capture(_ path: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

    }

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }
}

/// Synthetic fixture people and conversations (English names, no real data).
private enum SwitcherData {
    static let me = CoreFixtures.me.id
    static let northwind = CoreFixtures.team
    static let studio = Team(id: TeamID(unchecked: CoreFixtures.id("team", 2)), name: "studio", displayName: "Studio")

    static func user(_ n: Int, _ username: String, _ first: String, _ last: String, picture: Bool = false) -> User {
        User(id: UserID(unchecked: CoreFixtures.id("u", n)), username: username, firstName: first, lastName: last,
             lastPictureUpdate: MattermostTimestamp(milliseconds: picture ? Int64(n) : 0))
    }
    static let olivia = user(1, "olivia", "Olivia", "Bennett", picture: true)
    static let marcus = user(2, "marcus", "Marcus", "Chen")
    static let priya = user(3, "priya", "Priya", "Raman", picture: true)
    static let liam = user(4, "liam", "Liam", "Walker")
    static let sofia = user(5, "sofia", "Sofia", "Martinez", picture: true)
    static let noah = user(6, "noah", "Noah", "Kim")
    static let emma = user(7, "emma", "Emma", "Thompson")
    static let sophie = user(8, "sophie", "Sophie", "Turner")
    static let largeGroup = Channel(id: ChannelID(unchecked: CoreFixtures.id("gm", 2)), teamID: nil, type: .group,
                                    name: "gm-large-fixture",
                                    displayName: "alice, olivia, marcus, priya, liam, noah, emma")
    static let group = Channel(id: ChannelID(unchecked: CoreFixtures.id("gm", 1)), teamID: nil, type: .group,
                               name: "gm-fixture", displayName: "alice, noah, sofia, emma")

    /// A soft two-colour gradient standing in for a profile photo.
    static func avatar(seed: Int) -> Data {
        let size = 96
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = CGFloat((seed % 360 + 360) % 360) / 360
        let top = NSColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7,
                             brightness: 0.6, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
        context.setFillColor(NSColor(white: 1, alpha: 0.55).cgColor)
        context.fillEllipse(in: CGRect(x: 30, y: 44, width: 36, height: 36))
        context.fillEllipse(in: CGRect(x: 14, y: -30, width: 68, height: 64))
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return bytes as Data
    }
}
