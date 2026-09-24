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
