import Testing
import MatterMacModels

@Test func safeMarkupPreservesFallbackAndRefusesActiveLinks() {
    let text = "**Hello** <script>alert(1)</script> [bad](javascript:alert)"
    let parsed = MarkupParser.parse(text)
    #expect(parsed.plainText.contains("Hello"))
    #expect(parsed.plainText.contains("<script>"))
    #expect(SafeLink("javascript:alert(1)") == nil)
    #expect(SafeLink("https://user:password@example.org") == nil)
    #expect(SafeLink("https://example.org/help") != nil)
    var limits = MarkupLimits.standard
    limits.maximumInputCharacters = 4
    let limited = MarkupParser.parse(text, limits: limits)
    #expect(limited.hitLimits)
    #expect(limited.plainText == text)
}

@Test func taskListsAndTableAlignmentSurviveParsing() throws {
    let tasks = MarkupParser.parse("- [x] done\n- [ ] todo")
    guard case .list(let list) = try #require(tasks.blocks.first) else {
        Issue.record("Expected list"); return
    }
    #expect(list.items.map(\.task) == [.done, .open])
    #expect(tasks.plainText.contains("[x] done"))
    let parsed = MarkupParser.parse("| left | center | right |\n| :--- | :---: | ---: |\n| **bold** | x | 1 | extra |")
    guard case .table(let table) = try #require(parsed.blocks.first) else {
        Issue.record("Expected table"); return
    }
    #expect(table.alignments == [.left, .center, .right])
    #expect(table.rows.first?.count == 3)
    #expect(table.rows.first?.first == [.strong([.text("bold")])])
    #expect(MarkupAttachment.Accent("#abc") == .rgb(0xAABBCC))
    #expect(MarkupAttachment.Accent("bad-color") == .none)
    let attachment = MarkupAttachment(imageLink: SafeLink("https://example.org/image"), hasUnsupportedActions: true)
    let plain = MessageDocument(blocks: [.attachment(attachment)]).plainText
    #expect(plain.contains("https://example.org/image"))
    #expect(plain.contains("Interactive buttons"))
}
