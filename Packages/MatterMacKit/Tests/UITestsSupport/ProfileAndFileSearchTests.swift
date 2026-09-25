import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor @Suite("Profile editor and file search", .serialized)
struct ProfileAndFileSearchTests {
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
}
