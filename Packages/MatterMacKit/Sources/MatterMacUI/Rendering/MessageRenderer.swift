public import AppKit
public import MatterMacModels
public import MatterMacCore

/// Maps an emoji short name (without colons) to its Unicode presentation, or `nil` when
/// unknown (rendered as `:name:`). Supplied by the owner (e.g. an emoji catalog).
public typealias TimelineEmojiLookup = (String) -> String?

extension NSAttributedString.Key {
    /// Username (without "@") of a user mention. The body text view reports clicks on it
    /// as `TimelineAction.mentionTapped`. Never a `.link`: only `SafeLink` destinations
    /// carry the `.link` attribute.
    nonisolated public static let matterMacCustomEmoji = NSAttributedString.Key("MatterMacCustomEmoji")
    nonisolated public static let matterMacMention = NSAttributedString.Key("MatterMacMention")
    /// Channel name (without "~") of a channel mention; clicks report
    /// `TimelineAction.channelMentionTapped`.
    nonisolated public static let matterMacChannelMention = NSAttributedString.Key("MatterMacChannelMention")
    /// Marks the trailing "(edited)" indicator (not part of the message text).
    nonisolated public static let matterMacEditedMarker = NSAttributedString.Key("MatterMacEditedMarker")
}

/// Converts a presentation-neutral `MessageDocument` into attributed text for display
/// with TextKit 1.
///
/// - System fonts only; the body font is `NSFont.preferredFont(forTextStyle: .body)`
///   scaled by `fontScale`; code uses `NSFont.monospacedSystemFont`.
/// - Dynamic system colors only (label, secondary label, link, control accent).
/// - `.link` is set exclusively for `SafeLink` destinations; the label of a rejected link
///   is plain text.
/// - Work is linear in document size: every block and inline node is visited once and
///   the output is appended in place. Tables are bounded in rows, columns and cell text
///   (the rest is reported, never silently dropped). With a `characterLimit`, rendering
///   stops as soon as the limit is reached.
/// - Blocks (code, quotes, tables, attachments, rules) are TextKit 1 text blocks whose
///   padding and borders are fixed here; `TimelineTextBlock` only changes how their
///   backgrounds are drawn. Measured height therefore equals drawn height.
///
/// Main-actor only (uses AppKit text objects). Render only visible or near-visible rows;
/// results are cached by `TimelineLayoutCaches`.
public final class MessageRenderer {
    public let fontScale: CGFloat
    /// The signed-in user's username, used to highlight mentions of the current user.
    public let currentUsername: String?
    private let normalizedUsername: String?
    private let emojiLookup: TimelineEmojiLookup?
    let fonts: TimelineFonts

    /// Maximum nesting handled structurally; deeper content is rendered as plain text
    /// (the parser already bounds nesting, this guards hand-built documents).
    static let maximumBlockDepth = 12
    static let maximumInlineDepth = 24
    /// Table bounds: rows and columns beyond these are summarized in a note; cell text
    /// beyond `maximumTableCellCharacters` UTF-16 units ends with "…".
    static let maximumTableRows = ResourceBudget.maximumRenderedTableRows
    static let maximumTableColumns = ResourceBudget.maximumRenderedTableColumns
    static let maximumTableCellCharacters = ResourceBudget.maximumRenderedTableCellCharacters

    public init(fontScale: CGFloat = 1, currentUsername: String? = nil, emojiLookup: TimelineEmojiLookup? = nil) {
        self.fonts = TimelineFonts.forScale(fontScale)
        self.fontScale = fonts.scale
        self.currentUsername = currentUsername
        self.normalizedUsername = currentUsername.map { $0.lowercased() }
        self.emojiLookup = emojiLookup
    }

    /// The text shown for an emoji short name: the looked-up Unicode emoji or `:name:`.
    public func emojiText(for name: String) -> String {
        if let emojiLookup, let unicode = emojiLookup(name), !unicode.isEmpty { return unicode }
        return ":" + name + ":"
    }

