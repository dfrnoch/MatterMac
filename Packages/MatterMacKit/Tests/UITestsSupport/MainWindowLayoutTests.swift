import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor @Suite("Main window layout", .serialized)
struct MainWindowLayoutTests {
    @Test(arguments: [760.0, 976.0, 1000.0, 1100.0])
    func searchFitsContent(width: Double) async throws {
        let h = try await SettingsAndAttentionTests.Harness()
        var post = CoreFixtures.post(1, channel: h.channel.id, user: CoreFixtures.bob.id)
        post.message = "release " + String(repeating: "readable message content ", count: 20)
        h.service.withState { [post] in $0.posts[post.id] = post }
        h.model.select(channel: h.channel.id)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        defer { window.close() }
        let host = NSHostingController(rootView: MainWindowView(app: h.app, session: h.model).frame(minWidth: 760, minHeight: 500))
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 640))
        for _ in 0..<60 {
            host.view.layoutSubtreeIfNeeded()
            if h.model.draftProvider != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let composer = try #require(h.model.draftProvider as? ConversationController)
        let draft = Draft(text: "Unsent while searching", selectedRange: NSRange(location: 2, length: 4))
        composer.composer.load(draft: draft)
        composer.saveDraft()
        h.model.isSearchVisible = true
        h.model.runSearch("release")
        for _ in 0..<60 {
            host.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(h.model.search?.items.count == 1)
        #expect(abs(host.view.bounds.width - width) < 1)
        let splits = descendants(host.view).compactMap { $0 as? NSSplitView }
        #expect(!splits.isEmpty)
        for split in splits {
            let rect = split.convert(split.bounds, to: host.view)
            #expect(rect.minX >= -1 && rect.maxX <= width + 1, "Pane rect: \(rect)")
            for pane in split.arrangedSubviews where !pane.isHidden {
                let rect = pane.convert(pane.bounds, to: host.view)
                #expect(rect.minX >= -1 && rect.maxX <= width + 1, "Pane rect: \(rect)")
                #expect(rect.width >= 180)
            }
        }
        if let directory = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"],
           let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("search-\(Int(width)).png"))
            }
        }
        h.model.isSearchVisible = false
        for _ in 0..<60 {
            host.view.layoutSubtreeIfNeeded()
            if h.model.draftProvider != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = try #require(h.model.draftProvider as? ConversationController)
        #expect(restored.composer.currentDraft() == draft)
        await h.close()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
