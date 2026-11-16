import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Reply line, thread summary and inline reply actions", .serialized)
struct ReplyContextViewTests {
    final class Spy: TimelineViewControllerDelegate {
        var actions: [TimelineAction] = []
        func timelineRequestsOlder() {}
        func timelineRequestsNewer() {}
        func timelineVisibleRangeDidChange(first: PostID?, last: PostID?, isAtLiveEdge: Bool) {}
        func timeline(perform action: TimelineAction) { actions.append(action) }
        func timelineImage(for request: TimelineImageRequest) -> NSImage? { nil }
        func timelineNeedsImage(_ request: TimelineImageRequest) {}
    }

    static let bob = AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob", isBot: false,
                                        isCurrentUser: false, avatarRevision: 0)
    static let actions = PostActionHints(canReply: true, canReact: true, canCopyLink: true)

    let rootID = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id).id

    func presentation(_ n: Int, rootID: PostID? = nil, replyCount: Int = 0, context: ReplyContextPresentation? = nil)
        -> PostPresentation {
        let post = CoreFixtures.post(n, channel: CoreFixtures.channel(1).id)
        var presentation = PostPresentation(
            postID: post.id, pendingID: nil, channelID: post.channelID, rootID: rootID, author: Self.bob,
            createdAt: post.createAt, isContinuation: false,
            body: .document(MarkupParser.parse(post.message), isCollapsed: false), isEdited: false, isPinned: false,
            files: [], reactions: [], replyCount: replyCount, showsThreadContext: context != nil, sendState: nil,
            actions: Self.actions, permalink: CoreFixtures.endpoint.url(path: ["qa", "pl", post.id.rawValue]))
        presentation.replyContext = context
        if replyCount > 0 { presentation.lastReplyAt = MattermostTimestamp(milliseconds: post.createAt.milliseconds + 60_000) }
        return presentation
    }

    func makeTimeline(_ rows: [PostPresentation], inline: Bool) -> (TimelineViewController, NSWindow, Spy) {
        let c = TimelineViewController()
        let spy = Spy()
        c.delegate = spy
        c.visibilityOverrideForTesting = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        let items = rows.enumerated().map { index, post in
            TimelineItem(id: TimelineItemID(.post(post.postID!)), revision: UInt64(index + 1), content: .post(post))
        }
        var snapshot = TimelineSnapshot(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
                                        target: .channel(CoreFixtures.channel(1).id), generation: 1, items: items,
                                        isAtLiveEdge: true, isStale: false, scrollRequest: nil)
        snapshot.showsRepliesInline = inline
        c.apply(snapshot)
        window.contentView?.layoutSubtreeIfNeeded()
        return (c, window, spy)
    }

    func cell(_ c: TimelineViewController, row: Int) throws -> MessageCellView {
        try #require(c.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? MessageCellView)
    }

    @Test func replyLineSitsAboveTheHeaderAndOpensTheThread() throws {
        let context = ReplyContextPresentation(rootID: rootID, author: Self.bob, preview: .text("could you look into it"))
        let (c, window, spy) = makeTimeline([presentation(2, rootID: rootID, context: context)], inline: true)
        defer { c.removeAllContent(); window.close() }
        let row = try cell(c, row: 0)
        row.layoutSubtreeIfNeeded()
        let line = try #require(row.subviews.compactMap { $0 as? ReplyContextView }.first)
        #expect(!line.isHidden)
        #expect(line.frame.minX == TimelineRowMetrics.horizontalInset, "the connector starts in the avatar column")
        #expect(line.frame.maxY <= row.avatarView.frame.minY)
        #expect(line.accessibilityLabel() == "Reply to Bob: could you look into it")
        #expect(line.accessibilityPerformPress())
        #expect(spy.actions == [.openThread(root: rootID)])
        #expect(row.accessibilitySummary?.contains("Reply to Bob") == true)
    }

    @Test func threadRootShowsASummaryChip() throws {
        let (c, window, spy) = makeTimeline([presentation(1, replyCount: 3)], inline: false)
        defer { c.removeAllContent(); window.close() }
        let row = try cell(c, row: 0)
        row.layoutSubtreeIfNeeded()
        let chip = try #require(row.subviews.compactMap { $0 as? ThreadSummaryView }.first)
        #expect(!chip.isHidden && chip.frame.width > 0)
        #expect(chip.accessibilityLabel()?.hasPrefix("3 replies") == true)
        #expect(chip.accessibilityPerformPress())
        #expect(spy.actions == [.openThread(root: rootID)])
    }

    @Test func inlineRepliesOfferReplyAndOpenThreadSeparately() {
        let reply = presentation(2, rootID: rootID)
        let inline = TimelinePostActions.entries(for: reply, repliesInline: true).compactMap { $0 }
        #expect(inline.prefix(2).map(\.title) == [TimelineStrings.actionReply, TimelineStrings.menuOpenThread])
        #expect(inline.prefix(2).map(\.action) == [.reply(rootID), .openThread(root: rootID)])
        let threaded = TimelinePostActions.entries(for: reply).compactMap { $0 }
        #expect(threaded.first?.title == TimelineStrings.actionReplyInThread)
        #expect(!threaded.contains { $0.title == TimelineStrings.menuOpenThread })

        let bar = HoverActionBar(frame: .zero)
        let item = TimelineItemID(.post(reply.postID!))
        bar.configure(item: item, post: reply, repliesInline: true, emojiText: { $0 })
        #expect(bar.button(.openThread) != nil)
        bar.configure(item: item, post: reply, repliesInline: false, emojiText: { $0 })
        #expect(bar.button(.openThread) == nil)
        bar.configure(item: item, post: presentation(3), repliesInline: true, emojiText: { $0 })
        #expect(bar.button(.openThread) == nil, "a message without a thread has nothing to open")
    }
}
