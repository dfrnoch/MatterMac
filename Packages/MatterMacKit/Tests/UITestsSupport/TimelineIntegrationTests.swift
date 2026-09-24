import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Native timeline integration")
struct TimelineIntegrationTests {
    @Test func insertionEditAndRemovalReuseTheTable() throws {
        let c = TimelineViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        defer { c.removeAllContent(); window.close() }
        c.apply(snapshot([item(1), item(2)], generation: 1))
        window.contentView?.layoutSubtreeIfNeeded()
        let cell = try #require(c.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? MessageCellView)
        #expect(cell.displayedBodyText.contains("message 1"))
        let reloads = c.tableView.counters.fullReloads
        c.apply(snapshot([item(1), item(2), item(3)], generation: 2))
        #expect(c.tableView.numberOfRows == 3)
        #expect(c.tableView.counters.insertedRows == 1)
        #expect(c.tableView.counters.fullReloads == reloads)
        c.apply(snapshot([item(1, revision: 2), item(2), item(3)], generation: 3))
        #expect(c.tableView.counters.rowReloads > 0)
        #expect(c.tableView.counters.fullReloads == reloads)
        c.apply(snapshot([item(1, revision: 2), item(3)], generation: 4))
        #expect(c.tableView.numberOfRows == 2)
        #expect(c.tableView.counters.removedRows == 1)
        c.apply(snapshot([], generation: 3))
        #expect(c.tableView.numberOfRows == 2)
        c.removeAllContent()
        #expect(c.tableView.numberOfRows == 0)
        #expect(c.imageDemand.isEmpty)
    }

    private func snapshot(_ items: [TimelineItem], generation: UInt64) -> TimelineSnapshot {
        TimelineSnapshot(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
                         target: .channel(CoreFixtures.channel(1).id), generation: generation,
                         items: items, isAtLiveEdge: true, isStale: false, scrollRequest: nil)
    }
    private func item(_ n: Int, revision: UInt64 = 1) -> TimelineItem {
        let post = CoreFixtures.post(n, channel: CoreFixtures.channel(1).id)
        return TimelineItem(id: TimelineItemID(.post(post.id)), revision: revision, content: .post(
            PostPresentation(postID: post.id, pendingID: nil, channelID: post.channelID, rootID: nil,
                author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob",
                                           isBot: false, isCurrentUser: false, avatarRevision: 0),
                createdAt: post.createAt, isContinuation: false,
                body: .document(MarkupParser.parse(post.message), isCollapsed: false), isEdited: revision > 1,
                isPinned: false, files: [], reactions: [], replyCount: 0, showsThreadContext: false,
                sendState: nil, actions: .none, permalink: nil)))
    }
}
