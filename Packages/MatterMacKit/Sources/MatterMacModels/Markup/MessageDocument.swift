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
    case list(MarkupList)
    /// A GFM pipe table: column alignments and inline-formatted cells.
    case table(MarkupTable)
    case thematicBreak
    /// A Slack-style message attachment (`props.attachments`), composed by Core.
    case attachment(MarkupAttachment)
    /// Unsupported or over-limit content kept verbatim and shown monospaced.
    case plainFallback(String)

    func appendPlainText(to out: inout String) {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            MarkupInline.appendPlainText(of: inlines, to: &out)
        case .codeBlock(_, let code):
            out += code
        case .blockQuote(let blocks):
            for (index, block) in blocks.enumerated() {
                if index > 0 { out += "\n" }
                out += "> "
                block.appendPlainText(to: &out)
            }
        case .list(let list):
            for (index, item) in list.items.enumerated() {
                if index > 0 { out += "\n" }
                out += list.isOrdered ? "\(list.start &+ index). " : "• "
                switch item.task {
                case .open?: out += "[ ] "
                case .done?: out += "[x] "
                case nil: break
                }
                for (blockIndex, block) in item.blocks.enumerated() {
                    if blockIndex > 0 { out += "\n" }
                    block.appendPlainText(to: &out)
                }
            }
        case .table(let table):
            table.appendPlainText(to: &out)
        case .thematicBreak:
            out += "———"
        case .attachment(let attachment):
            attachment.appendPlainText(to: &out)
        case .plainFallback(let text):
            out += text
        }
    }
}

/// A bullet or ordered list. Items may carry a GFM task marker (`- [ ]`, `- [x]`).
public struct MarkupList: Hashable, Sendable {
    public var isOrdered: Bool
    /// First number of an ordered list (ignored for bullets).
    public var start: Int
    public var items: [MarkupListItem]

    public init(isOrdered: Bool = false, start: Int = 1, items: [MarkupListItem]) {
        self.isOrdered = isOrdered
        self.start = start
        self.items = items
    }
}

public struct MarkupListItem: Hashable, Sendable {
    public enum Task: Hashable, Sendable {
        case open
        case done
    }

    /// Task-list state when the item started with `[ ]` or `[x]` followed by a space;
    /// the marker itself is not part of `blocks`.
    public var task: Task?
    public var blocks: [MarkupBlock]

    public init(task: Task? = nil, blocks: [MarkupBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

/// A GFM pipe table. Every row has exactly `columnCount` cells: short rows are padded
/// with empty cells and extra cells are dropped, as GFM specifies.
public struct MarkupTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        /// No colon in the delimiter row: natural alignment.
        case none
        case left
        case center
        case right
    }

    public var alignments: [Alignment]
    public var header: [[MarkupInline]]
    public var rows: [[[MarkupInline]]]

    public init(alignments: [Alignment], header: [[MarkupInline]], rows: [[[MarkupInline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }

    public var columnCount: Int { alignments.count }

    func appendPlainText(to out: inout String) {
        func appendRow(_ cells: [[MarkupInline]]) {
            for (index, cell) in cells.enumerated() {
                if index > 0 { out += " | " }
                MarkupInline.appendPlainText(of: cell, to: &out)
            }
        }
        appendRow(header)
        for row in rows {
            out += "\n"
            appendRow(row)
        }
    }
}

/// A basic Slack-style message attachment in display form. The pretext is not part of
/// the attachment: like the official client, it is rendered as ordinary blocks before it.
public struct MarkupAttachment: Hashable, Sendable {
    /// The attachment's accent color (`color`): a Slack keyword or `#RGB`/`#RRGGBB`.
    public enum Accent: Hashable, Sendable {
        case none
        case good
        case warning
        case danger
        /// 0xRRGGBB.
        case rgb(UInt32)

        public init(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "good": self = .good
            case "warning": self = .warning
            case "danger": self = .danger
            default:
                var hex = Substring(value)
                if hex.hasPrefix("#") { hex = hex.dropFirst() }
                guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit),
                      var number = UInt32(hex, radix: 16) else {
                    self = .none
                    return
                }
                if hex.count == 3 {
                    let red = (number >> 8) & 0xF, green = (number >> 4) & 0xF, blue = number & 0xF
                    number = (red * 0x11) << 16 | (green * 0x11) << 8 | (blue * 0x11)
                }
                self = .rgb(number)
            }
        }
    }

    public struct Field: Hashable, Sendable {
        public var title: String
        public var value: [MarkupBlock]
        /// Consecutive short fields are laid out two per row.
        public var isShort: Bool

        public init(title: String, value: [MarkupBlock], isShort: Bool) {
            self.title = title
            self.value = value
            self.isShort = isShort
        }
    }

    public var accent: Accent
    public var author: String
    public var title: String
    /// Only a destination that passed the safe-link policy is kept.
    public var titleLink: SafeLink?
    public var text: [MarkupBlock]
    public var fields: [Field]
    /// The attachment image (`image_url`), offered as an explicit link; never fetched.
    public var imageLink: SafeLink?
    public var footer: String
    /// The attachment declared interactive actions, which are not executed.
    public var hasUnsupportedActions: Bool

    public init(accent: Accent = .none, author: String = "", title: String = "", titleLink: SafeLink? = nil,
                text: [MarkupBlock] = [], fields: [Field] = [], imageLink: SafeLink? = nil, footer: String = "",
                hasUnsupportedActions: Bool = false) {
        self.accent = accent
        self.author = author
        self.title = title
        self.titleLink = titleLink
        self.text = text
        self.fields = fields
        self.imageLink = imageLink
        self.footer = footer
        self.hasUnsupportedActions = hasUnsupportedActions
    }

    public var isEmpty: Bool {
        author.isEmpty && title.isEmpty && text.isEmpty && fields.isEmpty && imageLink == nil && footer.isEmpty
            && !hasUnsupportedActions
    }

    func appendPlainText(to out: inout String) {
        var lines: [String] = []
        if !author.isEmpty { lines.append(author) }
        if !title.isEmpty { lines.append(title) }
        if !text.isEmpty { lines.append(MessageDocument(blocks: text).plainText) }
        for field in fields {
            let value = MessageDocument(blocks: field.value).plainText
            lines.append(field.title.isEmpty ? value : field.title + ": " + value)
        }
        if !footer.isEmpty { lines.append(footer) }
        out += lines.joined(separator: "\n")
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

    static func appendPlainText(of inlines: [MarkupInline], to out: inout String) {
        for inline in inlines { inline.appendPlainText(to: &out) }
    }

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
