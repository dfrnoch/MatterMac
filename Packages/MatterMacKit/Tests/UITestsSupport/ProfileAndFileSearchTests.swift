import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor @Suite("Profile editor and file search", .serialized)
struct ProfileAndFileSearchTests {
    @Test func detachingSessionClearsRetainedProfilePopover() async throws {
        let h = try await SettingsAndAttentionTests.Harness()
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        defer { window.close() }
        let anchor = try #require(window.contentView)
        let popover = try #require(ProfilePopover.show(session: h.model, lookup: .id(CoreFixtures.me.id),
                                          relativeTo: NSRect(x: 10, y: 10, width: 20, height: 20), of: anchor))
        #expect(popover.contentViewController != nil)
        h.model.detach()
        #expect(!popover.isShown)
        #expect(popover.contentViewController == nil)
        #expect(ProfilePopover.show(session: h.model, lookup: .id(CoreFixtures.me.id),
                                    relativeTo: .zero, of: anchor) == nil)
        popover.close()
        await h.close()
    }

    @Test func hostsProfileEditorAndDisplaysFileResultsWithoutShowingWindow() async throws {
        let h = try await SettingsAndAttentionTests.Harness()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: ProfileSettingsView(session: h.model).frame(width: 540, height: 560))
        for _ in 0..<30 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(h.service.calls.contains("userStatus"))
        #expect(window.contentView?.bounds.width == 540)
        let channel = h.channel.id
        h.service.withProfile { state in
            state.files = [FileInfo(id: FileID(unchecked: CoreFixtures.id("file", 1)), channelID: channel,
                                    name: "report.txt", size: 1024)]
        }
        h.model.runFileSearch("report")
        window.contentViewController = NSHostingController(rootView: SearchPane(session: h.model))
        for _ in 0..<50 {
            window.contentView?.layoutSubtreeIfNeeded()
            if h.model.search?.files.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(h.model.search?.files.count == 1)
        #expect(h.model.search?.kind == .files)
        let sheet = try #require(ProfileEditSheet.present(session: h.model, on: window))
        for _ in 0..<10 {
            sheet.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.attachedSheet === sheet)
        await h.close()
        for _ in 0..<50 {
            sheet.contentView?.layoutSubtreeIfNeeded()
            if window.attachedSheet == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.attachedSheet == nil)
    }
    @Test func removingFileClosesRetainedViewerAndReleasesDisplayedImage() async throws {
        let h = try await SettingsAndAttentionTests.Harness()
        ImageViewerWindowController.isPresentationSuppressedForTesting = true
        defer { ImageViewerWindowController.isPresentationSuppressedForTesting = false }
        let png = CoreFixtures.png(width: 32, height: 32)
        h.service.withState { $0.imageHandler = { _, _ in png } }
        let first = FileInfo(id: FileID(unchecked: CoreFixtures.id("file", 1)), channelID: h.channel.id,
                             name: "preview.png", mimeType: "image/png")
        let second = FileInfo(id: FileID(unchecked: CoreFixtures.id("file", 2)), channelID: h.channel.id,
                              name: "other.txt")
        let actions = FileSearchActions()
        actions.preview(first, session: h.model)
        let viewer = try #require(actions.viewer)
        for _ in 0..<100 {
            if viewer.lease != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewer.lease != nil)
        actions.retainFiles([first.id, second.id])
        #expect(actions.viewer === viewer)
        actions.retainFiles([second.id])
        #expect(actions.viewer == nil)
        #expect(viewer.lease == nil)
        #expect(viewer.imageView.image == nil)
        await h.close()
    }

}
