import AppKit
import MatterMacCore
import MatterMacModels
import Testing
@testable import MatterMacUI

@MainActor
@Suite("Composer budgets, paste, and undo")
struct ComposerBudgetTests {
    // MARK: Paste

    @Test("Paste over the per-paste limit is refused before insertion; text unchanged")
    func pasteOverLimitRefused() {
        var budget = ResourceBudget()
        budget.maximumPasteBytes = 1_024
        let h = ComposerHarness(budget: budget)
        defer { h.close() }
        h.type("keep me")
        let pasteboard = ComposerHarness.privatePasteboard()
        pasteboard.setString(String(repeating: "ž", count: 600), forType: .string)  // 1,200 UTF-8 bytes

        #expect(!h.textView.readSelection(from: pasteboard))

        #expect(h.text == "keep me")
        #expect(h.spy.refusals == [.pasteTooLarge(limit: 1_024)])
        #expect(h.controller.notice != nil, "the refusal is explained inline")
        #expect(h.textView.metrics == h.recountedMetrics)
    }

    @Test("Paste exactly at the per-paste limit is accepted")
    func pasteAtLimitAccepted() {
        var budget = ResourceBudget()
        budget.maximumPasteBytes = 1_024
        let h = ComposerHarness(budget: budget)
        defer { h.close() }
        let pasteboard = ComposerHarness.privatePasteboard()
        let exact = String(repeating: "ab", count: 512)
        pasteboard.setString(exact, forType: .string)
        #expect(h.textView.readSelection(from: pasteboard))
        #expect(h.text == exact)
        #expect(h.spy.refusals.isEmpty)
    }

    @Test("Paste that would exceed the remaining draft budget is refused; replacing a selection counts net growth")
    func pasteOverDraftBudget() {
        let h = ComposerHarness()
        defer { h.close() }
        h.spy.draftBudgetBytes = 20
        h.type("0123456789")  // 10 bytes, 10 remaining
        let pasteboard = ComposerHarness.privatePasteboard()
        pasteboard.setString("ABCDEFGHIJKL", forType: .string)  // +12 > 10

        #expect(!h.textView.readSelection(from: pasteboard))
        #expect(h.text == "0123456789")
        #expect(h.spy.refusals == [.draftBudgetExceeded(limit: 10)])

        // Replacing 5 selected bytes with 12 grows by 7 ≤ 10: accepted.
        h.textView.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(h.textView.readSelection(from: pasteboard))
        #expect(h.text == "ABCDEFGHIJKL56789")
        #expect(h.controller.draftByteCount == 17)
    }

    @Test("Pasted image data goes to the host undecoded; text unchanged")
    func pasteImage() {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("caption")
        let pasteboard = ComposerHarness.privatePasteboard()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        pasteboard.setData(bytes, forType: .png)
        #expect(h.textView.readSelection(from: pasteboard))
        #expect(h.spy.images.count == 1)
        #expect(h.spy.images.first?.data == bytes)
        #expect(h.spy.images.first?.type == "public.png")
        #expect(h.text == "caption")
    }

    @Test("Text is preferred over a picture of the same text (Office-style pasteboards)")
    func textPreferredOverImage() {
        let h = ComposerHarness()
        defer { h.close() }
        let pasteboard = ComposerHarness.privatePasteboard()
        pasteboard.declareTypes([.string, .tiff], owner: nil)
        pasteboard.setString("cell text", forType: .string)
        pasteboard.setData(Data([0x4D, 0x4D, 0, 42]), forType: .tiff)
        #expect(h.textView.readSelection(from: pasteboard))
        #expect(h.text == "cell text")
        #expect(h.spy.images.isEmpty)
    }

    @Test("Pasted file URLs go to the host (and win over their name/icon representations)")
    func pasteFiles() throws {
        let h = ComposerHarness()
        defer { h.close() }
        let pasteboard = ComposerHarness.privatePasteboard()
        let urls = [URL(fileURLWithPath: "/tmp/mattermac-composer-a.txt"), URL(fileURLWithPath: "/tmp/b c.pdf")]
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.addTypes([.string], owner: nil)
        pasteboard.setString("a.txt", forType: .string)
        #expect(h.textView.readSelection(from: pasteboard))
        #expect(h.spy.fileBatches == [urls])
        #expect(h.text.isEmpty)
    }

