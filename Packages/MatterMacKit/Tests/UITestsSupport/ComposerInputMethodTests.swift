import AppKit
import Testing
@testable import MatterMacUI

// SPEC §13 mandatory input-method scenarios. These are programmatic simulations
// of the NSTextInputClient calls an input method makes (setMarkedText /
// insertText / unmarkText) and of key-binding commands (doCommand(by:)); they do
// not drive a real input method. See docs/research/apple.md for the
// manual checklist with real input sources.

@MainActor
@Suite("Composer input methods")
struct ComposerInputMethodTests {
    @Test("Japanese: Return during composition confirms, never sends or adds a newline")
    func japaneseCompositionReturnConfirms() {
        let h = ComposerHarness()
        defer { h.close() }
        h.setMarked("にほんご")
        #expect(h.textView.hasMarkedText())
        h.setMarked("日本語")  // conversion replaces the marked text
        #expect(h.textView.markedRange() == NSRange(location: 0, length: 3))

        h.pressReturn()

        #expect(h.spy.sentTexts.isEmpty)
        #expect(!h.text.contains("\n"))
        #expect(h.text == "日本語")
        #expect(!h.textView.hasMarkedText())

        h.pressReturn()  // composition finished: now Return sends
        #expect(h.spy.sentTexts == ["日本語"])
        #expect(h.text == "日本語", "the composer never clears on its own")
    }

