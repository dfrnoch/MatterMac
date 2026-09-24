import AppKit
import MatterMacModels
import Testing
@testable import MatterMacUI

@MainActor
@Suite("Composer key handling")
struct ComposerKeyHandlingTests {
    @Test("Return sends the exact text and leaves it in place until the host clears")
    func returnSends() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("hello  world ")
        h.pressReturn()
        #expect(h.spy.sentTexts == ["hello  world "])
        #expect(h.text == "hello  world ")
        h.controller.clear()
        #expect(h.text.isEmpty)
    }

    @Test("Return in an empty or whitespace-only composer does nothing")
    func returnOnEmpty() {
        let h = ComposerHarness()
        defer { h.close() }
        h.pressReturn()
        h.type("  \n\t ")
        h.pressReturn()
        #expect(h.spy.sentTexts.isEmpty)
        #expect(h.text == "  \n\t ")
        #expect(!h.controller.canSend)
    }

    @Test("Shift-Return (real key event through the key-binding system) inserts a newline")
    func shiftReturnInsertsNewline() throws {
        let h = ComposerHarness()
        defer { h.close() }
        let source = h.textView.inputContext?.selectedKeyboardInputSource ?? ""
        try #require(source.hasPrefix("com.apple.keylayout."), "keyboard layout input source required")
        h.type("a")
        h.textView.keyDown(with: h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode, modifiers: .shift))
        h.type("b")
        #expect(h.text == "a\nb")
        #expect(h.spy.sentTexts.isEmpty)
        h.textView.keyDown(with: h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode))
        #expect(h.spy.sentTexts == ["a\nb"])
    }

    @Test("Option-Return and Control-Return insert a plain \\n (never U+2028/U+2029)")
    func alternateNewlines() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("a")
        h.command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        h.type("b")
        h.command(#selector(NSResponder.insertLineBreak(_:)))
        h.type("c")
        h.command(#selector(NSResponder.insertParagraphSeparator(_:)))
        h.type("d")
        #expect(h.text.scalarValues == "a\nb\nc\nd".scalarValues)
        #expect(h.spy.sentTexts.isEmpty)
    }

    @Test("Command-Return mode: Return inserts a newline, Command-Return sends")
    func commandReturnMode() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.controller.sendBehavior = .commandReturnSends
        h.type("line1")
        h.pressReturn()
        h.type("line2")
        #expect(h.text == "line1\nline2")
        #expect(h.spy.sentTexts.isEmpty)

        let commandReturn = h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode, modifiers: .command)
        #expect(h.textView.performKeyEquivalent(with: commandReturn))
        #expect(h.spy.sentTexts == ["line1\nline2"])

        let keypad = h.keyEvent("\u{3}", keyCode: ComposerHarness.keypadEnterKeyCode, modifiers: .command)
        #expect(h.textView.performKeyEquivalent(with: keypad))
        #expect(h.spy.sentTexts.count == 2)
    }

    @Test("Command-Return that reaches keyDown (no key equivalent path) still sends")
    func commandReturnViaKeyDown() throws {
        let h = ComposerHarness()
        defer { h.close() }
        let source = h.textView.inputContext?.selectedKeyboardInputSource ?? ""
        try #require(source.hasPrefix("com.apple.keylayout."), "keyboard layout input source required")
        h.controller.sendBehavior = .commandReturnSends
        h.type("x")
        h.textView.keyDown(with: h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode, modifiers: .command))
        #expect(h.spy.sentTexts == ["x"])
        #expect(h.text == "x")
    }

    @Test("Only the exact Command-Return chord is intercepted")
    func onlyExactChordIntercepted() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("x")
        let shiftCommand = h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode, modifiers: [.command, .shift])
        _ = h.textView.performKeyEquivalent(with: shiftCommand)
        let commandA = h.keyEvent("a", keyCode: 0, modifiers: .command)
        _ = h.textView.performKeyEquivalent(with: commandA)
        #expect(h.spy.sentTexts.isEmpty)
        #expect(h.text == "x")
    }

    @Test("Command-Return during composition is not intercepted")
    func commandReturnDuringComposition() {
        let h = ComposerHarness()
        defer { h.close() }
        h.controller.sendBehavior = .commandReturnSends
        h.setMarked("zhong")
        let commandReturn = h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode, modifiers: .command)
        #expect(!h.textView.performKeyEquivalent(with: commandReturn))
        #expect(h.spy.sentTexts.isEmpty)
        #expect(h.textView.hasMarkedText())
    }

    @Test("Command-Return is ignored when the composer is not first responder")
    func commandReturnNeedsFocus() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("x")
        h.window.makeFirstResponder(nil)
        let commandReturn = h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode, modifiers: .command)
        #expect(!h.textView.performKeyEquivalent(with: commandReturn))
        #expect(h.spy.sentTexts.isEmpty)
    }

    @Test("Escape in compose mode is reported; in reply/edit mode it requests cancel")
    func escapeByMode() {
        let h = ComposerHarness()
        defer { h.close() }
        h.pressEscape()
        #expect(h.spy.escapes == 1)
        h.controller.mode = .reply(authorName: "Bob")
        h.pressEscape()
        #expect(h.spy.cancelModeRequests == 1)
        h.controller.mode = .edit(postID: PostID(rawValue: "abcdefghijklmnopqrstuvwxyz")!, original: "old")
        h.pressEscape()
        #expect(h.spy.cancelModeRequests == 2)
        #expect(h.spy.escapes == 1)
    }

    @Test("Up Arrow in an empty composer asks to edit the last message; otherwise moves the caret")
    func upArrowEditsLast() {
        let h = ComposerHarness()
        defer { h.close() }
        h.command(#selector(NSResponder.moveUp(_:)))
        #expect(h.spy.editLastRequests == 1)
        h.type("one\ntwo")
        h.command(#selector(NSResponder.moveUp(_:)))
        #expect(h.spy.editLastRequests == 1)
        #expect(h.textView.selectedRange().location <= 3)
    }

    @Test("Standard editing commands pass through untouched")
    func standardCommandsPassThrough() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("alpha beta")
        h.command(#selector(NSResponder.moveWordLeft(_:)))
        #expect(h.textView.selectedRange() == NSRange(location: 6, length: 0))
        h.command(#selector(NSResponder.moveToBeginningOfLine(_:)))
        #expect(h.textView.selectedRange().location == 0)
        h.command(#selector(NSResponder.moveToEndOfLine(_:)))
        #expect(h.textView.selectedRange().location == 10)
        h.command(#selector(NSResponder.selectAll(_:)))
        #expect(h.textView.selectedRange() == NSRange(location: 0, length: 10))
        h.command(#selector(NSResponder.deleteBackward(_:)))
        #expect(h.text.isEmpty)
        #expect(h.spy.sentTexts.isEmpty)
    }

    @Test("Edit ▸ Undo through the responder chain reaches the composer's own undo manager")
    func undoThroughResponderChain() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("hello")
        await h.endEvent()
        #expect(h.textView.undoManager !== h.window.undoManager)
        let undoItem = NSMenuItem(title: "Undo", action: #selector(ComposerTextView.undo(_:)), keyEquivalent: "z")
        #expect(h.textView.validateMenuItem(undoItem))
        #expect(undoItem.title.contains("Undo"))
        #expect(h.textView.tryToPerform(#selector(ComposerTextView.undo(_:)), with: nil))
        #expect(h.text.isEmpty)
        #expect(h.textView.tryToPerform(#selector(ComposerTextView.redo(_:)), with: nil))
        #expect(h.text == "hello")
    }

    @Test("Undo is disabled while a composition is active")
    func undoDisabledDuringComposition() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("a")
        await h.endEvent()
        h.setMarked("zh")
        let undoItem = NSMenuItem(title: "Undo", action: #selector(ComposerTextView.undo(_:)), keyEquivalent: "z")
        #expect(!h.textView.validateMenuItem(undoItem))
        _ = h.textView.tryToPerform(#selector(ComposerTextView.undo(_:)), with: nil)
        #expect(h.text == "azh")
    }

    @Test("Send is blocked while the host disallows sending; text is kept")
    func sendNotAllowed() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("wait")
        h.controller.isSendAllowed = false
        h.pressReturn()
        #expect(h.spy.sentTexts.isEmpty)
        #expect(h.text == "wait")
        #expect(!h.controller.sendButton.isEnabled)
        h.controller.isSendAllowed = true
        h.controller.sendButton.performClick(nil)
        #expect(h.spy.sentTexts == ["wait"])
    }

    @Test("The Send button commits an active composition before sending")
    func sendButtonCommitsComposition() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("a")
        h.setMarked("中文")
        h.controller.requestSend()
        #expect(h.spy.sentTexts == ["a中文"])
        #expect(!h.textView.hasMarkedText())
    }
}