    @Test("Too many files in one paste are refused")
    func tooManyFiles() {
        let h = ComposerHarness()
        defer { h.close() }
        let pasteboard = ComposerHarness.privatePasteboard()
        let count = ComposerTextView.maximumFilesPerInput + 1
        pasteboard.writeObjects((0..<count).map { URL(fileURLWithPath: "/tmp/f\($0)") as NSURL })
        #expect(!h.textView.readSelection(from: pasteboard))
        #expect(h.spy.fileBatches.isEmpty)
        #expect(h.spy.refusals == [.tooManyFiles(limit: ComposerTextView.maximumFilesPerInput)])
    }

    @Test("Readable and drag types are limited to plain text, file URLs, PNG, TIFF")
    func acceptedTypes() {
        let h = ComposerHarness()
        defer { h.close() }
        #expect(h.textView.readablePasteboardTypes == [.fileURL, .string, .png, .tiff])
        #expect(h.textView.acceptableDragTypes == [.fileURL, .string, .png, .tiff])
        let rtfOnly = ComposerHarness.privatePasteboard()
        let rtf = try? NSAttributedString(string: "RICH").data(
            from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        rtfOnly.setData(rtf, forType: .rtf)
        // The pasteboard offers a plain-text translation; only plain text arrives.
        #expect(h.textView.readSelection(from: rtfOnly))
        #expect(h.text == "RICH")
        #expect(h.textView.textStorage?.attributes(at: 0, effectiveRange: nil)[.link] == nil)
    }

    // MARK: Typing budget

    @Test("Typing past the remaining draft budget is refused; deleting then typing works")
    func typingOverBudget() {
        let h = ComposerHarness()
        defer { h.close() }
        h.spy.draftBudgetBytes = 8
        for character in "12345678" { h.type(String(character)) }
        h.type("9")
        #expect(h.text == "12345678")
        #expect(h.spy.refusals == [.draftBudgetExceeded(limit: 0)])
        h.textView.deleteBackward(nil)
        h.type("x")
        #expect(h.text == "1234567x")
        h.type("č")  // two bytes, zero available
        #expect(h.text == "1234567x")
        #expect(h.spy.refusals.count == 2)
    }

    @Test("Multi-byte characters are budgeted in UTF-8 bytes")
    func multiByteBudget() {
        let h = ComposerHarness()
        defer { h.close() }
        h.spy.draftBudgetBytes = 7
        h.type("ř")      // 2
        h.type("日")     // 3 → 5
        h.type("😀")     // 4 → 9 > 7: refused
        h.type("ů")      // 2 → 7
        #expect(h.text == "ř日ů")
        #expect(h.controller.draftByteCount == 7)
        #expect(h.spy.refusals == [.draftBudgetExceeded(limit: 2)])
    }

    @Test("Composition churn is allowed; the commit is enforced and a refused commit leaves no residue")
    func compositionBudget() {
        let h = ComposerHarness()
        defer { h.close() }
        h.spy.draftBudgetBytes = 8
        h.type("ab")  // 2 bytes, 6 available
        h.setMarked("にほんご")  // 12 bytes of marked text: allowed while composing
        h.setMarked("日本語")    // 9 bytes
        #expect(h.textView.hasMarkedText())
        #expect(h.spy.refusals.isEmpty)

        h.textView.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(h.text == "ab", "refused commit removes the composition instead of committing it")
        #expect(!h.textView.hasMarkedText())
        #expect(h.spy.refusals == [.draftBudgetExceeded(limit: 0)])
        #expect(h.textView.metrics == h.recountedMetrics)

        // A commit that fits is accepted.
        h.setMarked("にほ")
        h.textView.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.text == "ab日本")
        #expect(h.controller.draftByteCount == 8)
    }

