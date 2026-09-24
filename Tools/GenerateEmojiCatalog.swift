// MatterMac system-emoji table generator; MIT licensed with the project.
// Development tool only (never linked into the app, never run at app runtime):
//
//   swift Tools/GenerateEmojiCatalog.swift <emoji.json> <emoji_data.go> <output.swift>
//
// Inputs are pinned and verified by SHA-256 before anything is written (see
// docs/assets.md for download commands, provenance, and licenses):
//   - emoji-datasource 6.1.1 `emoji.json` (MIT, iamcal/emoji-data): glyph code
//     points, categories, picker order, and skin-tone variations.
//   - Mattermost v11.11.1 `server/public/model/emoji_data.go` (Apache-2.0):
//     the authoritative `SystemEmojis` short-name → code point map that the server
//     uses to accept reactions. Every name in it (except the image-only
//     `mattermost` emoji) must appear in the output, and nothing else may.
//
// Output: one packed string literal parsed lazily once by `EmojiCatalog`.
import CryptoKit
import Foundation

let emojiJSONSHA256 = "6e7ebffed46cc813a7e47191eaabe9c4efb39e66b731d72e21e3e8134eb8296e"
let emojiDataGoSHA256 = "f643f1a2edcadb04b980cd4b987c75362efde54caab2ccbf32a9048d6c8f2b4c"

