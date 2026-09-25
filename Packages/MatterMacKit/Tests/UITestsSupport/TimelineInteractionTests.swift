import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Timeline interaction", .serialized)
struct TimelineInteractionTests {
    final class Spy: TimelineViewControllerDelegate {
        var actions: [TimelineAction] = []
        func timelineRequestsOlder() {}
        func timelineRequestsNewer() {}
        func timelineVisibleRangeDidChange(first: PostID?, last: PostID?, isAtLiveEdge: Bool) {}
        func timeline(perform action: TimelineAction) { actions.append(action) }
        func timelineImage(for request: TimelineImageRequest) -> NSImage? { nil }
        var requested: [TimelineImageRequest] = []
        func timelineNeedsImage(_ request: TimelineImageRequest) { requested.append(request) }
    }

    @MainActor struct Fixture {
        let controller: TimelineViewController
        let window: NSWindow
        let spy: Spy
        func close() { controller.removeAllContent(); window.close() }
    }

    func makeTimeline(text: String, files: [FileInfo] = [], reactions: [ReactionGroup] = [],
                      appearance: NSAppearance.Name = .aqua) -> Fixture {
        let c = TimelineViewController()
        let spy = Spy()
        c.delegate = spy
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = c
        c.emojiLookup = { EmojiCatalog.system.glyph(for: $0) }
        let post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        let item = TimelineItem(id: TimelineItemID(.post(post.id)), revision: 1, content: .post(
            PostPresentation(postID: post.id, pendingID: nil, channelID: post.channelID, rootID: nil,
                author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob",
                                           isBot: false, isCurrentUser: false, avatarRevision: 0),
                createdAt: post.createAt, isContinuation: false,
                body: .document(MarkupParser.parse(text), isCollapsed: false), isEdited: false,
                isPinned: false, files: files, reactions: reactions, replyCount: 0, showsThreadContext: false,
                sendState: nil, actions: .none, permalink: nil)))
        c.apply(TimelineSnapshot(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
                                 target: .channel(CoreFixtures.channel(1).id), generation: 1,
                                 items: [item], isAtLiveEdge: true, isStale: false, scrollRequest: nil))
        window.contentView?.layoutSubtreeIfNeeded()
        return Fixture(controller: c, window: window, spy: spy)
    }

    func cell(_ f: Fixture) throws -> MessageCellView {
        try #require(f.controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? MessageCellView)
    }

    /// The view AppKit would deliver a click at `point` (in `view` coordinates) to.
    /// (Posting synthetic events to the queue is avoided: it disturbs the test runner.)
    func hitView(_ view: NSView, at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let root = window.contentView?.superview else { return nil }
        return root.hitTest(root.convert(view.convert(point, to: nil), from: nil))
    }

    func render(_ view: NSView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @Test func clickingALinkOpensItThroughTheDelegate() throws {
        let f = makeTimeline(text: "see https://example.com/page now")
        defer { f.close() }
        let cell = try cell(f)
        let text = cell.bodyTextView
        #expect(cell.frame.width == f.controller.tableView.bounds.width, "the cell spans the table")
        let range = (text.string as NSString).range(of: "example")
        let glyphs = text.layoutManager!.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = text.layoutManager!.boundingRect(forGlyphRange: glyphs, in: text.textContainer!)
        let point = NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y)
        #expect(hitView(text, at: point, in: f.window) === text, "the click reaches the text view, not the row")
        // Link cursor rects are only established inside the visible rect.
        #expect(text.visibleRect.contains(rect.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)))
        let url = try #require(text.link(at: point))
        text.clicked(onLink: url, at: range.location)
        #expect(f.spy.actions == [.openLink(SafeLink("https://example.com/page")!)])
    }

    @Test func clickingAnImageThumbnailPreviewsAndSavingStaysAvailable() throws {
        let image = FileInfo(id: FileID(unchecked: "imagexzzzzzzzzzzzzzzzzzzz"), name: "photo.jpg", fileExtension: "jpg",
                             size: 90_000, mimeType: "image/jpeg", width: 1_600, height: 1_200, hasPreviewImage: true)
        let icon = FileInfo(id: FileID(unchecked: "iconxzzzzzzzzzzzzzzzzzzzz"), name: "icon.gif", fileExtension: "gif",
                            size: 900, mimeType: "image/gif", width: 32, height: 32, hasPreviewImage: false)
        let f = makeTimeline(text: "look", files: [image, icon])
        defer { f.close() }
        let cell = try cell(f)
        // Sharp thumbnails come from the preview rendition when the server has one.
        #expect(f.spy.requested.contains(.preview(image.id)))
        #expect(f.spy.requested.contains(.thumbnail(icon.id)))
        let thumbnail = try #require(cell.subviews.compactMap { $0 as? ImageThumbnailView }.first { !$0.isHidden })
        let center = NSPoint(x: thumbnail.bounds.midX, y: thumbnail.bounds.midY)
        #expect(hitView(thumbnail, at: center, in: f.window) === thumbnail)
        let location = thumbnail.convert(center, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                        windowNumber: f.window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            if type == .leftMouseDown { thumbnail.mouseDown(with: event) } else { thumbnail.mouseUp(with: event) }
        }
        #expect(f.spy.actions == [.previewImage(image)])
        #expect(thumbnail.accessibilityPerformPress())
        #expect(f.spy.actions.last == .previewImage(image))
        // Saving: context menu (before the row's own items) and an accessibility action.
        let menuEvent = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                                        timestamp: 0, windowNumber: f.window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(thumbnail.menu(for: menuEvent))
        #expect(menu.items.prefix(2).map(\.title) == [TimelineStrings.openImage, TimelineStrings.saveAttachment])
        #expect(menu.items.contains { $0.title.hasPrefix("View Profile") }, "row items follow")
        let save = menu.items[1]
        _ = (save.target as? NSObject)?.perform(save.action, with: save)
        #expect(f.spy.actions.last == .openFile(image))
        #expect(thumbnail.accessibilityCustomActions()?.map(\.name) == [TimelineStrings.saveAttachment])
        // Space on the selected row previews its first image.
        f.controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: f.window.windowNumber, context: nil, characters: " ",
                                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        let count = f.spy.actions.count
        f.controller.tableView.keyDown(with: space)
        #expect(f.spy.actions.count == count + 1 && f.spy.actions.last == .previewImage(image))
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func reactionEmojiInkIsCenteredInsideItsPill(appearance: NSAppearance.Name) throws {
        let f = makeTimeline(text: "Reaction alignment", reactions: [
            ReactionGroup(emojiName: "heart", count: 1, includesCurrentUser: false),
        ], appearance: appearance)
        defer { f.close() }
        let chip = try #require(try cell(f).subviews.compactMap { $0 as? ReactionChipView }.first)
        let root = f.controller.view
        let rep = render(root)
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        var inkY: [CGFloat] = []
        // Inspect the actual red emoji pixels, including the area above/below the
        // pill: baseline-origin drawing can otherwise look like valid chip geometry.
        for y in stride(from: -30.0, through: chip.bounds.height + 30, by: 0.5) {
            for x in stride(from: 0.0, through: chip.bounds.width, by: 0.5) {
                let point = root.convert(NSPoint(x: x, y: y), from: chip)
                guard root.bounds.contains(point),
                      let color = rep.colorAt(x: Int(point.x * scale), y: Int((root.isFlipped ? point.y : root.bounds.height - point.y) * scale))?.usingColorSpace(.sRGB)
                else { continue }
                if color.redComponent > 0.5, color.redComponent - color.greenComponent > 0.25,
                   color.redComponent - color.blueComponent > 0.2 { inkY.append(y) }
            }
        }
        let top = try #require(inkY.min()), bottom = try #require(inkY.max())
        #expect(top >= 0)
        #expect(bottom <= chip.bounds.height)
        #expect(abs((top + bottom) / 2 - chip.bounds.midY) <= 3)
    }

    /// Relative luminance of the rendered pixel at `point` in `view` coordinates.
    func luminance(_ rep: NSBitmapImageRep, of root: NSView, at point: NSPoint, in view: NSView) -> CGFloat {
        let p = root.convert(point, from: view)
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        let y = root.isFlipped ? p.y : root.bounds.height - p.y
        let color = rep.colorAt(x: Int(p.x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func reactionChipsAreLegibleAndFitTheirContent(appearance: NSAppearance.Name) throws {
        let reactions = [ReactionGroup(emojiName: "+1", count: 2, includesCurrentUser: true),
                         ReactionGroup(emojiName: "tada", count: 13, includesCurrentUser: false),
                         ReactionGroup(emojiName: "party_parrot", count: 1, includesCurrentUser: false)]
        let f = makeTimeline(text: "hi", reactions: reactions, appearance: appearance)
        defer { f.close() }
        let cell = try cell(f)
        let chips = cell.subviews.compactMap { $0 as? ReactionChipView }.filter { !$0.isHidden }
        try #require(chips.count == 3)
        let fonts = f.controller.rowMetrics.fonts
        let isDark = appearance != .aqua
        let rep = render(f.controller.view)
        let background = luminance(rep, of: f.controller.view, at: NSPoint(x: cell.bounds.maxX - 4, y: 4), in: cell)
        for chip in chips {
            let metrics = try #require(chip.metrics)
            // Layout reserved exactly the measured width; the emoji's ink fits inside it.
            #expect(chip.frame.width == metrics.width)
            #expect(chip.frame.height >= fonts.emojiLineHeight)
            #expect(ReactionChipMetrics.horizontalPadding + metrics.emojiWidth + ReactionChipMetrics.spacing
                    + metrics.countWidth <= chip.bounds.width - ReactionChipMetrics.horizontalPadding + 0.5)
            #expect(hitView(chip, at: NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), in: f.window) === chip)
            // The pill stays a subtle tint of the timeline background, never an opaque label-color pill.
            let fill = luminance(rep, of: f.controller.view, at: NSPoint(x: chip.bounds.maxX - 4, y: chip.bounds.midY),
                                 in: chip)
            #expect(abs(fill - background) < 0.3, "chip fill \(fill) vs background \(background)")
            #expect(isDark ? fill < 0.45 : fill > 0.6)
            // The count text contrasts with the fill.
            let countX = ReactionChipMetrics.horizontalPadding + metrics.emojiWidth + ReactionChipMetrics.spacing
            var contrast: CGFloat = 0
            for dx in stride(from: countX, to: countX + metrics.countWidth, by: 0.5) {
                for dy in stride(from: chip.bounds.midY - 4, through: chip.bounds.midY + 4, by: 0.5) {
                    let value = luminance(rep, of: f.controller.view, at: NSPoint(x: dx, y: dy), in: chip)
                    contrast = max(contrast, abs(value - fill))
                }
            }
            #expect(contrast > 0.3, "count contrast \(contrast) \(chip.countText)")
        }
        #expect(chips.map(\.isSelectedByCurrentUser) == [true, false, false])
    }
}
