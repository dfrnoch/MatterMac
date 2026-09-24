import AppKit
import Testing
@testable import MatterMacUI

@MainActor
@Suite("Composer autocomplete")
struct ComposerCompletionTests {
    // MARK: Query detection

    @Test("Trigger detection before the caret", arguments: [
        ("@al", CompletionTrigger.user, "al"),
        ("hi @", .user, ""),
        ("hi @bob.smith", .user, "bob.smith"),
        ("x\n@al", .user, "al"),
        ("~town", .channel, "town"),
        ("see ~", .channel, ""),
        (":sm", .emoji, "sm"),
        ("nice :+1", .emoji, "+1"),
        ("日本語\u{3000}@yu", .user, "yu"),
        ("@Novák", .user, "Novák"),
    ])
    func detects(text: String, trigger: CompletionTrigger, query: String) throws {
        let ns = text as NSString
        let context = try #require(CompletionQueryDetector.detect(in: ns, selection: NSRange(location: ns.length, length: 0)))
        #expect(context.trigger == trigger)
        #expect(context.query == query)
        #expect(NSMaxRange(context.replacementRange) == ns.length)
    }

    @Test("No trigger", arguments: [
        "", "hello", "email@example", "10:30", ":s", "@a b", "(@al", "a~b", "@al ", "http://x",
        "@" + String(repeating: "x", count: 65),
    ])
    func noTrigger(text: String) {
        let ns = text as NSString
        #expect(CompletionQueryDetector.detect(in: ns, selection: NSRange(location: ns.length, length: 0)) == nil)
    }

    @Test("A non-empty selection never triggers")
    func selectionDoesNotTrigger() {
        #expect(CompletionQueryDetector.detect(in: "@al" as NSString, selection: NSRange(location: 1, length: 2)) == nil)
    }

    @Test("Query length limit is exactly 64")
    func queryLengthLimit() {
        let ok = ("@" + String(repeating: "x", count: 64)) as NSString
        #expect(CompletionQueryDetector.detect(in: ok, selection: NSRange(location: ok.length, length: 0))?.query.count == 64)
    }

    // MARK: Popup behavior

    @Test("Return with the popup open accepts the completion and does not send")
    func returnAcceptsCompletion() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions(ComposerProviderDouble.users(["alice", "alex"]))
        h.type("hi @al")
        await h.settleCompletions()
        #expect(h.controller.completion.isVisible)
        #expect(h.controller.completion.popup.items.map(\.title) == ["alice", "alex"])
        #expect(h.window.firstResponder === h.textView, "the popup never takes first responder")
        #expect(h.controller.completion.popup.window?.canBecomeKey == false)

        h.pressReturn()