    /// Renders a message body. Collapsed documents render at most
    /// `budget.collapsedMessageCharacters` characters followed by an ellipsis; everything
    /// else is bounded by `budget.maximumRenderedCharacters`.
    public func render(_ body: MessageBody, budget: ResourceBudget = .standard, customEmoji: [String: String] = [:]) -> NSAttributedString {
        switch body {
        case .document(let document, let isCollapsed):
            return render(document, characterLimit: isCollapsed ? budget.collapsedMessageCharacters
                                                                : budget.maximumRenderedCharacters, customEmoji: customEmoji)
        case .system(let text):
            return renderNote(text, limit: budget.maximumRenderedCharacters)
        case .deleted:
            return renderNote(TimelineStrings.deletedMessage, limit: budget.maximumRenderedCharacters)
        case .unsupported(let summary, let fallbackText):
            let state = RenderState(limit: budget.maximumRenderedCharacters)
            let noteStyle = baseParagraphStyle(indent: 0, blocks: [], spacingBefore: 0)
            state.setParagraph(first: noteStyle, continuation: noteStyle)
            state.append(summary, attributes: noteAttributes(paragraph: noteStyle))
            if !fallbackText.isEmpty {
                state.appendParagraphBreak()
                let style = baseParagraphStyle(indent: 0, blocks: [], spacingBefore: blockSpacing)
                let continuation = baseParagraphStyle(indent: 0, blocks: [], spacingBefore: 0)
                state.setParagraph(first: style, continuation: continuation)
                state.append(fallbackText, attributes: [
                    .font: fonts.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
                ])
            }
            return state.finish(ellipsisAttributes: noteAttributes(paragraph: noteStyle))
        }
    }

    /// Renders a document, stopping after `characterLimit` UTF-16 units (plus an ellipsis).
    public func render(_ document: MessageDocument, characterLimit: Int? = nil, customEmoji: [String: String] = [:]) -> NSAttributedString {
        let state = RenderState(limit: characterLimit ?? ResourceBudget.standard.maximumRenderedCharacters, customEmoji: customEmoji)
        renderBlocks(document.blocks, context: BlockContext(), state: state)
        let ellipsisStyle = state.lastParagraphStyle ?? baseParagraphStyle(indent: 0, blocks: [], spacingBefore: 0)
        return state.finish(ellipsisAttributes: [
            .font: fonts.body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: ellipsisStyle,
        ])
    }

    /// Appends the "(edited)" marker: on the last line after a paragraph, otherwise
    /// (code block, list, quote, table) on its own line without block styling.
    public func appendingEditedMarker(to text: NSAttributedString, inlineAfterParagraph: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let base = baseParagraphStyle(indent: 0, blocks: [], spacingBefore: 0)
        var paragraph: NSParagraphStyle = base
        var inline = false
        if inlineAfterParagraph, result.length > 0,
           let last = result.attribute(.paragraphStyle, at: result.length - 1, effectiveRange: nil) as? NSParagraphStyle,
           last.textBlocks.isEmpty {
            paragraph = last
            inline = true
        }
        let marker = (result.length == 0 ? "" : (inline ? " " : "\n")) + TimelineStrings.edited
        result.append(NSAttributedString(string: marker, attributes: [
            .font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            .matterMacEditedMarker: true,
        ]))
        return result
    }

    // MARK: - Blocks

    struct BlockContext {
        var indent: CGFloat = 0
        var textBlocks: [NSTextBlock] = []
        var color: NSColor = .labelColor
        var depth = 0
        var listDepth = 0
    }

    var blockSpacing: CGFloat { (fonts.bodyLineHeight * 0.5).rounded() }
    var itemSpacing: CGFloat { max(2, (fonts.bodyLineHeight * 0.15).rounded()) }

    func renderBlocks(_ blocks: [MarkupBlock], context: BlockContext, state: RenderState) {
        for (index, block) in blocks.enumerated() {
            if state.isTruncated { return }
            let spacing: CGFloat
            if index > 0 || state.output.length > 0 {
                state.appendParagraphBreak()
                spacing = spacingBefore(block)
            } else {
                spacing = 0
            }
            renderBlock(block, context: context, spacingBefore: spacing, state: state)
        }
    }

    func spacingBefore(_ block: MarkupBlock) -> CGFloat {
        if case .heading(let level, _) = block { return (fonts.bodyLineHeight * (level <= 2 ? 1 : 0.75)).rounded() }
        return blockSpacing
    }

