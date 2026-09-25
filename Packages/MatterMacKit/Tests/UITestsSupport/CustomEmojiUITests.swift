import AppKit
import Testing
import MatterMacModels
import MatterMacCore
@testable import MatterMacUI

@MainActor
@Suite("Custom emoji layout and slash detection")
struct CustomEmojiUITests {
    @Test func slashIsOnlyAtStartAndKeepsArgumentSpaces() {
        func detect(_ text: String) -> CompletionContext? {
            CompletionQueryDetector.detect(in: text as NSString, selection: NSRange(location: (text as NSString).length, length: 0))
        }
        #expect(detect("/")?.trigger == .command)
        #expect(detect("/status a")?.query == "status a")
        #expect(detect(" /status") == nil)
        #expect(detect("hello /status") == nil)
        #expect(detect("/status\naway") == nil)
        #expect(detect("/" + String(repeating: "a", count: 513)) == nil)
    }

    @Test func attachmentGeometryIsStableAndDoesNotLeakToNewlines() throws {
        let renderer = MessageRenderer(emojiLookup: EmojiCatalog.system.glyph(for:))
        let document = MarkupParser.parse(":party_parrot:\n\nnext")
        let text = renderer.render(document, customEmoji: ["party_parrot": "aaaaaaaaaaaaaaaaaaaaaaaaaa"])
        let attachment = try #require(text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width > 0)
        #expect(attachment.bounds.width == attachment.bounds.height)
        #expect(attachment.image == nil)
        #expect(text.attribute(.matterMacCustomEmoji, at: 0, effectiveRange: nil) as? String == "aaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(text.attribute(.attachment, at: 1, effectiveRange: nil) == nil)
        let measurer = TextMeasurer()
        let initial = measurer.height(of: text, width: 180)
        (attachment.attachmentCell as? CustomEmojiAttachmentCell)?.image = NSImage(size: NSSize(width: 256, height: 256))
        #expect(measurer.height(of: text, width: 180) == initial)
    }

    @Test func pickerDeduplicatesPagesAndStopsWhenServerMakesNoProgress() async {
        let picker = ReactionPickerViewController()
        var requests: [Int] = []
        picker.customPage = { page, _ in
            requests.append(page)
            // First page contains duplicates; the next page adds 60 names; a
            // broken server then repeats that second page forever.
            return (0..<60).map { index in
                let number = page == 0 ? index / 2 : index + 30
                return CustomEmoji(id: String(repeating: "a", count: 26), name: "custom_\(number)")
            }
        }
        _ = picker.view
        await picker.customTask?.value
        #expect(requests == [0])
        #expect(picker.sections.last?.emoji.count == 30)
        picker.loadCustomPage()
        await picker.customTask?.value
        #expect(requests == [0, 1])
        #expect(picker.sections.last?.emoji.count == 90)
        picker.loadCustomPage()
        await picker.customTask?.value
        #expect(requests == [0, 1, 2])
        #expect(picker.sections.last?.emoji.count == 90)
        picker.loadCustomPage()
        #expect(picker.customTask == nil)
        #expect(requests == [0, 1, 2])
        picker.viewDidDisappear()
    }

    @Test func pickerLoadsBoundedCustomPageAndSearch() async {
        let picker = ReactionPickerViewController()
        picker.customLimit = 2
        picker.customPage = { _, query in
            (0..<3).map { CustomEmoji(id: String(repeating: "a", count: 26), name: query.isEmpty ? "custom_\($0)" : query + "_\($0)") }
        }
        _ = picker.view
        for _ in 0..<30 where picker.sections.last?.title != "Custom" { await Task.yield() }
        #expect(picker.sections.last?.emoji.count == 2)
        picker.apply(query: "party")
        for _ in 0..<30 where picker.sections.last?.title != "Custom" { await Task.yield() }
        #expect(picker.sections.last?.emoji.first?.name == "party_0")
        picker.viewDidDisappear()
    }
}