        #expect(h.spy.sentTexts.isEmpty)
        #expect(h.text == "hi @alice ")
        #expect(!h.controller.completion.isVisible)
        h.pressReturn()
        #expect(h.spy.sentTexts == ["hi @alice "])
    }

    @Test("Up/Down navigate, Tab accepts; VoiceOver announcement follows the selection")
    func navigateAndTab() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions(ComposerProviderDouble.users(["alice", "alex", "alan"]))
        h.type("@al")
        await h.settleCompletions()
        #expect(h.controller.completion.popup.lastAnnouncement?.contains("alice") == true)
        h.command(#selector(NSResponder.moveDown(_:)))
        h.command(#selector(NSResponder.moveDown(_:)))
        #expect(h.controller.completion.popup.selectedItem?.title == "alan")
        #expect(h.controller.completion.popup.lastAnnouncement?.contains("3") == true)
        h.command(#selector(NSResponder.moveDown(_:)))  // wraps
        #expect(h.controller.completion.popup.selectedItem?.title == "alice")
        h.command(#selector(NSResponder.moveUp(_:)))  // wraps back
        #expect(h.controller.completion.popup.selectedItem?.title == "alan")
        #expect(h.spy.editLastRequests == 0)
        h.command(#selector(NSResponder.insertTab(_:)))
        #expect(h.text == "@alan ")
        #expect(!h.text.contains("\t"))
    }

    @Test("Escape closes the popup first, then cancels the reply mode")
    func escapeClosesPopupThenCancelsMode() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.controller.mode = .reply(authorName: "Carol")
        h.enableCompletions(ComposerProviderDouble.users(["carol"]))
        h.type("@ca")
        await h.settleCompletions()
        #expect(h.controller.completion.isVisible)

        h.pressEscape()
        #expect(!h.controller.completion.isVisible)
        #expect(h.spy.cancelModeRequests == 0)
        // The dismissed query does not reopen by itself...
        h.controller.completion.update()
        await h.settleCompletions()
        #expect(!h.controller.completion.isVisible)

        h.pressEscape()
        #expect(h.spy.cancelModeRequests == 1)
        #expect(h.text == "@ca", "cancelling never discards text by itself")

        // ...but typing reopens it.
        h.type("r")
        await h.settleCompletions()
        #expect(h.controller.completion.isVisible)
    }

    @Test("Shift-Return with the popup open accepts the suggestion (popup has priority)")
    func popupHasPriorityOverNewline() async throws {
        let h = ComposerHarness()
        defer { h.close() }
        let source = h.textView.inputContext?.selectedKeyboardInputSource ?? ""
        try #require(source.hasPrefix("com.apple.keylayout."), "keyboard layout input source required")
        h.enableCompletions(ComposerProviderDouble.users(["bob"]))
        h.type("@b")
        await h.settleCompletions()
        h.textView.keyDown(with: h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode, modifiers: .shift))
        #expect(h.text == "@bob ")
        #expect(h.spy.sentTexts.isEmpty)
    }

    @Test("Command-Return with the popup open closes it and sends")
    func commandReturnWithPopup() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions(ComposerProviderDouble.users(["bob"]))
        h.type("@b")
        await h.settleCompletions()
        let commandReturn = h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode, modifiers: .command)
        #expect(h.textView.performKeyEquivalent(with: commandReturn))
        #expect(!h.controller.completion.isVisible)
        #expect(h.spy.sentTexts == ["@b"])
    }

    @Test("Accepting is one undoable edit")
    func acceptIsOneUndoStep() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions([CompletionItem(id: "smile", title: "smile", insertionText: ":smile:", leadingText: "😄")])
        h.type("hey :sm")
        await h.endEvent()
        await h.settleCompletions()
        #expect(h.controller.completion.isVisible)
        h.pressReturn()
        #expect(h.text == "hey :smile: ")
        await h.endEvent()
        h.undoManager.undo()
        #expect(h.text == "hey :sm")
        h.undoManager.redo()
        #expect(h.text == "hey :smile: ")
    }

    @Test("At most eight items are shown")
    func maxEightItems() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions(ComposerProviderDouble.users((0..<30).map { "user\($0)" }))
        h.type("@u")
        await h.settleCompletions()
        #expect(h.controller.completion.popup.items.count == 8)
    }

    @Test("Emoji needs two query characters")
    func emojiMinimumQuery() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions(ComposerProviderDouble.users(["x"]))
        h.type(":s")
        await h.settleCompletions()
        #expect(h.provider.queries.isEmpty)
        #expect(!h.controller.completion.isVisible)
        h.type("m")
        await h.settleCompletions()
        #expect(h.provider.queries.map(\.1) == ["sm"])
        #expect(h.provider.queries.first?.0 == .emoji)
    }

    @Test("Debounce coalesces fast typing into one provider call with the latest query")
    func debounceLatestWins() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.controller.completion.debounceInterval = .milliseconds(80)
        h.enableCompletions(ComposerProviderDouble.users(["alice"]))
        h.type("@")
        h.type("a")
        h.type("l")
        await h.settleCompletions()
        #expect(h.provider.queries.map(\.1) == ["al"])
        #expect(h.controller.completion.providerCallCount == 1)
        #expect(h.controller.completion.isVisible)
    }

    @Test("A superseded in-flight request is cancelled and its late result ignored")
    func supersededResultIgnored() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.provider.itemsByQuery = [
            "a": ComposerProviderDouble.users(["stale"]),
            "al": ComposerProviderDouble.users(["alice"]),
        ]
        h.provider.holdQueries = ["a"]
        h.controller.completionProvider = h.provider
        h.type("@a")
        // Wait until the first request is suspended inside the provider.
        while h.provider.heldCount == 0 { await Task.yield() }
        let first = h.controller.completion.pendingFetch
        h.type("l")
        await h.settleCompletions()
        #expect(h.controller.completion.popup.items.map(\.title) == ["alice"])
        h.provider.release("a")
        await first?.value
        #expect(h.provider.cancelledQueries == ["a"])
        #expect(h.controller.completion.popup.items.map(\.title) == ["alice"], "late result must not replace newer items")
    }

    @Test("Moving the caret away from the query closes the popup")
    func caretMoveCloses() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions(ComposerProviderDouble.users(["alice"]))
        h.type("x @al")
        await h.settleCompletions()
        #expect(h.controller.completion.isVisible)
        h.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!h.controller.completion.isVisible)
    }

    @Test("Composition does not re-query; the committed text does")
    func compositionFreezesQuery() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions(ComposerProviderDouble.users(["yuki"]))
        h.type("@")
        await h.settleCompletions()
        let before = h.provider.queries.count
        h.setMarked("ゆき")
        await h.settleCompletions()
        #expect(h.provider.queries.count == before)
        h.textView.insertText("雪", replacementRange: NSRange(location: NSNotFound, length: 0))
        await h.settleCompletions()
        #expect(h.provider.queries.last?.1 == "雪")
    }

    @Test("Resigning first responder closes the popup")
    func resignCloses() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.enableCompletions(ComposerProviderDouble.users(["alice"]))
        h.type("@a")
        await h.settleCompletions()
        #expect(h.controller.completion.isVisible)
        h.window.makeFirstResponder(nil)
        #expect(!h.controller.completion.isVisible)
    }

    @Test("Popup is placed above the anchor when there is room, else below")
    func popupPlacement() {
        let size = NSSize(width: 320, height: 100)
        let anchor = NSRect(x: 100, y: 50, width: 8, height: 16)
        let above = CompletionPopup.origin(for: size, anchor: anchor, screen: nil)
        #expect(above.y == anchor.maxY + 4)
        if let screen = NSScreen.main {
            let top = NSRect(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.maxY - 20, width: 8, height: 16)
            let below = CompletionPopup.origin(for: size, anchor: top, screen: screen)
            #expect(below.y + size.height <= top.minY)
        }
    }
}
