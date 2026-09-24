import Foundation
import Testing
import MatterMacModels

@Suite("System emoji catalog")
struct EmojiCatalogTests {
    let catalog = EmojiCatalog.system

    @Test func coversMattermostSystemEmojiNames() {
        // Mattermost v11.11.1 SystemEmojis has 4,464 names; `mattermost` is image-only.
        #expect(catalog.nameCount == 4463)
        #expect(catalog.all.count == 1810 + 1490)
        #expect(catalog.all.filter(\.isSkinToneVariant).count == 1490)
        #expect(catalog.glyph(for: "mattermost") == nil)
    }

    @Test func resolvesCommonNamesAndAliases() {
        #expect(catalog.glyph(for: "+1") == "👍")
        #expect(catalog.glyph(for: "thumbsup") == "👍")
        #expect(catalog.glyph(for: "-1") == "👎")
        #expect(catalog.glyph(for: "smile") == "😄")
        #expect(catalog.glyph(for: "joy") == "😂")
        #expect(catalog.glyph(for: "tada") == "🎉")
        #expect(catalog.glyph(for: "white_check_mark") == "✅")
        #expect(catalog.glyph(for: "heart") == "\u{2764}\u{FE0F}")
        #expect(catalog.glyph(for: "eyes") == "👀")
        #expect(catalog.glyph(for: "satisfied") == catalog.glyph(for: "laughing"))
        // Primary name first: what Mattermost clients send for reactions.
        #expect(catalog.emoji(named: "thumbsup")?.name == "+1")
        #expect(catalog.emoji(named: "thumbsup")?.names == ["+1", "thumbsup"])
        #expect(catalog.emoji(named: "smile")?.category == .smileysEmotion)
        #expect(catalog.emoji(named: "flag-cz")?.category == .flags)
    }

    @Test func resolvesSkinToneVariants() {
        #expect(catalog.glyph(for: "+1_medium_skin_tone") == "👍🏽")
        #expect(catalog.glyph(for: "thumbsup_dark_skin_tone") == "👍🏿")
        #expect(catalog.emoji(named: "thumbsup_light_skin_tone")?.name == "+1_light_skin_tone")
        #expect(catalog.emoji(named: "+1_light_skin_tone")?.isSkinToneVariant == true)
        // Explicitly listed variant names (an alias added after skin derivation).
        #expect(catalog.glyph(for: "middle_finger_light_skin_tone") == "🖕🏻")
        #expect(catalog.glyph(for: "fu_light_skin_tone") == nil)
        #expect(catalog.glyph(for: "fu") == "🖕")
    }

    @Test func unknownNamesStayUnresolved() {
        #expect(catalog.glyph(for: "party_parrot") == nil)
        #expect(catalog.glyph(for: "") == nil)
        #expect(catalog.glyph(for: String(repeating: "a", count: 500)) == nil)
        #expect(catalog.glyph(for: "SMILE") == "😄") // v10 servers keep reaction case
    }

    @Test func searchRanksExactThenPrefixThenSubstring() {
        let heart = catalog.search("heart", limit: 20)
        #expect(heart.first?.matchedName == "heart")
        let ranks = heart.map { $0.matchedName == "heart" ? 0 : ($0.matchedName.hasPrefix("heart") ? 1 : 2) }
        #expect(ranks == ranks.sorted())
        let smi = catalog.search("smi", limit: 8)
        #expect(smi.count == 8)
        #expect(smi.allSatisfy { $0.matchedName.hasPrefix("smi") })
        #expect(smi.map(\.matchedName) == smi.map(\.matchedName).sorted())
        #expect(catalog.search(":tada:", limit: 8).first?.emoji.name == "tada")
        #expect(catalog.search("THUMBS", limit: 8).map(\.matchedName) == ["thumbsdown", "thumbsup"])
        // One result per emoji even when several aliases match.
        let ids = catalog.search("a", limit: 256).map(\.emoji.name)
        #expect(Set(ids).count == ids.count)
    }

    @Test func searchIsBounded() {
        #expect(catalog.search("a", limit: 8).count == 8)
        #expect(catalog.search("a", limit: 100_000).count == EmojiCatalog.maximumSearchResults)
        #expect(catalog.search("a", limit: 0).isEmpty)
        #expect(catalog.search("a", limit: -3).isEmpty)
        #expect(catalog.search("", limit: 8).isEmpty)
        #expect(catalog.search("::", limit: 8).isEmpty)
        #expect(catalog.search(String(repeating: "a", count: 81), limit: 8).isEmpty)
        #expect(catalog.search("zzzzqqq", limit: 8).isEmpty)
    }

    @Test func skinTonesOnlyWhenAsked() {
        #expect(catalog.search("+1", limit: 20).allSatisfy { !$0.emoji.isSkinToneVariant })
        #expect(catalog.search("+1_medium_skin", limit: 20).first?.emoji.glyph == "👍🏽")
        #expect(catalog.search("+1", limit: 20, includingSkinTones: true).contains { $0.emoji.isSkinToneVariant })
    }

    @Test func pickerDataIsValidForReactions() {
        for name in EmojiCatalog.defaultQuickReactions {
            #expect(catalog.emoji(named: name)?.name == name)
        }
        for category in EmojiCategory.allCases where category.isShownInPicker {
            let emoji = catalog.pickerEmoji(in: category)
            #expect(!emoji.isEmpty)
            #expect(emoji.allSatisfy { !$0.isSkinToneVariant && Reaction.isValidEmojiName($0.name) })
        }
        #expect(catalog.pickerEmoji(in: .smileysEmotion).first?.name == "grinning")
    }

    @Test func everyNameIsAWellFormedShortName() {
        // The inline parser recognises `[A-Za-z0-9_+-]{1,80}` between colons.
        for emoji in catalog.all {
            for name in emoji.names {
                #expect(name.utf8.count <= 80 && name.utf8.allSatisfy { byte in
                    (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F || byte == 0x2D || byte == 0x2B
                }, "\(name)")
            }
            #expect(!emoji.glyph.isEmpty)
        }
    }
}
