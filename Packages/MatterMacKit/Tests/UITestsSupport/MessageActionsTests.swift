import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Message actions, hover bar and link previews", .serialized)
struct MessageActionsTests {
    final class Spy: TimelineViewControllerDelegate {
        var actions: [TimelineAction] = []
        var requested: [TimelineImageRequest] = []
        var reports: [(last: PostID?, scrolled: Bool)] = []
        func timelineRequestsOlder() {}
        func timelineRequestsNewer() {}
        func timelineVisibleRangeDidChange(first: PostID?, last: PostID?, isAtLiveEdge: Bool) {
            reports.append((last, false))
        }
        func timelineVisibleRangeDidChange(first: PostID?, last: PostID?, isAtLiveEdge: Bool, userScrolled: Bool) {
            reports.append((last, userScrolled))
        }
        func timeline(perform action: TimelineAction) { actions.append(action) }
        func timelineImage(for request: TimelineImageRequest) -> NSImage? { nil }
        func timelineNeedsImage(_ request: TimelineImageRequest) { requested.append(request) }
    }

    struct Fixture {
        let controller: TimelineViewController
        let window: NSWindow
        let spy: Spy
        let posts: [Post]
        @MainActor func close() { controller.removeAllContent(); window.close() }
    }

    static let actions = PostActionHints(canReply: true, canReact: true, canEdit: true, canDelete: true, canCopyLink: true,
                                         canPin: true, canSave: true, canMarkUnread: true)

