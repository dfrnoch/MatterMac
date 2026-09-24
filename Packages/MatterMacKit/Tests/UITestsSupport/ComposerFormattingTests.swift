import AppKit
import Testing
@testable import MatterMacUI

@MainActor
@Suite("Composer Markdown formatting")
struct ComposerFormattingTests {
    /// Undo groups by event; let the run loop close each group as real events would.
    private func endEvent() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

    @Test func wrapsTogglesAndUndoes() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("make this bold")
        endEvent()
        h.textView.setSelectedRange(NSRange(location: 10, length: 4))
        h.textView.applyMarkdown(.bold)
        endEvent()
        #expect(h.text == "make this **bold**", "\(h.text)")
        #expect(h.textView.selectedRange() == NSRange(location: 12, length: 4))
        // Applying again removes the markers.
        h.textView.applyMarkdown(.bold)
        #expect(h.text == "make this bold")
        endEvent()
        h.textView.undo(nil)
        #expect(h.text == "make this **bold**", "\(h.text)")
    }

    @Test func emptySelectionLinkQuoteAndCodeBlock() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.textView.applyMarkdown(.italic)
        #expect(h.text == "__")
        #expect(h.textView.selectedRange() == NSRange(location: 1, length: 0))
        h.textView.setSelectedRange(NSRange(location: 0, length: (h.text as NSString).length))
        h.type("docs")
        h.textView.setSelectedRange(NSRange(location: 0, length: 4))
        h.textView.applyMarkdown(.link)
        #expect(h.text == "[docs](url)")
        #expect(h.textView.selectedRange() == NSRange(location: 7, length: 3))
        h.textView.setSelectedRange(NSRange(location: 0, length: (h.text as NSString).length))
        h.type("a\nb")
        h.textView.setSelectedRange(NSRange(location: 0, length: 3))
        h.textView.applyMarkdown(.quote)
        #expect(h.text == "> a\n> b")
        h.textView.setSelectedRange(NSRange(location: 0, length: (h.text as NSString).length))
        h.type("x = 1\ny = 2")
        h.textView.setSelectedRange(NSRange(location: 0, length: 11))
        h.textView.applyMarkdown(.code)
        #expect(h.text == "```\nx = 1\ny = 2\n```")
    }

    @Test func keyEquivalentsMapToStyles() throws {
        func event(_ key: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
        }
        #expect(ComposerTextView.markdownStyle(for: event("b", .command)) == .bold)
        #expect(ComposerTextView.markdownStyle(for: event("x", [.command, .shift])) == .strikethrough)
        #expect(ComposerTextView.markdownStyle(for: event("k", [.command, .option])) == .link)
        #expect(ComposerTextView.markdownStyle(for: event("k", .command)) == nil)
    }
}
