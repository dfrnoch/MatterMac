import AppKit
import Testing
import MatterMacModels
import MatterMacCore
@testable import MatterMacUI

@MainActor
@Suite("Jumbo emoji")
struct JumboEmojiTests {
    let renderer = MessageRenderer(emojiLookup: EmojiCatalog.system.glyph(for:))

    func fontSize(_ markdown: String, customEmoji: [String: String] = [:]) -> CGFloat? {
        let text = renderer.render(MarkupParser.parse(markdown), customEmoji: customEmoji)
        return (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
    }

    @Test func emojiOnlyMessagesRenderLarge() {
        let jumbo = renderer.jumboEmojiSize
        #expect(jumbo > renderer.fonts.bodySize * 2)
        #expect(fontSize("👍") == jumbo)
        #expect(fontSize("🎉 🎉  ❤️") == jumbo)
        #expect(fontSize(":tada::+1:") == jumbo)
        #expect(fontSize("👨‍👩‍👧 🇨🇿 1️⃣") == jumbo, "ZWJ, flags and keycaps count as one emoji each")
        #expect(fontSize(":party_parrot:", customEmoji: ["party_parrot": String(repeating: "a", count: 26)]) == jumbo)
    }

    @Test func textMixedLongOrUnknownStaysNormal() {
        let body = renderer.fonts.bodySize
        #expect(fontSize("ok 👍") == body)
        #expect(fontSize("1") == body, "digits are emoji-capable but drawn as text")
        #expect(fontSize(":not_an_emoji:") == body)
        #expect(fontSize(String(repeating: "😀", count: MessageRenderer.maximumJumboEmoji + 1)) == body)
        #expect(fontSize("**👍**") == body)
        #expect(fontSize("👍\n\n👍") == body, "two paragraphs")
    }
}