    func presentation(_ post: Post, continuation: Bool = false, pinned: Bool = false, saved: Bool = false,
                      edited: Bool = false, reactions: [ReactionGroup] = [], preview: LinkPreview? = nil,
                      actions: PostActionHints = Self.actions) -> PostPresentation {
        PostPresentation(
            postID: post.id, pendingID: nil, channelID: post.channelID, rootID: nil,
            author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob", isBot: false,
                                       isCurrentUser: false, avatarRevision: 0),
            createdAt: post.createAt, isContinuation: continuation, body: .document(MarkupParser.parse(post.message),
                                                                                  isCollapsed: false),
            isEdited: edited, isPinned: pinned, files: [], reactions: reactions, replyCount: 0, showsThreadContext: false,
            sendState: nil, actions: actions,
            permalink: CoreFixtures.endpoint.url(path: ["qa", "pl", post.id.rawValue]), isSaved: saved,
            editedAt: edited ? MattermostTimestamp(milliseconds: post.createAt.milliseconds + 60_000) : nil,
            linkPreview: preview)
    }

    func makeTimeline(_ rows: [PostPresentation], height: CGFloat = 480) -> Fixture {
        let c = TimelineViewController()
        let spy = Spy()
        c.delegate = spy
        c.visibilityOverrideForTesting = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        c.emojiLookup = { EmojiCatalog.system.glyph(for: $0) }
        let items = rows.enumerated().map { index, post in
            TimelineItem(id: TimelineItemID(.post(post.postID!)), revision: UInt64(index + 1), content: .post(post))
        }
        c.apply(TimelineSnapshot(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
                                 target: .channel(CoreFixtures.channel(1).id), generation: 1, items: items,
                                 isAtLiveEdge: true, isStale: false, scrollRequest: nil))
        window.contentView?.layoutSubtreeIfNeeded()
        return Fixture(controller: c, window: window, spy: spy, posts: [])
    }

    func post(_ n: Int, _ message: String = "hello") -> Post {
        CoreFixtures.post(n, channel: CoreFixtures.channel(1).id, message: message)
    }

    func cell(_ f: Fixture, row: Int = 0) throws -> MessageCellView {
        try #require(f.controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? MessageCellView)
    }

    func hover(_ f: Fixture, row: Int) throws {
        let rect = f.controller.tableView.rect(ofRow: row)
        let point = f.controller.tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: f.window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 0, pressure: 0))
        f.controller.hoverMouseMoved(event)
    }

    @Test func hoverBarAppearsTopRightWithoutChangingRowHeights() throws {
        let posts = [post(1), post(2), post(3)]
        let f = makeTimeline(posts.map { presentation($0) })
        defer { f.close() }
        let bar = f.controller.hoverBar
        #expect(bar.isHidden)
        let heights = (0..<3).map { f.controller.tableView.rect(ofRow: $0).height }
        try hover(f, row: 1)
        #expect(!bar.isHidden)
        #expect(bar.postID == posts[1].id)
        #expect(bar.buttons.map(\.kind) == [.quickReaction("+1"), .quickReaction("white_check_mark"),
                                            .quickReaction("heart"), .addReaction, .reply, .more])
        let rowRect = f.controller.view.convert(f.controller.tableView.rect(ofRow: 1), from: f.controller.tableView)
        #expect(bar.frame.maxX <= rowRect.maxX && bar.frame.maxX >= rowRect.maxX - 40, "right-aligned in the row")
        #expect(bar.frame.intersects(rowRect))
        #expect(abs(bar.frame.midY - rowRect.maxY) < HoverActionBar.height, "straddles the row's top edge")
        #expect((0..<3).map { f.controller.tableView.rect(ofRow: $0).height } == heights)
        let rowView = try #require(f.controller.tableView.rowView(atRow: 1, makeIfNecessary: false) as? TimelineRowView)
        #expect(rowView.isHovered)
        if #available(macOS 26, *) {
            #expect(bar.subviews.contains { $0 is NSGlassEffectView }, "Liquid Glass on macOS 26+")
        } else {
            #expect(bar.subviews.contains { $0 is NSVisualEffectView })
        }
        // Buttons are real, accessible controls.
        for (_, button) in bar.buttons {
            #expect(button.accessibilityLabel()?.isEmpty == false)
            #expect(button.toolTip?.isEmpty == false)
        }
        try hover(f, row: 2)
        #expect(bar.postID == posts[2].id)
        #expect(!rowView.isHovered)
        f.controller.hoverMouseExited()
        #expect(bar.isHidden)
    }

    @Test func hoverBarButtonsPerformActions() throws {
        let posts = [post(1)]
        let f = makeTimeline(posts.map { presentation($0) })
        defer { f.close() }
        try hover(f, row: 0)
        let bar = f.controller.hoverBar
        let id = posts[0].id
        try #require(bar.button(.quickReaction("+1"))).performClick(nil)
        try #require(bar.button(.quickReaction("heart"))).performClick(nil)
        try #require(bar.button(.addReaction)).performClick(nil)
        try #require(bar.button(.reply)).performClick(nil)
        #expect(f.spy.actions == [.toggleReaction(id, emojiName: "+1"), .toggleReaction(id, emojiName: "heart"),
                                  .addReaction(id), .reply(id)])
        // "More" offers exactly the context-menu items.
        let more = try #require(f.controller.moreMenu(for: id))
        let context = NSMenu()
        f.controller.populate(context, row: 0)
        #expect(more.items.map(\.title) == context.items.map(\.title))
        #expect(more.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Reply in Thread", "Add Reaction…", "Mark as Unread", "Save Message", "Pin to Channel", "Copy Link",
            "Copy Text", "Edit Message", "Delete Message…", "View Profile of Bob",
        ])
        let pin = try #require(more.items.first { $0.title == "Pin to Channel" })
        _ = (pin.target as? NSObject)?.perform(pin.action, with: pin)
        #expect(f.spy.actions.last == .setPinned(id, true))
        let unread = try #require(more.items.first { $0.title == "Mark as Unread" })
        _ = (unread.target as? NSObject)?.perform(unread.action, with: unread)
        #expect(f.spy.actions.last == .markUnread(id))
    }

    @Test func pinnedAndSavedPostsOfferTheReverseActionsAndShowIndicators() throws {
        let p = post(1)
        let f = makeTimeline([presentation(p, pinned: true, saved: true)])
        defer { f.close() }
        let menu = NSMenu()
        f.controller.populate(menu, row: 0)
        #expect(menu.items.contains { $0.title == "Unpin from Channel" })
        #expect(menu.items.contains { $0.title == "Remove from Saved" })
        let cell = try cell(f)
        let meta = cell.metaLabel.attributedText.string
        #expect(meta.contains(TimelineStrings.pinned) && meta.contains(TimelineStrings.saved))
        #expect(cell.metaLabel.toolTip == TimelineStrings.longDateTime(p.createAt))
        #expect(cell.accessibilitySummary?.contains(TimelineStrings.saved) == true)
    }

    @Test func rowsExposeEveryActionToAccessibility() throws {
        let p = post(1)
        let f = makeTimeline([presentation(p)])
        defer { f.close() }
        let actions = try #require(try cell(f).accessibilityCustomActions())
        #expect(actions.map(\.name) == [
            "React with :+1:", "React with :white_check_mark:", "React with :heart:", "Reply in Thread", "Add Reaction…",
            "Mark as Unread", "Save Message", "Pin to Channel", "Copy Link", "Copy Text", "Edit Message",
            "Delete Message…", "View Profile of Bob",
        ])
        let save = try #require(actions.first { $0.name == "Save Message" })
        #expect(save.handler?() == true)
        #expect(f.spy.actions == [.setSaved(p.id, true)])
        let react = try #require(actions.first)
        #expect(react.handler?() == true)
        #expect(f.spy.actions.last == .toggleReaction(p.id, emojiName: "+1"))
        // A read-only post offers only what is allowed.
        let g = makeTimeline([presentation(post(2), actions: PostActionHints(canCopyLink: true))])
        defer { g.close() }
        #expect(try cell(g).accessibilityCustomActions()?.map(\.name) == ["Copy Link", "Copy Text", "View Profile of Bob"])
        try hover(g, row: 0)
        #expect(g.controller.hoverBar.buttons.map(\.kind) == [.more], "no reactions or reply without permission")
    }

    @Test func selectedRowShowsTheBarWhenThePointerIsElsewhere() throws {
        let posts = [post(1), post(2)]
        let f = makeTimeline(posts.map { presentation($0) })
        defer { f.close() }
        f.controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(!f.controller.hoverBar.isHidden)
        #expect(f.controller.hoverBar.postID == posts[0].id)
        try hover(f, row: 1)
        #expect(f.controller.hoverBar.postID == posts[1].id, "the pointer wins over the selection")
        f.controller.hoverMouseExited()
        #expect(f.controller.hoverBar.postID == posts[0].id)
        f.controller.tableView.deselectAll(nil)
        #expect(f.controller.hoverBar.isHidden)
    }

    @Test func editedMarkerFollowsTextAndContinuationRowsShowTimeOnHover() throws {
        let first = post(1, "first")
        let second = post(2, "second line")
        let f = makeTimeline([presentation(first), presentation(second, continuation: true, edited: true)])
        defer { f.close() }
        let cell = try cell(f, row: 1)
        #expect(cell.displayedBodyText == "second line " + TimelineStrings.edited)
        #expect(!cell.metaLabel.attributedText.string.contains(TimelineStrings.edited))
        #expect(!cell.isHoverHighlighted)
        try hover(f, row: 1)
        #expect(cell.isHoverHighlighted)
        let label = try #require(cell.subviews.compactMap { $0 as? TimelineLabel }.first {
            !$0.isHidden && $0.attributedText.string == TimelineStrings.time(second.createAt)
        })
        #expect(label.frame.maxX <= TimelineRowMetrics.contentLeading, "in the avatar gutter")
        #expect(label.toolTip?.contains(TimelineStrings.editedAt(MattermostTimestamp(
            milliseconds: second.createAt.milliseconds + 60_000))) == true)
        f.controller.hoverMouseExited()
        #expect(label.isHidden)
    }

    @Test func reactionChipsNameWhoReacted() throws {
        let reactions = [ReactionGroup(emojiName: "+1", count: 5, includesCurrentUser: true, reactorNames: ["You", "Bob"]),
                         ReactionGroup(emojiName: "tada", count: 2, includesCurrentUser: false, reactorNames: ["Bob", "Carol"]),
                         ReactionGroup(emojiName: "heart", count: 2, includesCurrentUser: false, reactorNames: ["Bob"])]
        let f = makeTimeline([presentation(post(1), reactions: reactions)])
        defer { f.close() }
        let chips = try cell(f).subviews.compactMap { $0 as? ReactionChipView }.filter { !$0.isHidden }
        #expect(chips.map(\.toolTip) == ["You, Bob and 3 others reacted with :+1:", "Bob and Carol reacted with :tada:",
                                         "Bob and 1 other reacted with :heart:"])
        #expect(chips[0].accessibilityHelp() == chips[0].toolTip)
    }

    @Test func websitePreviewCardRendersBelowTheTextAndOpensTheLink() throws {
        let link = SafeLink("https://example.com/article")!
        let preview = LinkPreview(kind: .website, link: link, title: "An article with a long enough title to wrap maybe",
                                  description: String(repeating: "Description text. ", count: 20), siteName: "Example",
                                  image: LinkPreview.Image(url: "https://example.com/a.png", width: 1_200, height: 630))
        let p = post(1, "see https://example.com/article")
        let f = makeTimeline([presentation(p, preview: preview)])
        defer { f.close() }
        let cell = try cell(f)
        let card = try #require(cell.subviews.compactMap { $0 as? LinkPreviewCardView }.first { !$0.isHidden })
        #expect(card.displayedSite == "Example")
        #expect(card.displayedTitle == preview.title)
        #expect(card.frame.minY > cell.bodyTextView.frame.maxY, "below the message text")
        #expect(card.frame.maxY <= cell.bounds.maxY)
        #expect(card.frame.width <= TimelineRowMetrics.linkPreviewMaximumWidth)
        let layout = f.controller.rowMetrics.linkPreviewLayout(preview, origin: .zero, contentWidth: 500, exact: true)
        #expect(try #require(layout.description).height <= 3 * f.controller.rowMetrics.fonts.metaLineHeight)
        #expect(try #require(layout.title).height <= 2 * f.controller.rowMetrics.fonts.bodyLineHeight)
        #expect(layout.image?.width == TimelineMetrics.linkPreviewThumbnailSize)
        #expect(f.spy.requested.contains(.linkPreview(url: "https://example.com/a.png")))
        #expect(card.accessibilityLabel() == TimelineStrings.linkPreviewAccessibility(preview))
        #expect(card.accessibilityPerformPress())
        #expect(f.spy.actions == [.openLink(link)])
    }

    @Test func textOnlyAndImagePreviewsNeverRequestUnproxiedImages() throws {
        let link = SafeLink("https://example.com/cat.jpg")!
        let proxied = LinkPreview(kind: .image, link: link, image: LinkPreview.Image(url: link.url.absoluteString,
                                                                                     width: 800, height: 600))
        let textOnly = LinkPreview(kind: .website, link: SafeLink("https://example.org")!, title: "Example")
        let f = makeTimeline([presentation(post(1), preview: proxied), presentation(post(2), preview: textOnly)])
        defer { f.close() }
        let imageCard = try #require(try cell(f, row: 0).subviews.compactMap { $0 as? LinkPreviewCardView }.first)
        #expect(imageCard.frame.size == CGSize(width: 320, height: 240), "fits the thumbnail box from metadata")
        let textCard = try #require(try cell(f, row: 1).subviews.compactMap { $0 as? LinkPreviewCardView }.first)
        #expect(textCard.frame.height < 80)
        #expect(f.spy.requested.filter { if case .linkPreview = $0 { true } else { false } }
                == [.linkPreview(url: link.url.absoluteString)])
    }

    /// Development review only: with `MM_SNAPSHOT_DIR` set, captures this test's own
    /// window (never the rest of the screen) in light and dark appearance.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] != nil),
          arguments: [NSAppearance.Name.aqua, .darkAqua])
    func snapshotForReview(appearance: NSAppearance.Name) async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"])
        let preview = LinkPreview(kind: .website, link: SafeLink("https://mattermost.com")!,
                                  title: "Mattermost | Secure collaboration for technical and operational teams",
                                  description: "Mattermost is an open core, self-hosted collaboration platform that offers chat, "
                                      + "workflow automation, voice calling, screen sharing, and AI integration.",
                                  siteName: "Mattermost")
        let reactions = [ReactionGroup(emojiName: "+1", count: 3, includesCurrentUser: true, reactorNames: ["You", "Bob"]),
                         ReactionGroup(emojiName: "heart", count: 1, includesCurrentUser: false, reactorNames: ["Carol"])]
        let rows = [
            presentation(post(1, "Has anyone looked at the release checklist?"), pinned: true),
            presentation(post(2, "Yes — see https://mattermost.com for the overview."), continuation: true, edited: true,
                         preview: preview),
            presentation(post(3, "Great, thanks! Saving this one."), saved: true, reactions: reactions),
        ]
        let f = makeTimeline(rows, height: 520)
        defer { f.close() }
        f.window.appearance = NSAppearance(named: appearance)
        f.window.setFrameOrigin(NSPoint(x: 80, y: 80))
        f.window.orderFrontRegardless()
        f.window.contentView?.layoutSubtreeIfNeeded()
        try hover(f, row: 1)
        f.window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        f.window.displayIfNeeded()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(f.window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent("message-actions-\(appearance.rawValue).png").path]
        try process.run()
        process.waitUntilExit()
        f.window.orderOut(nil)
    }

    @Test func userScrollsAreReportedSeparatelyFromContentUpdates() async throws {
        let posts = (1...40).map { post($0, "message \($0) " + String(repeating: "text ", count: 20)) }
        let f = makeTimeline(posts.map { presentation($0) }, height: 300)
        defer { f.close() }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(f.spy.reports.allSatisfy { !$0.scrolled }, "applying a snapshot is not a user scroll")
        let clip = f.controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - 400)))
        f.controller.scrollView.reflectScrolledClipView(clip)
        let deadline = ContinuousClock.now + .seconds(2)
        while !(f.spy.reports.last?.scrolled ?? false), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.spy.reports.last?.scrolled == true)
    }
}
