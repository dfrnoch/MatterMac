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
/// - Work is linear in document size: every block and inline node is visited once, the
///   output is appended in place, and table padding is capped per cell. With a
///   `characterLimit`, rendering stops as soon as the limit is reached.
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
    /// Table cells are padded to at most this many columns so output stays linear.
    static let maximumTableColumnWidth = 40

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
    public func render(_ body: MessageBody, budget: ResourceBudget = .standard) -> NSAttributedString {
        switch body {
        case .document(let document, let isCollapsed):
            return render(document, characterLimit: isCollapsed ? budget.collapsedMessageCharacters
                                                                : budget.maximumRenderedCharacters)
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
    public func render(_ document: MessageDocument, characterLimit: Int? = nil) -> NSAttributedString {
        let state = RenderState(limit: characterLimit ?? Int.max)
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
    private var itemSpacing: CGFloat { max(2, (fonts.bodyLineHeight * 0.15).rounded()) }

    private func renderBlocks(_ blocks: [MarkupBlock], context: BlockContext, state: RenderState) {
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

    private func spacingBefore(_ block: MarkupBlock) -> CGFloat {
        if case .heading = block { return fonts.bodyLineHeight.rounded() }
        return blockSpacing
    }

    private func renderBlock(_ block: MarkupBlock, context: BlockContext, spacingBefore: CGFloat, state: RenderState) {
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
            var style = InlineStyle(size: fonts.headingSize(level: level), color: context.color)
            style.bold = true
            renderInlines(inlines, style: style, depth: 0, state: state)

        case .codeBlock(_, let code):
            renderCodeBlock(code, context: context, spacingBefore: spacingBefore, state: state)

        case .blockQuote(let children):
            let quote = NSTextBlock()
            quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            quote.setBorderColor(TimelinePalette.quoteBar, for: .minX)
            quote.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            if spacingBefore > 0 {
                quote.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
            }
            if context.indent > 0 {
                // Text blocks span their container; indentation becomes a block margin.
                quote.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            }
            var inner = context
            inner.textBlocks.append(quote)
            inner.color = .secondaryLabelColor
            inner.depth += 1
            inner.indent = 0
            if children.isEmpty {
                renderPlain(" ", context: inner, spacingBefore: 0, font: fonts.body, state: state)
            }
            for (index, child) in children.enumerated() {
                if state.isTruncated { return }
                if index > 0 { state.appendParagraphBreak() }
                renderBlock(child, context: inner, spacingBefore: index > 0 ? self.spacingBefore(child) : 0, state: state)
            }

        case .list(let ordered, let start, let items):
            renderList(ordered: ordered, start: start, items: items, context: context, spacingBefore: spacingBefore,
                       state: state)

        case .table(let header, let rows):
            renderTable(header: header, rows: rows, context: context, spacingBefore: spacingBefore, state: state)

        case .thematicBreak:
            let style = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks,
                                           spacingBefore: spacingBefore, alignment: .center)
            state.setParagraph(first: style, continuation: style)
            state.append("———", attributes: [
                .font: fonts.body, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
            ])

        case .plainFallback(let text):
            renderPlain(text, context: context, spacingBefore: spacingBefore, font: fonts.mono, state: state)
        }
    }

    private func renderPlain(_ text: String, context: BlockContext, spacingBefore: CGFloat, font: NSFont,
                             state: RenderState) {
        let first = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks, spacingBefore: spacingBefore)
        let continuation = baseParagraphStyle(indent: context.indent, blocks: context.textBlocks, spacingBefore: 0)
        state.setParagraph(first: first, continuation: continuation)
        state.appendMultiline(text, attributes: [.font: font, .foregroundColor: context.color, .paragraphStyle: first],
                              continuationStyle: continuation)
    }

    private func renderCodeBlock(_ code: String, context: BlockContext, spacingBefore: CGFloat, state: RenderState) {
        let block = NSTextBlock()
        block.backgroundColor = TimelinePalette.codeBackground
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
        if spacingBefore > 0 {
            block.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        }
        if context.indent > 0 {
            block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        }
        let style = NSMutableParagraphStyle()
        style.textBlocks = context.textBlocks + [block]
        style.lineBreakMode = .byWordWrapping
        style.tabStops = []
        style.defaultTabInterval = fonts.monoAdvance * 4
        style.baseWritingDirection = .leftToRight
        style.alignment = .left
        state.setParagraph(first: style, continuation: style)
        var text = code
        if text.hasSuffix("\n") { text.removeLast() }
        if text.isEmpty { text = " " }
        state.appendMultiline(text, attributes: [
            .font: fonts.mono, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ], continuationStyle: style)
    }

    private func renderList(ordered: Bool, start: Int, items: [[MarkupBlock]], context: BlockContext,
                            spacingBefore: CGFloat, state: RenderState) {
        let markerFont = fonts.font(size: fonts.bodySize, bold: false, italic: false, mono: false)
        let markerWidth: CGFloat
        if ordered {
            let widest = "\(start &+ max(items.count - 1, 0))."
            markerWidth = ceil(NSAttributedString(string: widest, attributes: [.font: markerFont]).size().width) + 6
        } else {
            markerWidth = ceil(fonts.bodySize * 1.1)
        }
        let bullets = ["•", "◦", "▪"]
        var contentContext = context
        contentContext.indent = context.indent + markerWidth
        contentContext.depth += 1
        contentContext.listDepth += 1

        for (index, item) in items.enumerated() {
            if state.isTruncated { return }
            if index > 0 { state.appendParagraphBreak() }
            let marker = ordered ? "\(start &+ index)." : bullets[context.listDepth % bullets.count]
            let first = listParagraphStyle(context: context, contentIndent: contentContext.indent,
                                           spacingBefore: index == 0 ? spacingBefore : itemSpacing)
            let continuation = baseParagraphStyle(indent: contentContext.indent, blocks: context.textBlocks,
                                                  spacingBefore: 0)
            state.setParagraph(first: first, continuation: continuation)
            state.append(marker + "\t", attributes: [
                .font: markerFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: first,
            ])
            var remaining = item[...]
            if case .paragraph(let inlines)? = remaining.first {
                renderInlines(inlines, style: InlineStyle(size: fonts.bodySize, color: context.color), depth: 0,
                              state: state)
                remaining = remaining.dropFirst()
            } else if remaining.isEmpty {
                continue
            }
            for block in remaining {
                if state.isTruncated { return }
                state.appendParagraphBreak()
                renderBlock(block, context: contentContext, spacingBefore: itemSpacing, state: state)
            }
        }
    }

    private func renderTable(header: [String], rows: [[String]], context: BlockContext, spacingBefore: CGFloat,
                             state: RenderState) {
        let columnCount = max(header.count, rows.reduce(0) { max($0, $1.count) })
        guard columnCount > 0 else { return }
        func clean(_ cell: String) -> String {
            cell.contains(where: \.isNewline) ? cell.replacingOccurrences(of: "\n", with: " ") : cell
        }
        let header = header.map(clean)
        let rows = rows.map { $0.map(clean) }
        var widths = Array(repeating: 1, count: columnCount)
        for (column, cell) in header.enumerated() { widths[column] = max(widths[column], cell.count) }
        for row in rows {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.count) }
        }
        widths = widths.map { min($0, Self.maximumTableColumnWidth) }

        func line(_ cells: [String]) -> String {
            var out = ""
            for column in 0..<columnCount {
                if column > 0 { out += " | " }
                let cell = column < cells.count ? cells[column] : ""
                out += cell
                let pad = widths[column] - cell.count
                if pad > 0, column < columnCount - 1 { out += String(repeating: " ", count: pad) }
            }
            return out
        }

        let first = tableParagraphStyle(context: context, spacingBefore: spacingBefore)
        let continuation = tableParagraphStyle(context: context, spacingBefore: 0)
        state.setParagraph(first: first, continuation: continuation)
        let boldMono = fonts.font(size: fonts.monoSize, bold: true, italic: false, mono: true)
        state.append(line(header), attributes: [.font: boldMono, .foregroundColor: context.color, .paragraphStyle: first])
        let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-")
        let rowAttributes: [NSAttributedString.Key: Any] = [
            .font: fonts.mono, .foregroundColor: context.color, .paragraphStyle: continuation,
        ]
        state.appendParagraphBreak()
        state.append(separator, attributes: [
            .font: fonts.mono, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: continuation,
        ])
        for row in rows {
            if state.isTruncated { return }
            state.appendParagraphBreak()
            state.append(line(row), attributes: rowAttributes)
        }
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

    private func listParagraphStyle(context: BlockContext, contentIndent: CGFloat, spacingBefore: CGFloat)
        -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = context.indent
        style.headIndent = contentIndent
        style.tabStops = [NSTextTab(textAlignment: .natural, location: contentIndent)]
        style.defaultTabInterval = 28
        style.paragraphSpacingBefore = spacingBefore
        style.lineBreakMode = .byWordWrapping
        style.baseWritingDirection = .natural
        style.textBlocks = context.textBlocks
        return style
    }

    private func tableParagraphStyle(context: BlockContext, spacingBefore: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = context.indent
        style.headIndent = context.indent
        style.paragraphSpacingBefore = spacingBefore
        style.lineBreakMode = .byWordWrapping
        style.alignment = .left
        style.baseWritingDirection = .leftToRight
        style.textBlocks = context.textBlocks
        return style
    }

    private func noteAttributes(paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
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

    private func attributes(_ style: InlineStyle, state: RenderState) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: fonts.font(size: style.mono ? max(style.size - 1, 8) : style.size, bold: style.bold,
                              italic: style.italic, mono: style.mono),
            .foregroundColor: style.link != nil ? NSColor.linkColor : style.color,
            .paragraphStyle: state.currentParagraphStyle,
        ]
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.mono { attributes[.backgroundColor] = TimelinePalette.inlineCodeBackground }
        if let link = style.link { attributes[.link] = link }
        return attributes
    }

    private func renderInlines(_ inlines: [MarkupInline], style: InlineStyle, depth: Int, state: RenderState) {
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
                state.append(emojiText(for: name), attributes: attributes)
            case .hashtag(let tag):
                state.append("#" + tag, attributes: attributes(style, state: state))
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
            attributes[.backgroundColor] = TimelinePalette.mentionHighlight
            attributes[.foregroundColor] = NSColor.labelColor
        } else {
            attributes[.foregroundColor] = style.link != nil ? NSColor.linkColor : style.color
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
private final class RenderState {
    let output = NSMutableAttributedString()
    private var remaining: Int
    private(set) var isTruncated = false
    private var firstParagraphStyle: NSParagraphStyle = .default
    private var continuationParagraphStyle: NSParagraphStyle = .default
    private(set) var currentParagraphStyle: NSParagraphStyle = .default
    private(set) var lastParagraphStyle: NSParagraphStyle?
    private var lastAttributes: [NSAttributedString.Key: Any] = [:]

    init(limit: Int) {
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
