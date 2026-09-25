import AppKit
import MatterMacModels

extension MessageRenderer {
    func renderCodeBlock(_ code: String, context: BlockContext, spacingBefore: CGFloat, state: RenderState) {
        let block = TimelineTextBlock(decoration: .code)
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

    func renderList(_ list: MarkupList, context: BlockContext,
                            spacingBefore: CGFloat, state: RenderState) {
        let ordered = list.isOrdered, start = list.start, items = list.items
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
            state.append((item.task.map { $0 == .done ? "☑" : "☐" } ?? marker) + "\t", attributes: [
                .font: markerFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: first,
            ])
            var remaining = item.blocks[...]
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

    func listParagraphStyle(context: BlockContext, contentIndent: CGFloat, spacingBefore: CGFloat)
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

    func renderQuote(_ children: [MarkupBlock], context: BlockContext, spacingBefore: CGFloat, state: RenderState) {
        let block = TimelineTextBlock(decoration: .quote)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        var inner = context
        inner.textBlocks.append(block)
        inner.depth += 1
        for (index, child) in children.enumerated() {
            if state.isTruncated { return }
            if index > 0 { state.appendParagraphBreak() }
            renderBlock(child, context: inner, spacingBefore: index == 0 ? 0 : blockSpacing, state: state)
        }
    }

    func renderRule(context: BlockContext, spacingBefore: CGFloat, state: RenderState) {
        let block = TimelineTextBlock(decoration: .rule)
        var inner = context
        inner.textBlocks.append(block)
        renderPlain(" ", context: inner, spacingBefore: spacingBefore, font: fonts.body, state: state)
    }

    func hashtagAttributes(_ tag: String, style: InlineStyle, state: RenderState) -> [NSAttributedString.Key: Any] {
        var result = attributes(style, state: state)
        result[.foregroundColor] = NSColor.linkColor
        return result
    }

    func renderTable(_ table: MarkupTable, context: BlockContext, spacingBefore: CGFloat, state: RenderState) {
        let columns = min(table.columnCount, Self.maximumTableColumns)
        guard columns > 0 else { return }
        let grid = NSTextTable()
        grid.numberOfColumns = columns
        grid.layoutAlgorithm = .fixedLayoutAlgorithm
        grid.collapsesBorders = true
        let rows = [table.header] + Array(table.rows.prefix(Self.maximumTableRows))
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columns {
                if state.isTruncated { return }
                if rowIndex > 0 || column > 0 { state.appendParagraphBreak() }
                let cell = NSTextTableBlock(table: grid, startingRow: rowIndex, rowSpan: 1,
                                           startingColumn: column, columnSpan: 1)
                cell.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
                cell.setWidth(5, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(TimelinePalette.tableBorder)
                if rowIndex == 0 { cell.backgroundColor = TimelinePalette.tableHeaderBackground }
                let alignment: NSTextAlignment = switch table.alignments[column] {
                case .none, .left: .left
                case .center: .center
                case .right: .right
                }
                let paragraph = baseParagraphStyle(indent: 0, blocks: context.textBlocks + [cell],
                    spacingBefore: 0, alignment: alignment)
                state.setParagraph(first: paragraph, continuation: paragraph)
                var style = InlineStyle(size: fonts.bodySize, color: context.color)
                style.bold = rowIndex == 0
                var inlines = column < row.count ? row[column] : []
                let plain = MessageDocument(blocks: [.paragraph(inlines)]).plainText
                if plain.utf16.count > Self.maximumTableCellCharacters {
                    let source = plain as NSString
                    let cut = source.rangeOfComposedCharacterSequence(at: Self.maximumTableCellCharacters).location
                    inlines = [.text(source.substring(to: cut) + "…")]
                }
                // The shared output budget bounds every cell, including formatted content.
                if inlines.isEmpty { state.append(" ", attributes: attributes(style, state: state)) }
                else { renderInlines(inlines, style: style, depth: 0, state: state) }
            }
        }
        if table.rows.count > Self.maximumTableRows || table.columnCount > columns {
            state.appendParagraphBreak()
            let note = [table.rows.count > Self.maximumTableRows
                ? RenderingStrings.tableRowsNotShown(table.rows.count - Self.maximumTableRows) : "",
                table.columnCount > columns ? RenderingStrings.tableColumnsNotShown(table.columnCount - columns) : ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            renderPlain(note, context: context, spacingBefore: blockSpacing, font: fonts.meta, state: state)
        }
    }

    func renderAttachment(_ attachment: MarkupAttachment, context: BlockContext, spacingBefore: CGFloat,
                          state: RenderState) {
        let accent: NSColor = switch attachment.accent {
        case .none: TimelinePalette.attachmentDefaultAccent
        case .good: .systemGreen
        case .warning: .systemOrange
        case .danger: .systemRed
        case .rgb(let rgb): NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                    green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        let block = TimelineTextBlock(decoration: .attachment(accent))
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        var inner = context
        inner.textBlocks.append(block)
        inner.depth += 1
        var blocks: [MarkupBlock] = []
        if !attachment.author.isEmpty { blocks.append(.paragraph([.emphasis([.text(attachment.author)])])) }
        if !attachment.title.isEmpty {
            blocks.append(.paragraph([.link(destination: attachment.titleLink, label: [.strong([.text(attachment.title)])])]))
        }
        blocks += attachment.text
        var index = 0
        while index < attachment.fields.count {
            let field = attachment.fields[index]
            func content(_ field: MarkupAttachment.Field) -> [MarkupInline] {
                [.strong([.text(field.title)]), .lineBreak, .text(MessageDocument(blocks: field.value).plainText)]
            }
            if field.isShort, index + 1 < attachment.fields.count, attachment.fields[index + 1].isShort {
                blocks.append(.table(MarkupTable(alignments: [.left, .left], header: [content(field), content(attachment.fields[index + 1])], rows: [])))
                index += 2
            } else {
                blocks.append(.paragraph(content(field)))
                index += 1
            }
        }
        if let image = attachment.imageLink { blocks.append(.paragraph([.link(destination: image, label: [.text(RenderingStrings.attachmentImage)])])) }
        if !attachment.footer.isEmpty { blocks.append(.paragraph([.emphasis([.text(attachment.footer)])])) }
        if attachment.hasUnsupportedActions { blocks.append(.paragraph([.text(RenderingStrings.interactiveUnsupported)])) }
        for (index, child) in blocks.enumerated() {
            if state.isTruncated { return }
            if index > 0 { state.appendParagraphBreak() }
            renderBlock(child, context: inner, spacingBefore: index == 0 ? 0 : itemSpacing, state: state)
        }
    }
}