    func renderBlock(_ block: MarkupBlock, context: BlockContext, spacingBefore: CGFloat, state: RenderState) {
        if context.depth > Self.maximumBlockDepth {
            renderPlain(MessageDocument(blocks: [block]).plainText, context: context, spacingBefore: spacingBefore,
                        font: fonts.body, state: state)
            return
        }
        switch block {
        case .paragraph(let inlines):
            let first = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks, spacingBefore: spacingBefore)
            let continuation = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks, spacingBefore: 0)
            state.setParagraph(first: first, continuation: continuation)
            renderInlines(inlines, style: InlineStyle(size: fonts.bodySize, color: context.color), depth: 0, state: state)

        case .heading(let level, let inlines):
            let first = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks, spacingBefore: spacingBefore)
            let continuation = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks, spacingBefore: 0)
            state.setParagraph(first: first, continuation: continuation)
            var style = InlineStyle(size: fonts.headingSize(level: level),
                                    color: level >= 6 ? NSColor.secondaryLabelColor : context.color)
            style.bold = true
            renderInlines(inlines, style: style, depth: 0, state: state)

        case .codeBlock(_, let code):
            renderCodeBlock(code, context: context, spacingBefore: spacingBefore, state: state)

        case .blockQuote(let children):
            renderQuote(children, context: context, spacingBefore: spacingBefore, state: state)

        case .list(let list):
            renderList(list, context: context, spacingBefore: spacingBefore, state: state)

        case .table(let table):
            renderTable(table, context: context, spacingBefore: spacingBefore, state: state)

        case .thematicBreak:
            renderRule(context: context, spacingBefore: spacingBefore, state: state)

        case .attachment(let attachment):
            renderAttachment(attachment, context: context, spacingBefore: spacingBefore, state: state)

        case .plainFallback(let text):
            renderPlain(text, context: context, spacingBefore: spacingBefore, font: fonts.mono, state: state)
        }
    }

    func renderPlain(_ text: String, context: BlockContext, spacingBefore: CGFloat, font: NSFont,
                     state: RenderState) {
        let first = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks, spacingBefore: spacingBefore)
        let continuation = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks, spacingBefore: 0)
        state.setParagraph(first: first, continuation: continuation)
        state.appendMultiline(text, attributes: [.font: font, .foregroundColor: context.color, .paragraphStyle: first],
                              continuationStyle: continuation)
    }

    // MARK: - Paragraph styles

    func baseParagraphStyle(indent: CGFloat, blocks: [NSTextBlock], spacingBefore: CGFloat,
                            alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacingBefore = spacingBefore
        style.lineBreakMode = .byWordWrapping
        style.alignment = alignment
        style.baseWritingDirection = .natural
        style.textBlocks = blocks
        return style
    }

    func noteAttributes(paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [
            .font: fonts.font(size: fonts.bodySize, bold: false, italic: true, mono: false),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
    }

    private func renderNote(_ text: String, limit: Int) -> NSAttributedString {
        let state = RenderState(limit: limit)
        let style = baseParagraphStyle(indent: 0, blocks: [], spacingBefore: 0)
        state.setParagraph(first: style, continuation: style)
        state.appendMultiline(text, attributes: noteAttributes(paragraph: style), continuationStyle: style)
        return state.finish(ellipsisAttributes: noteAttributes(paragraph: style))
    }

    // MARK: - Inlines

    struct InlineStyle {
        var size: CGFloat
        var color: NSColor
        var bold = false
        var italic = false
        var strike = false
        var mono = false
        var link: URL?

        init(size: CGFloat, color: NSColor) {
            self.size = size
            self.color = color
        }
    }

    func attributes(_ style: InlineStyle, state: RenderState) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: fonts.font(size: style.mono ? max(style.size - 1, 8) : style.size, bold: style.bold,
                              italic: style.italic, mono: style.mono),
            .foregroundColor: style.link != nil ? NSColor.linkColor : style.color,
            .paragraphStyle: state.currentParagraphStyle,
        ]
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.mono {
            attributes[.backgroundColor] = TimelinePalette.inlineCodeBackground
            attributes[.matterMacInlineCode] = true
        }
        if let link = style.link { attributes[.link] = link }
        return attributes
    }

    func renderInlines(_ inlines: [MarkupInline], style: InlineStyle, depth: Int, state: RenderState) {
        if depth > Self.maximumInlineDepth {
            var flat = ""
            for inline in inlines { flat += MessageDocument(blocks: [.paragraph([inline])]).plainText }
            state.appendInlineText(flat, attributes: attributes(style, state: state))
            return
        }
        for inline in inlines {
            if state.isTruncated { return }
            switch inline {
            case .text(let text):
                state.appendInlineText(text, attributes: attributes(style, state: state))
            case .emphasis(let children):
                var child = style
                child.italic = true
                renderInlines(children, style: child, depth: depth + 1, state: state)
            case .strong(let children):
                var child = style
                child.bold = true
                renderInlines(children, style: child, depth: depth + 1, state: state)
            case .strikethrough(let children):
                var child = style
                child.strike = true
                renderInlines(children, style: child, depth: depth + 1, state: state)
            case .code(let code):
                var child = style
                child.mono = true
                state.appendInlineText(code, attributes: attributes(child, state: state))
            case .link(let destination, let label):
                var child = style
                // Only a SafeLink becomes openable; a rejected destination keeps its
                // label as ordinary text.
                child.link = destination?.url
                renderInlines(label, style: child, depth: depth + 1, state: state)
            case .mention(let name):
                state.append("@" + name, attributes: mentionAttributes(name, style: style, state: state))
            case .channelMention(let name):
                var attributes = attributes(style, state: state)
                attributes[.font] = fonts.font(size: style.size, bold: true, italic: style.italic, mono: false)
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.matterMacChannelMention] = name
                attributes[.cursor] = NSCursor.pointingHand
                state.append("~" + name, attributes: attributes)
            case .emoji(let name):
                var attributes = attributes(style, state: state)
                attributes[.toolTip] = ":" + name + ":"
                if let id = state.customEmoji[name.lowercased()] {
                    let font = attributes[.font] as? NSFont ?? fonts.body
                    let attachment = NSTextAttachment()
                    let edge = ceil(font.ascender - font.descender)
                    attachment.bounds = NSRect(x: 0, y: font.descender, width: edge, height: edge)
                    attachment.attachmentCell = CustomEmojiAttachmentCell(bounds: attachment.bounds)
                    attributes[.attachment] = attachment
                    attributes[.matterMacCustomEmoji] = id
                    state.append("\u{FFFC}", attributes: attributes)
                } else {
                    state.append(emojiText(for: name), attributes: attributes)
                }
            case .hashtag(let tag):
                state.append("#" + tag, attributes: hashtagAttributes(tag, style: style, state: state))
            case .lineBreak, .softBreak:
                state.appendLineBreak()
            }
        }
    }

    private func mentionAttributes(_ name: String, style: InlineStyle, state: RenderState)
        -> [NSAttributedString.Key: Any] {
        var attributes = attributes(style, state: state)
        let lower = name.lowercased()
        let isSpecial = lower == "channel" || lower == "here" || lower == "all"
        let isCurrentUser = normalizedUsername.map { $0 == lower } ?? false
        attributes[.font] = fonts.font(size: style.size, bold: true, italic: style.italic, mono: false)
        if isSpecial || isCurrentUser {
            // Like the official client: your own mentions and channel-wide mentions are
            // highlighted; the message cell is tinted too.
            attributes[.backgroundColor] = TimelinePalette.mentionHighlight
            attributes[.foregroundColor] = TimelinePalette.selfMentionText
            attributes[.matterMacSelfMention] = true
        } else {
            // Other people's mentions read as links (they open the profile).
            attributes[.foregroundColor] = NSColor.linkColor
        }
        if !isSpecial {
            attributes[.matterMacMention] = name
            attributes[.cursor] = NSCursor.pointingHand
        }
        return attributes
    }
}

