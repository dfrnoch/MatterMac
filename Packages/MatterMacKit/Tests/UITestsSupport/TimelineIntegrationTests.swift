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

    @Test func scrollingKeepsNativeRowRetentionBounded() async throws {
        let c = TimelineViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        defer { c.removeAllContent(); window.close() }
        c.apply(snapshot((1...100).map { item($0) }, generation: 1))
        window.orderFront(nil)
        // reloadData explicitly drops all known views, so total allocations across
        // reloads do not measure reuse. Scroll one table and weakly observe its
        // live displayed rows after native run-loop/autorelease transactions.
        let seen = NSHashTable<TimelineRowView>.weakObjects()
        var maximumDisplayed = 0
        for cycle in 0..<20 {
            autoreleasepool {
                c.tableView.scrollRowToVisible(cycle.isMultiple(of: 2) ? 0 : 99)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(30))
            autoreleasepool {
                var displayed = 0
                c.tableView.enumerateAvailableRowViews { row, index in
                    guard index >= 0,
                          c.tableView.rect(ofRow: index).intersects(c.visibleDocumentRect),
                          let row = row as? TimelineRowView else { return }
                    displayed += 1
                    seen.add(row)
                }
                #expect(displayed > 0)
                maximumDisplayed = max(maximumDisplayed, displayed)
                #expect(seen.allObjects.count <= 2 * maximumDisplayed,
                        "Repeated scrolling must not retain more than two viewports of observed rows")
            }
        }
    }

    @Test func floatingControlsPreserveAnchorAndExcludeCoveredMessages() throws {
        let c = TimelineViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        defer { c.removeAllContent(); window.close() }
        let state = snapshot((1...100).map { item($0) }, generation: 1)
        c.apply(state)
        window.contentView?.layoutSubtreeIfNeeded()
        c.setBottomOverlayInset(80)
        #expect(c.visibleDocumentRect.maxY >= c.tableView.rect(ofRow: 99).maxY - 1)
        #expect(c.distanceFromBottom() < 1)
        c.setVisibleTop(c.tableView.rect(ofRow: 20).minY)
        let anchor = try #require(c.captureAnchor())
        c.setBottomOverlayInset(180)
        #expect(c.captureAnchor()?.itemID == anchor.itemID)
        #expect(abs((c.captureAnchor()?.offset ?? 0) - anchor.offset) < 1)
        c.apply(snapshot((0...100).map { item($0) }, generation: 2))
        #expect(c.captureAnchor()?.itemID == anchor.itemID)
        #expect(abs((c.captureAnchor()?.offset ?? 0) - anchor.offset) < 1)
        #expect(c.scrollView.contentView.bounds.height - c.visibleDocumentRect.height >= 180)
        let report = c.currentVisibilityReport(state)
        let coveredRange = c.tableView.rows(in: NSRect(x: 0, y: c.visibleDocumentRect.maxY + 1,
            width: c.tableView.bounds.width, height: 150))
        if coveredRange.length > 1 {
            #expect(report.last != c.items[coveredRange.location + 1].post?.postID)
        }
        c.isPinnedToLiveEdge = true
        c.setBottomOverlayInset(60)
        #expect(c.distanceFromBottom() < 1)
        #expect(c.currentVisibilityReport(state).last == state.items.last?.post?.postID)
    }

    /// Scrolled to the top, a prepended page keeps the previously first post in place
    /// instead of leaving the viewport at the top (which requested page after page).
    @Test func prependedOlderPageKeepsThePositionAndDoesNotRequestAgain() throws {
        let c = TimelineViewController()
        let delegate = RecordingDelegate()
        c.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        defer { c.removeAllContent(); window.close() }
        func gap(_ state: GapPresentation.State, revision: UInt64) -> TimelineItem {
            TimelineItem(id: TimelineItemID(.olderGap), revision: revision,
                         content: .gap(GapPresentation(direction: .older, state: state)))
        }
        c.apply(snapshot([gap(.idle, revision: 1)] + (100...160).map { item($0) }, generation: 1))
        window.contentView?.layoutSubtreeIfNeeded()
        c.setVisibleTop(0)
        c.afterScrollPositionSettled()
        #expect(delegate.olderRequests == 1)
        c.apply(snapshot([gap(.loading, revision: 2)] + (100...160).map { item($0) }, generation: 2))
        let firstPost = TimelineItemID(.post(CoreFixtures.post(100, channel: CoreFixtures.channel(1).id).id))
        let before = c.tableView.rect(ofRow: try #require(c.rowIndex[firstPost])).minY - c.visibleDocumentRect.minY
        c.apply(snapshot([gap(.idle, revision: 3)] + (40...160).map { item($0) }, generation: 3))
        window.contentView?.layoutSubtreeIfNeeded()
        let after = c.tableView.rect(ofRow: try #require(c.rowIndex[firstPost])).minY - c.visibleDocumentRect.minY
        #expect(abs(after - before) < 1, "The first post of the old page stays where it was")
        #expect(c.visibleDocumentRect.minY > c.visibleDocumentRect.height * 1.5)
        c.afterScrollPositionSettled()
        #expect(delegate.olderRequests == 1, "No further page until the user scrolls up again")
    }

    private final class RecordingDelegate: TimelineViewControllerDelegate {
        var olderRequests = 0
        func timelineRequestsOlder() { olderRequests += 1 }
        func timelineRequestsNewer() {}
        func timelineVisibleRangeDidChange(first: PostID?, last: PostID?, isAtLiveEdge: Bool) {}
        func timeline(perform action: TimelineAction) {}
        func timelineImage(for request: TimelineImageRequest) -> NSImage? { nil }
        func timelineNeedsImage(_ request: TimelineImageRequest) {}
    }

    /// `MM_SNAPSHOT_DIR` optionally captures only this test's window in both appearances.
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
    func jumpToLatestPillFollowsTheLiveEdge(appearance: NSAppearance.Name) async throws {
        let c = TimelineViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = c
        defer { c.removeAllContent(); window.close() }
        c.apply(snapshot((1...100).map { item($0) }, generation: 1))
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(c.newMessagesButton.isHidden)

        c.setVisibleTop(c.tableView.rect(ofRow: 10).minY)
        c.updateNewMessagesButton()
        #expect(!c.newMessagesButton.isHidden)
        #expect(c.newMessagesButton.title == TimelineStrings.jumpToLatest)
        #expect(!c.newMessagesButton.isProminent)
        let pill = c.newMessagesButton.frame
        #expect(pill.height == JumpToLatestPill.height)
        #expect(abs(pill.midX - c.view.bounds.midX) <= 1)
        await capture(window, "jump-to-latest-\(appearance.rawValue).png")

        c.newItemsBelow = 3
        c.updateNewMessagesButton()
        #expect(c.newMessagesButton.title == TimelineStrings.newMessagesButton(3))
        #expect(c.newMessagesButton.isProminent)
        #expect(c.newMessagesButton.button.accessibilityLabel() == TimelineStrings.newMessagesButton(3))
        await capture(window, "new-messages-\(appearance.rawValue).png")

        #expect(c.newMessagesButton.button.target === c)
        #expect(c.newMessagesButton.button.action == #selector(TimelineViewController.newMessagesButtonPressed(_:)))
        c.newMessagesButtonPressed(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        c.updateNewMessagesButton()
        #expect(c.distanceFromBottom() < 1)
        #expect(c.newMessagesButton.isHidden)
    }

    private func capture(_ window: NSWindow, _ name: String) async {
        guard let directory = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] else { return }
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent(name).path]
        try? process.run()
        process.waitUntilExit()
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