    @Test("unmarkText over budget: the composition is not committed")
    func unmarkOverBudget() {
        let h = ComposerHarness()
        defer { h.close() }
        h.spy.draftBudgetBytes = 4
        h.setMarked("zhongwen")
        h.setMarked("中文")  // 6 bytes > 4
        h.textView.unmarkText()
        #expect(h.text.isEmpty)
        #expect(h.spy.refusals.count == 1)
        #expect(h.textView.metrics == h.recountedMetrics)
    }

    @Test("Load, clear, and undo are never refused by the budget")
    func programmaticNotRefused() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.spy.draftBudgetBytes = 3
        h.controller.load(draft: Draft(text: "longer than three"))
        #expect(h.text == "longer than three")
        #expect(h.spy.refusals.isEmpty)
        h.controller.clear()
        h.type("abc")
        await h.endEvent()
        h.textView.selectAll(nil)
        h.textView.deleteBackward(nil)
        await h.endEvent()
        h.undoManager.undo()
        #expect(h.text == "abc")
        #expect(h.spy.refusals.isEmpty)
    }

    // MARK: Undo

    @Test("Undo levels are capped by the budget")
    func undoLevelsCapped() async {
        var budget = ResourceBudget()
        budget.composerUndoLevels = 3
        let h = ComposerHarness(budget: budget)
        defer { h.close() }
        #expect(h.undoManager.levelsOfUndo == 3)
        for word in ["one ", "two ", "three ", "four ", "five "] {
            h.type(word)
            await h.endEvent()
        }
        #expect(h.undoCount() == 3)
        #expect(h.text == "one two ")
    }

    @Test("clearUndoHistory drops undo and redo")
    func clearUndoHistory() async {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("abc")
        await h.endEvent()
        h.type("def")
        await h.endEvent()
        h.undoManager.undo()
        #expect(h.undoManager.canRedo)
        h.controller.clearUndoHistory()
        #expect(!h.undoManager.canUndo)
        #expect(!h.undoManager.canRedo)
        #expect(h.textView.undoRetainedBytesEstimate == 0)
        h.type("x")  // typing after clearing is undoable again (coalescing was broken)
        await h.endEvent()
        #expect(h.undoManager.canUndo)
    }

    @Test("Undo retains at most the byte cap; the latest large edit stays undoable")
    func undoByteCap() async {
        var budget = ResourceBudget()
        budget.unsentText = .init(count: 100, bytes: 64)  // undo byte cap derives from this
        let h = ComposerHarness(budget: budget)
        defer { h.close() }
        #expect(h.textView.undoByteLimit == 64)
        h.type(String(repeating: "a", count: 30))
        await h.endEvent()
        h.type(String(repeating: "b", count: 30))
        await h.endEvent()
        #expect(h.textView.undoRetainedBytesEstimate == 60)
        let pasteboard = ComposerHarness.privatePasteboard()
        pasteboard.setString(String(repeating: "c", count: 40), forType: .string)
        #expect(h.textView.readSelection(from: pasteboard))
        await h.endEvent()
        #expect(h.textView.undoRetainedBytesEstimate == 40, "older history dropped before the paste registered")
        #expect(h.undoCount() == 1)
        #expect(h.text == String(repeating: "a", count: 30) + String(repeating: "b", count: 30))
    }

    @Test("Incremental metrics match a full recount across edits, undo, redo, and composition")
    func metricsStayExact() async {
        let h = ComposerHarness()
        defer { h.close() }
        let recountsBefore = h.textView.metricsRecountCount
        h.type("Příliš žluťoučký kůň 🐴 ")
        await h.endEvent()
        h.setMarked("ni")
        h.setMarked("你")
        h.textView.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        await h.endEvent()
        h.textView.setSelectedRange(NSRange(location: 2, length: 5))
        h.textView.deleteBackward(nil)
        await h.endEvent()
        h.command(#selector(NSResponder.deleteWordBackward(_:)))
        await h.endEvent()
        h.undoManager.undo()
        h.undoManager.undo()
        h.undoManager.redo()
        h.textView.insertAtCaret("e\u{301}")
        #expect(h.textView.metrics == h.recountedMetrics)
        #expect(h.textView.metricsRecountCount == recountsBefore, "no drift fallback needed")
    }
}
