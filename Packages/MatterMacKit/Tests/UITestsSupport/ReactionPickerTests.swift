import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Reaction picker and emoji rendering")
struct ReactionPickerTests {
    private final class Spy {
        var picked: [String] = []
        var cancels = 0
    }

    private func makePicker() -> (ReactionPickerViewController, NSWindow, Spy) {
        let picker = ReactionPickerViewController()
        let spy = Spy()
        picker.onPick = { spy.picked.append($0) }
        picker.onCancel = { spy.cancels += 1 }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ReactionPickerViewController.preferredSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = picker
        window.contentView?.layoutSubtreeIfNeeded()
        return (picker, window, spy)
    }

    private func command(_ picker: ReactionPickerViewController, _ selector: Selector) {
        _ = picker.control(picker.searchField, textView: NSTextView(), doCommandBy: selector)
    }

    private func search(_ picker: ReactionPickerViewController, _ text: String) {
        picker.searchField.stringValue = text
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.searchField))
    }

    @Test func browseStartsWithStaticFrequentRowAndReturnPicksFirst() {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        #expect(picker.sections.first?.emoji.map(\.name) == EmojiCatalog.defaultQuickReactions)
        #expect(picker.sections.count == 1 + EmojiCategory.allCases.filter(\.isShownInPicker).count)
        #expect(picker.selectedEmoji?.name == "+1")
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked == ["+1"])
    }

    @Test func arrowKeysMoveTheSelectionAndAnnounceIt() {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        command(picker, #selector(NSResponder.moveRight(_:)))
        #expect(picker.selectedEmoji?.name == "smile")
        #expect(picker.lastAnnouncement == "smile")
        command(picker, #selector(NSResponder.moveLeft(_:)))
        command(picker, #selector(NSResponder.moveLeft(_:)))
        #expect(picker.selectedEmoji?.name == "+1", "stops at the first item")
        // The frequent row is shorter than a grid row: Down enters the next section.
        command(picker, #selector(NSResponder.moveDown(_:)))
        #expect(picker.selection?.section == 1)
        #expect(picker.selectedEmoji?.name == "grinning")
        command(picker, #selector(NSResponder.moveDown(_:)))
        #expect(picker.selection == IndexPath(item: picker.columnCount, section: 1))
        command(picker, #selector(NSResponder.moveUp(_:)))
        command(picker, #selector(NSResponder.moveUp(_:)))
        #expect(picker.selection == IndexPath(item: 0, section: 0))
        command(picker, #selector(NSResponder.moveRight(_:)))
        command(picker, #selector(NSResponder.moveRight(_:)))
        command(picker, #selector(NSResponder.moveRight(_:)))
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked == ["heart"])
    }

    @Test func searchFiltersAndReturnPicksTheFirstResult() {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        search(picker, "tad")
        #expect(picker.sections.count == 1)
        #expect(picker.selectedEmoji?.name == "tada")
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked == ["tada"])
        // An alias resolves to the primary name that is sent to the server.
        search(picker, "thumbsup")
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked == ["tada", "+1"])
        search(picker, "zzqqxx")
        #expect(picker.sections.isEmpty)
        #expect(picker.selectedEmoji == nil)
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked.count == 2)
        search(picker, "")
        #expect(picker.selectedEmoji?.name == "+1")
    }

    @Test func escapeCancelsAndClickPicks() {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        command(picker, #selector(NSResponder.cancelOperation(_:)))
        #expect(spy.cancels == 1)
        #expect(spy.picked.isEmpty)
        picker.collectionView(picker.collectionView, didSelectItemsAt: [IndexPath(item: 2, section: 0)])
        #expect(spy.picked == ["white_check_mark"])
        // Clicking the highlighted item also picks: the collection view's own
        // selection is kept empty so the click always reports.
        picker.apply(query: "")
        let first = IndexPath(item: 0, section: 0)
        picker.collectionView.selectItems(at: [first], scrollPosition: [])
        picker.collectionView(picker.collectionView, didSelectItemsAt: [first])
        #expect(spy.picked == ["white_check_mark", "+1"])
        #expect(picker.collectionView.selectionIndexPaths.isEmpty)
    }

    @Test func itemsExposeTheEmojiNameToVoiceOver() throws {
        let (picker, window, _) = makePicker()
        defer { window.close() }
        let item = picker.collectionView(picker.collectionView, itemForRepresentedObjectAt: IndexPath(item: 2, section: 0))
        #expect(item.view.accessibilityLabel() == "white check mark")
        #expect(item.view.accessibilityRole() == .button)
        #expect(item.view.toolTip == ":white_check_mark:")
        #expect((item as? EmojiPickerItem)?.isCurrent == false)
        let current = picker.collectionView(picker.collectionView, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        #expect((current as? EmojiPickerItem)?.isCurrent == true)
        #expect(current.view.isAccessibilitySelected())
    }

    @Test func timelineRendersGlyphsAndGivesARowAnchor() throws {
        let c = TimelineViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        defer { c.removeAllContent(); window.close() }
        c.emojiLookup = { EmojiCatalog.system.glyph(for: $0) }
        let post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        let reactions = [ReactionGroup(emojiName: "+1", count: 2, includesCurrentUser: true),
                         ReactionGroup(emojiName: "party_parrot", count: 1, includesCurrentUser: false)]
        c.apply(TimelineSnapshot(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
                                 target: .channel(CoreFixtures.channel(1).id), generation: 1,
                                 items: [item(post, text: "Done :tada: :party_parrot:", reactions: reactions)],
                                 isAtLiveEdge: true, isStale: false, scrollRequest: nil))
        window.contentView?.layoutSubtreeIfNeeded()
        let cell = try #require(c.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? MessageCellView)
        #expect(cell.displayedBodyText == "Done 🎉 :party_parrot:")
        let chips = cell.subviews.compactMap { $0 as? ReactionChipView }.filter { !$0.isHidden }
        #expect(chips.map(\.emoji) == ["👍", ":party_parrot:"])
        #expect(chips.first?.toolTip == "You and 1 other reacted with :+1:")
        #expect(chips.last?.toolTip == "1 person reacted with :party_parrot:")
        #expect(chips.first?.accessibilityLabel()?.contains("+1") == true)
        #expect(c.anchorRect(for: post.id) != nil)
        #expect(c.anchorRect(for: CoreFixtures.post(9, channel: post.channelID).id) == nil)
    }

    private func item(_ post: Post, text: String, reactions: [ReactionGroup]) -> TimelineItem {
        TimelineItem(id: TimelineItemID(.post(post.id)), revision: 1, content: .post(
            PostPresentation(postID: post.id, pendingID: nil, channelID: post.channelID, rootID: nil,
                author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob",
                                           isBot: false, isCurrentUser: false, avatarRevision: 0),
                createdAt: post.createAt, isContinuation: false,
                body: .document(MarkupParser.parse(text), isCollapsed: false), isEdited: false,
                isPinned: false, files: [], reactions: reactions, replyCount: 0, showsThreadContext: false,
                sendState: nil, actions: .none, permalink: nil)))
    }
}
