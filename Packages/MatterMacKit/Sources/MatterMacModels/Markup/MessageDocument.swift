public import Foundation

/// A parsed, bounded, presentation-neutral representation of a Mattermost message's
/// markup. Produced off the main actor by `MarkupParser`; converted to attributed
/// text by the UI for visible rows only. Contains no fonts, colors, or AppKit types.
public struct MessageDocument: Hashable, Sendable {
    public var blocks: [MarkupBlock]
    /// `true` if parser limits were reached; the remainder is preserved verbatim in a
    /// trailing `.plainFallback` block (content is never silently dropped).
    ///
    /// `MarkupParser` guarantees: `hitLimits == true` exactly when the last block is a
    /// `.plainFallback` whose text is a verbatim suffix of the input, starting at the
    /// beginning of the first top-level block that could not be parsed within limits.
    public var hitLimits: Bool

    public init(blocks: [MarkupBlock], hitLimits: Bool = false) {
        self.blocks = blocks
        self.hitLimits = hitLimits
    }

    public static let empty = MessageDocument(blocks: [])

    /// Plain text used for accessibility labels, copy-as-text, and search highlighting.
    public var plainText: String {
        var out = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 { out += "\n" }
            block.appendPlainText(to: &out)
        }
        return out
    }
}

public indirect enum MarkupBlock: Hashable, Sendable {
    case paragraph([MarkupInline])
    case heading(level: Int, [MarkupInline])
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkupBlock])
    case list(ordered: Bool, start: Int, items: [[MarkupBlock]])
    /// A table rendered as aligned monospaced text (readable fallback, not a grid).
    case table(header: [String], rows: [[String]])
    case thematicBreak
    /// Unsupported or over-limit content kept verbatim and shown monospaced.
    case plainFallback(String)

    func appendPlainText(to out: inout String) {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            for inline in inlines { inline.appendPlainText(to: &out) }
        case .codeBlock(_, let code):
            out += code
        case .blockQuote(let blocks):
            for (index, block) in blocks.enumerated() {
                if index > 0 { out += "\n" }
                out += "> "
                block.appendPlainText(to: &out)
            }
        case .list(let ordered, let start, let items):
            for (index, item) in items.enumerated() {
                if index > 0 { out += "\n" }
                out += ordered ? "\(start + index). " : "• "
                for (blockIndex, block) in item.enumerated() {
                    if blockIndex > 0 { out += "\n" }
                    block.appendPlainText(to: &out)
                }
            }
        case .table(let header, let rows):
            out += header.joined(separator: " | ")
            for row in rows { out += "\n" + row.joined(separator: " | ") }
        case .thematicBreak:
            out += "———"
        case .plainFallback(let text):
            out += text
        }
    }
}

public indirect enum MarkupInline: Hashable, Sendable {
    case text(String)
    case emphasis([MarkupInline])
    case strong([MarkupInline])
    case strikethrough([MarkupInline])
    case code(String)
    /// `destination` is `nil` when the URL failed the safe-link policy; the label is
    /// still shown, but nothing is openable.
    case link(destination: SafeLink?, label: [MarkupInline])
    /// `@username`, `@channel`, `@here`, `@all`.
    case mention(String)
    /// `~channel-name`.
    case channelMention(String)
    /// `:emoji_name:`. Rendered as a Unicode emoji when known, otherwise as text.
    case emoji(String)
    case hashtag(String)
    case lineBreak
    case softBreak

    func appendPlainText(to out: inout String) {
        switch self {
        case .text(let text), .code(let text): out += text
        case .emphasis(let children), .strong(let children), .strikethrough(let children):
            for child in children { child.appendPlainText(to: &out) }
        case .link(_, let label):
            for child in label { child.appendPlainText(to: &out) }
        case .mention(let name): out += "@" + name
        case .channelMention(let name): out += "~" + name
        case .emoji(let name): out += ":" + name + ":"
        case .hashtag(let tag): out += "#" + tag
        case .lineBreak, .softBreak: out += "\n"
        }
    }
}

/// A link destination that passed the safe-scheme policy. Only `http`, `https`, and
/// `mailto` are openable; everything else (custom schemes, `file:`, `javascript:`,
/// `vbscript:`, `data:`) is rejected at parse time.
///
/// Additionally rejected: control characters (C0, DEL, C1), invisible format
/// characters (bidi overrides, zero-width characters, BOM), any whitespace inside the
/// destination, embedded credentials (`user@` / `user:password@`, including an empty
/// user), web URLs without a plain host, and destinations longer than 2,048 bytes.
public struct SafeLink: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case web, mail }
    public let url: URL
    public let kind: Kind

    /// Maximum destination length accepted, in UTF-8 bytes.
    public static let maximumLength = 2_048

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumLength,
              !trimmed.unicodeScalars.contains(where: Self.isForbidden),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "http", "https":
            guard url.user(percentEncoded: true) == nil, url.password(percentEncoded: true) == nil,
                  let host = url.host(percentEncoded: false), Self.isPlainHost(host)
            else { return nil }
            self.kind = .web
        case "mailto":
            // `mailto:` must carry an address; an authority (`mailto://...`) is not a mail link.
            guard trimmed.utf8.count > 7, url.host(percentEncoded: true) == nil,
                  url.user(percentEncoded: true) == nil
            else { return nil }
            self.kind = .mail
        default:
            return nil
        }
        self.url = url
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x21 || (value >= 0x7F && value <= 0x9F) { return true }
        if value < 0x7F { return false }
        switch scalar.properties.generalCategory {
        case .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .control:
            return true
        default:
            return scalar.properties.isWhitespace
        }
    }

    /// ASCII host as produced by `URL` (IDN hosts arrive as punycode): letters, digits,
    /// `.`, `-`, `_`, and `:` for bracketed IPv6 literals. Percent-decoded hosts with
    /// anything else (`javascript%3Aalert(1)` decodes to `javascript:alert(1)`) are refused.
    private static func isPlainHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 255 else { return false }
        return host.utf8.allSatisfy { byte in
            MarkupByte.isAlphanumeric(byte) || byte == MarkupByte.dot || byte == MarkupByte.dash
                || byte == MarkupByte.underscore || byte == MarkupByte.colon
        }
    }
}

/// Bounds on parser work for one message (SPEC §14). Exceeding any limit stops rich
/// parsing and preserves the remainder verbatim.
///
/// - `maximumInputCharacters`: Unicode scalars considered for rich parsing (Mattermost
///   counts post length in runes). Lines beyond it, plus the top-level block that
///   crosses it, become the trailing `.plainFallback`.
/// - `maximumNestingDepth`: block containers (quotes, lists) and, separately, inline
///   containers (emphasis, strong, strikethrough, links) may each nest this deep.
/// - `maximumBlocks`: blocks created (including list items and table rows).
/// - `maximumInlineNodes`: inline tokens created across the whole message.
public struct MarkupLimits: Hashable, Sendable {
    public var maximumInputCharacters: Int
    public var maximumNestingDepth: Int
    public var maximumBlocks: Int
    public var maximumInlineNodes: Int

    public init(maximumInputCharacters: Int = 70_000, maximumNestingDepth: Int = 8,
                maximumBlocks: Int = 1_000, maximumInlineNodes: Int = 10_000) {
        self.maximumInputCharacters = maximumInputCharacters
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumBlocks = maximumBlocks
        self.maximumInlineNodes = maximumInlineNodes
    }

    public static let standard = MarkupLimits()
}