    @Test("Japanese: input-method commit, then Return sends the committed text")
    func japaneseCommitThenSend() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("今日は")
        h.setMarked("にほんご")
        h.pressEscape()
        #expect(h.spy.escapes == 0, "Escape during composition belongs to the input method")
        #expect(h.textView.hasMarkedText(), "Escape reaching the view does not destroy the composition")
        h.pressReturn()
        #expect(h.spy.sentTexts.isEmpty)
        // Start a fresh composition and let the "input method" commit it.
        h.setMarked("にほんご")
        h.setMarked("日本語")
        h.textView.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!h.textView.hasMarkedText())
        #expect(h.text == "今日はにほんご日本語")
        h.pressReturn()
        #expect(h.spy.sentTexts == ["今日はにほんご日本語"])
    }

    @Test("Chinese pinyin: zhongwen → 中文; Return only sends after commit")
    func chinesePinyin() {
        let h = ComposerHarness()
        defer { h.close() }
        for partial in ["z", "zh", "zho", "zhon", "zhong", "zhongw", "zhongwe", "zhongwen"] {
            h.setMarked(partial)
        }
        #expect(h.text == "zhongwen")
        h.setMarked("中文")
        #expect(h.textView.hasMarkedText())
        h.command(#selector(NSResponder.insertNewline(_:)))
        #expect(h.spy.sentTexts.isEmpty)
        #expect(h.text == "中文")

        h.type("很好")
        h.pressReturn()
        #expect(h.spy.sentTexts == ["中文很好"])
    }

    @Test("Chinese: unmarkText commits the candidate exactly")
    func chineseUnmarkCommits() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("说")
        h.setMarked("zhongwen")
        h.setMarked("中文")
        h.textView.unmarkText()
        #expect(h.text == "说中文")
        #expect(h.textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(h.textView.metrics == h.recountedMetrics)
    }

    @Test("Return through the real key-binding path while marked text exists")
    func keyDownReturnWithMarkedText() throws {
        let h = ComposerHarness()
        defer { h.close() }
        let source = h.textView.inputContext?.selectedKeyboardInputSource ?? ""
        // With a real input method selected, NSTextInputContext may consume the key
        // itself; this check only applies to plain keyboard layouts.
        try #require(source.hasPrefix("com.apple.keylayout."), "keyboard layout input source required")
        h.setMarked("にほ")
        h.textView.keyDown(with: h.keyEvent("\r", keyCode: ComposerHarness.returnKeyCode))
        #expect(h.spy.sentTexts.isEmpty)
        #expect(h.text == "にほ")
        #expect(!h.textView.hasMarkedText())
    }

    @Test("Czech diacritics: precomposed and decomposed input stay byte-exact")
    func czechDiacritics() {
        let h = ComposerHarness()
        defer { h.close() }
        for character in ["č", "ř", "ů", " ", "Ž", "ě"] { h.type(character) }
        #expect(h.text.scalarValues == [0x10D, 0x159, 0x16F, 0x20, 0x17D, 0x11B])

        h.type(" ")
        // Decomposed forms (as some layouts, dead keys, or pastes produce them).
        for piece in ["c", "\u{30C}", "r", "\u{30C}", "u", "\u{30A}"] { h.type(piece) }
        let expected = "čřů Žě c\u{30C}r\u{30C}u\u{30A}"
        #expect(h.text.utf8Bytes == expected.utf8Bytes, "no normalization of decomposed marks")
        #expect(h.controller.messageCharacterCount == expected.unicodeScalars.count)
        #expect(h.controller.draftByteCount == expected.utf8.count)

        h.pressReturn()
        #expect(h.spy.sentTexts.first?.utf8Bytes == expected.utf8Bytes)
    }

    @Test("Czech dead-key composition (ˇ then c) commits č")
    func czechDeadKey() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("Da")
        h.setMarked("ˇ")
        h.pressReturn()  // a Return reaching us mid-dead-key only confirms
        #expect(h.spy.sentTexts.isEmpty)
        h.textView.deleteBackward(nil)
        h.setMarked("ˇ")
        h.textView.insertText("č", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.text == "Dač")
        #expect(h.text.scalarValues.last == 0x10D)
    }

    @Test("Grapheme deletion removes whole clusters", arguments: [
        ("a👨‍👩‍👧", "a"),
        ("ae\u{301}", "a"),
        ("a🇨🇿", "a"),
        ("a👍🏽", "a"),
        ("ac\u{30C}", "a"),
        ("a\u{0915}\u{094D}\u{0937}", "a\u{0915}\u{094D}"),  // Devanagari: AppKit deletes the last scalar of a conjunct
    ])
    func graphemeDeletion(input: String, expected: String) {
        let h = ComposerHarness()
        defer { h.close() }
        h.type(input)
        h.textView.deleteBackward(nil)
        #expect(h.text.utf8Bytes == expected.utf8Bytes)
        #expect(h.textView.metrics == h.recountedMetrics)
    }

    @Test("Stacked combining marks are preserved and counted as the server counts")
    func combiningMarksPreserved() {
        let h = ComposerHarness()
        defer { h.close() }
        let zalgoish = "a\u{301}\u{328}\u{35C}e\u{300}\u{316}"
        h.type(zalgoish)
        #expect(h.text.utf8Bytes == zalgoish.utf8Bytes)
        #expect(h.controller.messageCharacterCount == 7, "server counts runes, not grapheme clusters")
        h.pressReturn()
        #expect(h.spy.sentTexts.first?.scalarValues == zalgoish.scalarValues)
    }

    @Test("Arabic and Hebrew mixed with Latin are preserved exactly")
    func bidiPreserved() {
        let h = ComposerHarness()
        defer { h.close() }
        let mixed = "Hello مرحبا بالعالم world שָׁלוֹם 123 عربي‎ (ok) ٣٤٥"
        for word in mixed.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if word.offset > 0 { h.type(" ") }
            h.type(String(word.element))
        }
        #expect(h.text.utf8Bytes == mixed.utf8Bytes)
        // Caret movement through bidi text must not alter content.
        for _ in 0..<10 { h.command(#selector(NSResponder.moveLeft(_:))) }
        for _ in 0..<4 { h.command(#selector(NSResponder.moveWordRight(_:))) }
        #expect(h.text.utf8Bytes == mixed.utf8Bytes)
        h.command(#selector(NSResponder.moveToEndOfDocument(_:)))
        h.pressReturn()
        #expect(h.spy.sentTexts.first?.utf8Bytes == mixed.utf8Bytes)
    }

    @Test("Multiline paste is inserted byte-exact (CRLF, tabs, trailing spaces, code)")
    func multilinePasteByteExact() {
        let h = ComposerHarness()
        defer { h.close() }
        let pasted = "line1\r\nline2\n\tindented  \n```swift\nlet x = \"quote\" -- 'dash'\n```\n\n  trailing "
        let pasteboard = ComposerHarness.privatePasteboard()
        pasteboard.setString(pasted, forType: .string)
        #expect(h.textView.readSelection(from: pasteboard))
        #expect(h.text.utf8Bytes == pasted.utf8Bytes, "no smart quotes, dashes, or smart insert")
        #expect(h.textView.metrics == h.recountedMetrics)
        h.pressReturn()
        #expect(h.spy.sentTexts.first?.utf8Bytes == pasted.utf8Bytes)
    }

    @Test("Emoji and symbols inserted at the caret (emoji picker) are one undoable edit")
    func emojiPickerInsertion() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("ab")
        await h.endEvent()
        h.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(h.controller.insertAtCaret("👨‍👩‍👧"))
        #expect(h.text == "a👨‍👩‍👧b")
        #expect(h.textView.selectedRange() == NSRange(location: 1 + ("👨‍👩‍👧" as NSString).length, length: 0))
        await h.endEvent()
        h.undoManager.undo()
        #expect(h.text == "ab")
    }

    @Test("Emoji insertion during composition commits the composition first")
    func emojiDuringComposition() {
        let h = ComposerHarness()
        defer { h.close() }
        h.setMarked("にほ")
        h.controller.insertAtCaret("😀")
        #expect(h.text == "にほ😀")
        #expect(!h.textView.hasMarkedText())
    }
}
