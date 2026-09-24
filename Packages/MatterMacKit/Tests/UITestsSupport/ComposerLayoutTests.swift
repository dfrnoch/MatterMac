import AppKit
import Testing
@testable import MatterMacUI

@MainActor
@Suite("Composer layout")
struct ComposerLayoutTests {
    private func frames(_ h: ComposerHarness) throws -> (box: NSRect, attach: NSRect, send: NSRect) {
        h.controller.view.layoutSubtreeIfNeeded()
        let row = try #require(h.controller.attachButton.superview)
        let box = try #require(row.subviews.first { $0 is NSBox })
        func inWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        return (inWindow(box), inWindow(h.controller.attachButton), inWindow(h.controller.sendButton))
    }

    @Test func attachAndSendButtonsAlignWithTheTextField() throws {
        let h = ComposerHarness()
        defer { h.close() }
        let single = try frames(h)
        // One line: both buttons are vertically centered on the input box.
        #expect(abs(single.attach.midY - single.box.midY) <= 0.5, "attach \(single.attach) box \(single.box)")
        #expect(abs(single.send.midY - single.box.midY) <= 0.5, "send \(single.send) box \(single.box)")
        let centerAboveBottom = single.box.midY - single.box.minY

        // Several lines: the box grows upward and the buttons stay beside the last line.
        h.type("one\ntwo\nthree\nfour")
        let multi = try frames(h)
        #expect(multi.box.height > single.box.height + 20)
        for button in [multi.attach, multi.send] {
            #expect(abs(button.midY - (multi.box.minY + centerAboveBottom)) <= 0.5, "button \(button) box \(multi.box)")
        }
    }
}
