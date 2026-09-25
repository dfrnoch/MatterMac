import AppKit
import Testing
import MatterMacPlatform

@MainActor
@Suite("Session-only split geometry", .serialized)
struct SplitViewPersistenceTests {
    @Test func initialAndDynamicallyReplacedSplitsDoNotAutosave() {
        let guardObject = SplitViewPersistenceGuard()
        withExtendedLifetime(guardObject) {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            for _ in 0..<3 {
                host.subviews.forEach { $0.removeFromSuperview() }
                let split = NSSplitView(frame: host.bounds)
                split.isVertical = true
                host.addSubview(split)
                split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600)))
                split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600)))
                // A fresh fixture identity cannot restore a developer's saved split.
                split.autosaveName = "MatterMacFixture-" + UUID().uuidString
                split.setPosition(240, ofDividerAt: 0)
                #expect(split.autosaveName == nil)
                split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600)))
                split.autosaveName = "MatterMacFixture-" + UUID().uuidString
                split.setPosition(280, ofDividerAt: 0)
                #expect(split.autosaveName == nil)
                split.setPosition(240, ofDividerAt: 0)
                #expect(split.autosaveName == nil)
            }
        }
    }
}