/// Mutable output buffer with a UTF-16 budget. Appends in place (amortized O(1) per
/// unit) and snaps truncation to a grapheme boundary.
final class RenderState {
    let output = NSMutableAttributedString()
    let customEmoji: [String: String]
    private var remaining: Int
    private(set) var isTruncated = false
    private var firstParagraphStyle: NSParagraphStyle = .default
    private var continuationParagraphStyle: NSParagraphStyle = .default
    private(set) var currentParagraphStyle: NSParagraphStyle = .default
    private(set) var lastParagraphStyle: NSParagraphStyle?
    private var lastAttributes: [NSAttributedString.Key: Any] = [:]

    init(limit: Int, customEmoji: [String: String] = [:]) {
        self.customEmoji = customEmoji
        remaining = max(limit, 0)
    }

    func setParagraph(first: NSParagraphStyle, continuation: NSParagraphStyle) {
        firstParagraphStyle = first
        continuationParagraphStyle = continuation
        currentParagraphStyle = first
    }

    /// Appends text that must not contain paragraph separators in its attribute run.
    func append(_ text: String, attributes: [NSAttributedString.Key: Any]) {
        guard !isTruncated, !text.isEmpty else { return }
        let ns = text as NSString
        var piece = ns
        if ns.length > remaining {
            var cut = remaining
            if cut > 0, cut < ns.length {
                cut = ns.rangeOfComposedCharacterSequence(at: cut).location
            }
            piece = ns.substring(to: cut) as NSString
            isTruncated = true
        }
        if piece.length > 0 {
            let location = output.length
            output.replaceCharacters(in: NSRange(location: location, length: 0), with: piece as String)
            output.setAttributes(attributes, range: NSRange(location: location, length: piece.length))
            remaining -= piece.length
            lastAttributes = attributes
            lastParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        }
    }

