import AppKit
import Testing
@testable import MatterMacUI

@MainActor
@Suite("Title bar backing")
struct TitlebarBackingTests {
    /// SwiftUI makes the title bar transparent when it hides its toolbar background,
    /// which switches AppKit's scroll edge backing off behind the toolbar.
    @Test func guardKeepsTheTitleBarOpaqueWhileItIsInTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        let view = TitlebarBackingGuard.GuardView()
        window.contentView?.addSubview(view)
        #expect(!window.titlebarAppearsTransparent)
        window.titlebarAppearsTransparent = true
        #expect(!window.titlebarAppearsTransparent)
        view.removeFromSuperview()
        window.titlebarAppearsTransparent = true
        #expect(window.titlebarAppearsTransparent)
    }
}