/// Category keys (Mattermost's normalized names) in Mattermost picker order.
let categories: [(source: String, key: String)] = [
    ("Smileys & Emotion", "smileys-emotion"), ("People & Body", "people-body"),
    ("Animals & Nature", "animals-nature"), ("Food & Drink", "food-drink"), ("Activities", "activities"),
    ("Travel & Places", "travel-places"), ("Objects", "objects"), ("Symbols", "symbols"), ("Flags", "flags"),
    ("Component", "component"),
]
/// Skin-tone modifier → digit used in the packed table (and the Mattermost suffix).
let skinDigits: [String: Character] = ["1F3FB": "1", "1F3FC": "2", "1F3FD": "3", "1F3FE": "4", "1F3FF": "5"]
let skinSuffixes: [Character: String] = [
    "1": "light_skin_tone", "2": "medium_light_skin_tone", "3": "medium_skin_tone",
    "4": "medium_dark_skin_tone", "5": "dark_skin_tone",
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func verified(_ path: String, sha256 expected: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == expected else { fail("\(path): SHA-256 \(digest) does not match pinned \(expected)") }
    return data
}

func glyph(_ unified: String) -> String {
    var scalars = String.UnicodeScalarView()
    for part in unified.split(separator: "-") {
        guard let value = UInt32(part, radix: 16), let scalar = Unicode.Scalar(value) else { fail("bad code \(unified)") }
        scalars.append(scalar)
    }
    return String(scalars)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: swift Tools/GenerateEmojiCatalog.swift <emoji.json> <emoji_data.go> <output.swift>")
}
let jsonData = verified(CommandLine.arguments[1], sha256: emojiJSONSHA256)
let goData = verified(CommandLine.arguments[2], sha256: emojiDataGoSHA256)

// MARK: - Mattermost SystemEmojis (name → lowercase unified), in file order

guard let goText = String(data: goData, encoding: .utf8) else { fail("emoji_data.go is not UTF-8") }
let entryPattern = try NSRegularExpression(pattern: #"^\s*"([^"]+)":\s*"([^"]*)",\s*$"#, options: .anchorsMatchLines)
var systemNames: [String: String] = [:]
var namesByCode: [String: [String]] = [:]
for match in entryPattern.matches(in: goText, range: NSRange(goText.startIndex..., in: goText)) {
    let name = String(goText[Range(match.range(at: 1), in: goText)!])
    let code = String(goText[Range(match.range(at: 2), in: goText)!]).lowercased()
    guard systemNames.updateValue(code, forKey: name) == nil else { fail("duplicate name \(name)") }
    namesByCode[code, default: []].append(name)
}
guard systemNames.count > 4000 else { fail("parsed only \(systemNames.count) SystemEmojis entries") }
let imageOnly: Set = ["mattermost"] // Mattermost's built-in image emoji; no Unicode form.
for name in imageOnly { guard systemNames[name] == name else { fail("expected image-only \(name)") } }

// MARK: - emoji-datasource

struct Source {
    let unified: String
    let shortName: String
    let category: String
    let sortOrder: Int
    let skins: [(key: String, unified: String)]
}
guard let rawEntries = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
    fail("emoji.json is not an array of objects")
}
let sources: [Source] = rawEntries.map { entry in
    guard let unified = entry["unified"] as? String, let shortName = entry["short_name"] as? String,
          let category = entry["category"] as? String, let sortOrder = entry["sort_order"] as? Int else {
        fail("emoji.json entry is missing unified/short_name/category/sort_order")
    }
    let variations = (entry["skin_variations"] as? [String: [String: Any]]) ?? [:]
    let skins = variations.map { key, value -> (key: String, unified: String) in
        guard let code = value["unified"] as? String else { fail("skin variation without unified") }
        return (key, code)
    }.sorted { $0.key < $1.key }
    return Source(unified: unified, shortName: shortName, category: category, sortOrder: sortOrder, skins: skins)
}
let knownCategories = Set(categories.map(\.source))
for source in sources where !knownCategories.contains(source.category) { fail("unknown category \(source.category)") }

// MARK: - Packed table

var lines: [String] = []
var emitted = Set<String>()
var skinRecords = 0, explicitSkinRecords = 0, baseRecords = 0

func take(_ names: [String]) {
    for name in names {
        guard systemNames[name] != nil, emitted.insert(name).inserted else { fail("name \(name) emitted twice") }
        guard !name.contains(" "), !name.contains("\t"), !name.contains("=") else { fail("unpackable name \(name)") }
    }
}

for (sourceCategory, key) in categories {
    lines.append("@" + key)
    for source in sources.filter({ $0.category == sourceCategory }).sorted(by: { $0.sortOrder < $1.sortOrder }) {
        let code = source.unified.lowercased()
        guard let group = namesByCode[code], group.contains(source.shortName) else {
            fail("\(source.shortName) (\(code)) is not a Mattermost system emoji")
        }
        // Primary (the name Mattermost clients send for reactions) first, then aliases.
        let names = [source.shortName] + group.filter { $0 != source.shortName }
        let base = glyph(source.unified)
        guard let first = base.unicodeScalars.first, first != "@", first != "~" else { fail("glyph collides with marker") }
        take(names)
        lines.append(base + "\t" + names.joined(separator: " "))
        baseRecords += 1
        for skin in source.skins {
            let skinCode = skin.unified.lowercased()
            guard let actual = namesByCode[skinCode] else { fail("skin variant \(skinCode) missing from SystemEmojis") }
            let digits = String(skin.key.split(separator: "-").map { part -> Character in
                guard let digit = skinDigits[String(part)] else { fail("unknown skin modifier \(part)") }
                return digit
            })
            let suffix = digits.map { skinSuffixes[$0]! }.joined(separator: "_")
            let derived = names.map { $0 + "_" + suffix }
            take(actual)
            if Set(derived) == Set(actual) {
                lines.append("~" + glyph(skin.unified) + "\t" + digits)
            } else {
                // Some aliases were added after Mattermost derived skin names; list exactly.
                let ordered = derived.filter(actual.contains) + actual.filter { !derived.contains($0) }
                lines.append("~" + glyph(skin.unified) + "\t=" + ordered.joined(separator: " "))
                explicitSkinRecords += 1
            }
            skinRecords += 1
        }
    }
}

let missing = Set(systemNames.keys).subtracting(emitted).subtracting(imageOnly)
guard missing.isEmpty else { fail("SystemEmojis names not covered: \(missing.sorted().prefix(20))") }
let packed = lines.joined(separator: "\n")
guard !packed.contains("\"\"\"#"), !packed.contains("\r") else { fail("packed text would break the literal") }

let output = """
// GENERATED by Tools/GenerateEmojiCatalog.swift — do not edit by hand.
// Sources (verified by SHA-256; see docs/assets.md):
//   emoji-datasource 6.1.1 emoji.json (MIT) \(emojiJSONSHA256)
//   Mattermost v11.11.1 server/public/model/emoji_data.go (Apache-2.0) \(emojiDataGoSHA256)
// \(baseRecords) emoji, \(skinRecords) skin-tone variants, \(emitted.count) short names.
//
// Format, one record per line:
//   @<category>              starts a category (picker order)
//   <glyph>\\t<name> <name>…  an emoji; the first name is the primary short name
//   ~<glyph>\\t<digits>       skin-tone variant of the preceding emoji: each of its
//                            names + "_" + the tones for digits 1…5 joined by "_"
//                            (1 light … 5 dark, e.g. "13" = light_skin_tone_medium_skin_tone)
//   ~<glyph>\\t=<name> <name>… skin-tone variant with explicitly listed names

extension EmojiCatalog {
    static let packedSystemEmoji: StaticString = #\"\"\"
\(packed)
\"\"\"#
}

"""
try Data(output.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
print("wrote \(baseRecords) emoji, \(skinRecords) skin-tone variants (\(explicitSkinRecords) explicit), "
      + "\(emitted.count) names, \(packed.utf8.count) packed bytes")
