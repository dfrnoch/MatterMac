// Server-uploaded (custom) emoji, available when the server reports
// `EnableCustomEmoji`. Only the identity is kept: the image is fetched on demand
// through the bounded image pipeline (`GET /emoji/{id}/image`) and never stored.

/// One custom emoji (`model.Emoji`: `{id, name, creator_id, …}`).
public struct CustomEmoji: Hashable, Sendable, Identifiable {
    /// Path-safe server id, validated at decode time.
    public let id: String
    /// Lowercase short name, 1–64 characters of `[a-z0-9_+-]`.
    public let name: String
    public let creatorID: UserID?

    public init(id: String, name: String, creatorID: UserID? = nil) {
        self.id = id
        self.name = name.lowercased()
        self.creatorID = creatorID
    }

    /// Server limit for custom emoji names (`model.EmojiNameMaxLength`).
    public static let maximumNameLength = 64

    /// Whether `name` could be a custom emoji: a valid reaction name that is not a
    /// system emoji. Custom emoji names cannot shadow system names on the server.
    public static func isCandidateName(_ name: String, catalog: EmojiCatalog = .system) -> Bool {
        guard name.utf8.count <= maximumNameLength, Reaction.isValidEmojiName(name) else { return false }
        return catalog.glyph(for: name.lowercased()) == nil
    }

    /// Approximate retained bytes, for cost-bounded caches.
    public var estimatedCost: Int { 96 + id.utf8.count + name.utf8.count }
}

extension MessageDocument {
    /// Distinct custom-emoji candidate names (`:name:` that are not system emoji) in
    /// document order, lowercased, at most `limit`. Work is bounded by the document's
    /// size and nesting (the parser already bounds both).
    public func customEmojiCandidates(limit: Int = 32, catalog: EmojiCatalog = .system) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func visit(_ inlines: [MarkupInline], depth: Int) {
            for inline in inlines where names.count < limit {
                switch inline {
                case .emoji(let raw):
                    let name = raw.lowercased()
                    if !seen.contains(name), CustomEmoji.isCandidateName(name, catalog: catalog) {
                        seen.insert(name)
                        names.append(name)
                    }
                case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, let children):
                    if depth < 24 { visit(children, depth: depth + 1) }
                default:
                    continue
                }
            }
        }
        func visit(_ blocks: [MarkupBlock], depth: Int) {
            for block in blocks where names.count < limit && depth < 16 {
                switch block {
                case .paragraph(let inlines), .heading(_, let inlines): visit(inlines, depth: 0)
                case .blockQuote(let children): visit(children, depth: depth + 1)
                case .list(let list): for item in list.items { visit(item.blocks, depth: depth + 1) }
                case .table(let table):
                    for cell in table.header { visit(cell, depth: 0) }
                    for row in table.rows { for cell in row { visit(cell, depth: 0) } }
                case .attachment(let attachment):
                    visit(attachment.text, depth: depth + 1)
                    for field in attachment.fields { visit(field.value, depth: depth + 1) }
                default: continue
                }
            }
        }
        visit(blocks, depth: 0)
        return names
    }
}