    /// Inline text may contain newlines (e.g. a text node with embedded breaks); each
    /// newline switches to the continuation paragraph style.
    func appendInlineText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
        guard text.contains(where: \.isNewline) else {
            append(text, attributes: attributes)
            return
        }
        appendMultiline(text, attributes: attributes, continuationStyle: continuationParagraphStyle)
    }

    func appendMultiline(_ text: String, attributes: [NSAttributedString.Key: Any], continuationStyle: NSParagraphStyle) {
        var attributes = attributes
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isTruncated { return }
            if !first {
                appendLineBreak()
                attributes[.paragraphStyle] = continuationStyle
            }
            first = false
            append(String(line), attributes: attributes)
        }
    }

    /// A hard line break inside a block: new paragraph without block spacing.
    func appendLineBreak() {
        appendNewline()
        currentParagraphStyle = continuationParagraphStyle
    }

    /// Terminates the current paragraph before a new block.
    func appendParagraphBreak() {
        appendNewline()
    }

    private func appendNewline() {
        guard !isTruncated else { return }
        var attributes = lastAttributes
        attributes[.link] = nil
        attributes[.backgroundColor] = nil
        attributes[.matterMacMention] = nil
        attributes[.matterMacChannelMention] = nil
        attributes[.cursor] = nil
        attributes[.toolTip] = nil
        attributes[.attachment] = nil
        attributes[.matterMacSelfMention] = nil
        attributes[.matterMacInlineCode] = nil
        attributes[.matterMacCustomEmoji] = nil
        attributes[.paragraphStyle] = currentParagraphStyle
        if attributes[.font] == nil { attributes[.font] = NSFont.preferredFont(forTextStyle: .body) }
        append("\n", attributes: attributes)
    }

    func finish(ellipsisAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        if isTruncated {
            var attributes = ellipsisAttributes
            if let style = lastParagraphStyle { attributes[.paragraphStyle] = style }
            let location = output.length
            output.replaceCharacters(in: NSRange(location: location, length: 0), with: "…")
            output.setAttributes(attributes, range: NSRange(location: location, length: 1))
        }
        return output
    }
}

/// TextKit 1 measures the attachment cell, not NSTextAttachment.bounds. Keep
/// cell geometry independent of the image's pixel dimensions and arrival time.
final class CustomEmojiAttachmentCell: NSTextAttachmentCell {
    nonisolated let fixedBounds: NSRect

    init(bounds: NSRect, image: NSImage? = nil) {
        fixedBounds = bounds
        super.init(imageCell: image)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override func cellSize() -> NSSize { fixedBounds.size }
    nonisolated override func cellBaselineOffset() -> NSPoint { fixedBounds.origin }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if let image {
            image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSAttributedString(string: ":", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
                .draw(in: cellFrame)
        }
    }
}
