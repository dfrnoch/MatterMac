import AppKit
import MatterMacModels
import MatterMacCore

/// Frames for every component of a row at one layout width. Computed once per
/// (item revision, width bucket, font scale) and used both for the row height and for
/// the cell's manual frame layout, so measured height and display always agree.
enum RowLayout {
    case message(MessageRowLayout)
    case separator(SeparatorRowLayout)

    var height: CGFloat {
        switch self {
        case .message(let layout): layout.height
        case .separator(let layout): layout.height
        }
    }

    var estimatedCost: Int {
        switch self {
        case .message(let layout):
            TimelineLayoutCaches.rowLayoutBaseCost
                + (layout.attachments.count + layout.reactions.count + (layout.linkPreview == nil ? 8 : 13))
                * TimelineLayoutCaches.rowLayoutFrameCost
        case .separator:
            TimelineLayoutCaches.rowLayoutBaseCost
        }
    }
}

struct PendingLayout: Equatable {
    var spinner: CGRect?
    var status: CGRect
    var retry: CGRect?
    var discard: CGRect?
}

struct MessageRowLayout: Equatable {
    var height: CGFloat = 0
    var avatar: CGRect?
    var threadContext: CGRect?
    var header: CGRect?
    var body: CGRect = .zero
    var showMore: CGRect?
    /// Server-provided link preview card (below the text, above attachments).
    var linkPreview: LinkPreviewLayout?
    /// One frame per displayed file (at most `maximumDisplayedFiles`).
    var attachments: [CGRect] = []
    var attachmentOverflow: CGRect?
    /// One frame per displayed reaction chip (at most `maximumDisplayedReactions`).
    var reactions: [CGRect] = []
    var reactionOverflow: CGRect?
    var replies: CGRect?
    var pending: PendingLayout?
}

struct SeparatorRowLayout: Equatable {
    var height: CGFloat
    /// Wrapping explanatory text (failed gap, history start).
    var label: CGRect = .zero
    var button: CGRect?
    var spinner: CGRect?
}

/// Layout constants and computations for timeline rows at one font scale.
struct TimelineRowMetrics {
    let fonts: TimelineFonts

    static let horizontalInset: CGFloat = 16
    static let avatarSize = TimelineMetrics.avatarSize
    static let avatarGap: CGFloat = 10
    static let contentLeading = horizontalInset + avatarSize + avatarGap
    static let headerTopPadding: CGFloat = 8
    static let continuationTopPadding: CGFloat = 2
    static let bottomPadding: CGFloat = 4
    static let componentSpacing: CGFloat = 6
    static let buttonHeight: CGFloat = 22
    static let fileChipHeight: CGFloat = 44
    static let fileChipMaximumWidth: CGFloat = 320
    static let chipSpacing: CGFloat = 4
    static let spinnerSize: CGFloat = 16
    static let maximumDisplayedFiles = 10
    static let maximumDisplayedReactions = 40
    static let minimumContentWidth: CGFloat = 80
    static let minimumThumbnailEdge: CGFloat = 24
    static let unknownImageSize = CGSize(width: 240, height: 160)

    /// Tall enough for an Apple Color Emoji line (taller than the text line) plus insets.
    var reactionChipHeight: CGFloat { ceil(max(fonts.bodyLineHeight, fonts.emojiLineHeight) + 6) }

    static func contentWidth(forLayoutWidth width: CGFloat) -> CGFloat {
        max(minimumContentWidth, width - contentLeading - horizontalInset)
    }

    /// Thumbnail box for an image file, scaled to fit 360×240 and the content width.
    static func thumbnailSize(for file: FileInfo, contentWidth: CGFloat) -> CGSize {
        let maxWidth = min(TimelineMetrics.maximumThumbnailSize.width, contentWidth)
        let maxHeight = TimelineMetrics.maximumThumbnailSize.height
        guard let width = file.width, let height = file.height, width > 0, height > 0 else {
            let box = unknownImageSize
            let scale = min(1, maxWidth / box.width)
            return CGSize(width: floor(box.width * scale), height: floor(box.height * scale))
        }
        let scale = min(1, maxWidth / CGFloat(width), maxHeight / CGFloat(height))
        return CGSize(width: max(minimumThumbnailEdge, floor(CGFloat(width) * scale)),
                      height: max(minimumThumbnailEdge, floor(CGFloat(height) * scale)))
    }

    static func showsThumbnail(_ file: FileInfo) -> Bool { file.isImage }

    func reactionTitle(_ reaction: ReactionGroup, renderer: MessageRenderer) -> (emoji: String, count: String) {
        (renderer.emojiText(for: reaction.emojiName), "\(reaction.count)")
    }

    /// Same measurement the chip draws with (`ReactionChipMetrics`), so nothing clips.
    func reactionChipWidth(_ reaction: ReactionGroup, renderer: MessageRenderer) -> CGFloat {
        let title = reactionTitle(reaction, renderer: renderer)
        return ReactionChipMetrics(emoji: title.emoji, count: title.count, fonts: fonts).width
    }

    func statusText(for state: SendState) -> NSAttributedString {
        let color: NSColor = switch state {
        case .failed: .systemRed
        case .outcomeUnknown: .systemOrange
        default: .secondaryLabelColor
        }
        return NSAttributedString(string: TimelineStrings.sendStateDescription(state), attributes: [
            .font: fonts.meta, .foregroundColor: color,
        ])
    }

    static func showsSpinner(_ state: SendState) -> Bool {
        switch state {
        case .queued, .uploading, .sending: true
        case .failed, .outcomeUnknown: false
        }
    }

    static func offersUploadDiscard(_ state: SendState) -> Bool {
        switch state { case .queued, .uploading: true; default: false }
    }

    static func offersRetry(_ state: SendState) -> Bool {
        switch state {
        case .failed, .outcomeUnknown: true
        default: false
        }
    }

    // MARK: - Message rows

    /// Header, avatar, attachments, reactions, and accessories around a body of the
    /// given height. Deterministic: same inputs produce identical frames.
    func messageLayout(for post: PostPresentation, width: CGFloat, bodyHeight: CGFloat,
                       renderer: MessageRenderer, exact: Bool = true) -> MessageRowLayout {
        var layout = MessageRowLayout()
        let isSystem: Bool
        if case .system = post.body { isSystem = true } else { isSystem = false }
        let showsHeader = !post.isContinuation && !isSystem
        let contentX = Self.contentLeading
        let contentWidth = Self.contentWidth(forLayoutWidth: width)
        var y = showsHeader ? Self.headerTopPadding : Self.continuationTopPadding

        if post.showsThreadContext {
            layout.threadContext = CGRect(x: contentX, y: y, width: contentWidth, height: fonts.metaLineHeight)
            y += fonts.metaLineHeight + 2
        }
        if showsHeader {
            layout.avatar = CGRect(x: Self.horizontalInset, y: y, width: Self.avatarSize, height: Self.avatarSize)
            layout.header = CGRect(x: contentX, y: y, width: contentWidth, height: fonts.authorLineHeight)
            y += fonts.authorLineHeight + 2
        }
        layout.body = CGRect(x: contentX, y: y, width: contentWidth, height: bodyHeight)
        y += bodyHeight

        if case .document(_, true) = post.body {
            y += Self.componentSpacing
            layout.showMore = CGRect(x: contentX, y: y, width: contentWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        }

        if let preview = post.linkPreview {
            y += Self.componentSpacing
            let card = linkPreviewLayout(preview, origin: CGPoint(x: contentX, y: y), contentWidth: contentWidth, exact: exact)
            layout.linkPreview = card
            y += card.frame.height
        }

        let files = post.files.prefix(Self.maximumDisplayedFiles)
        for file in files {
            y += Self.componentSpacing
            if Self.showsThumbnail(file) {
                let size = Self.thumbnailSize(for: file, contentWidth: contentWidth)
                layout.attachments.append(CGRect(x: contentX, y: y, width: size.width, height: size.height))
                y += size.height
            } else {
                let chipWidth = min(contentWidth, Self.fileChipMaximumWidth)
                layout.attachments.append(CGRect(x: contentX, y: y, width: chipWidth, height: Self.fileChipHeight))
                y += Self.fileChipHeight
            }
        }
        if post.files.count > files.count {
            y += Self.componentSpacing
            layout.attachmentOverflow = CGRect(x: contentX, y: y, width: contentWidth, height: fonts.metaLineHeight)
            y += fonts.metaLineHeight
        }

        if !post.reactions.isEmpty {
            y += Self.componentSpacing
            let chipHeight = reactionChipHeight
            var x = contentX
            var lineY = y
            let maxX = contentX + contentWidth
            let shown = post.reactions.prefix(Self.maximumDisplayedReactions)
            for reaction in shown {
                let chipWidth = min(reactionChipWidth(reaction, renderer: renderer), contentWidth)
                if x > contentX, x + chipWidth > maxX {
                    x = contentX
                    lineY += chipHeight + Self.chipSpacing
                }
                layout.reactions.append(CGRect(x: x, y: lineY, width: chipWidth, height: chipHeight))
                x += chipWidth + Self.chipSpacing
            }
            if post.reactions.count > shown.count {
                let text = NSAttributedString(string: TimelineStrings.moreReactions(post.reactions.count - shown.count),
                                              attributes: [.font: fonts.meta])
                let overflowWidth = DrawnText.width(of: text) + 8
                if x > contentX, x + overflowWidth > maxX {
                    x = contentX
                    lineY += chipHeight + Self.chipSpacing
                }
                layout.reactionOverflow = CGRect(x: x, y: lineY, width: overflowWidth, height: chipHeight)
            }
            y = lineY + chipHeight
        }

        if post.replyCount > 0 {
            y += Self.componentSpacing
            layout.replies = CGRect(x: contentX, y: y, width: contentWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        }

        if let state = post.sendState {
            y += Self.componentSpacing
            var pending = PendingLayout(status: .zero)
            var textX = contentX
            if Self.showsSpinner(state) {
                pending.spinner = CGRect(x: contentX, y: y + max(0, (fonts.metaLineHeight - Self.spinnerSize) / 2),
                                         width: Self.spinnerSize, height: Self.spinnerSize)
                textX += Self.spinnerSize + 6
            }
            let textWidth = max(Self.minimumContentWidth, contentX + contentWidth - textX)
            let textHeight = max(fonts.metaLineHeight, DrawnText.height(of: statusText(for: state), width: textWidth))
            pending.status = CGRect(x: textX, y: y, width: textWidth, height: textHeight)
            y += max(textHeight, pending.spinner == nil ? 0 : Self.spinnerSize)
            if Self.offersRetry(state) || Self.offersUploadDiscard(state) {
                y += 4
                if Self.offersRetry(state), post.pendingID != nil {
                    pending.retry = CGRect(x: contentX, y: y, width: 0, height: Self.buttonHeight)
                }
                pending.discard = CGRect(x: contentX, y: y, width: 0, height: Self.buttonHeight)
                y += Self.buttonHeight
            }
            layout.pending = pending
        }

        y += Self.bottomPadding
        if let avatar = layout.avatar { y = max(y, avatar.maxY + Self.bottomPadding) }
        layout.height = ceil(y)
        return layout
    }

    // MARK: - Separator rows

    func dateSeparatorLayout(width: CGFloat) -> SeparatorRowLayout {
        let height = ceil(fonts.metaLineHeight + 20)
        return SeparatorRowLayout(height: height,
                                  label: CGRect(x: Self.horizontalInset, y: 10, width: max(0, width - 2 * Self.horizontalInset),
                                                height: fonts.metaLineHeight))
    }

    func unreadBoundaryLayout(width: CGFloat) -> SeparatorRowLayout {
        let height = ceil(fonts.metaLineHeight + 12)
        return SeparatorRowLayout(height: height,
                                  label: CGRect(x: Self.horizontalInset, y: 6, width: max(0, width - 2 * Self.horizontalInset),
                                                height: fonts.metaLineHeight))
    }

    func gapText(_ gap: GapPresentation) -> NSAttributedString? {
        let text: String
        switch gap.state {
        case .idle: return nil
        case .loading: text = gap.direction == .older ? TimelineStrings.loadingOlder : TimelineStrings.loadingNewer
        case .failed(let error): text = TimelineStrings.loadFailed(gap.direction, error)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
    }

    func gapLayout(_ gap: GapPresentation, width: CGFloat) -> SeparatorRowLayout {
        let textWidth = max(Self.minimumContentWidth, width - 2 * Self.horizontalInset)
        var layout = SeparatorRowLayout(height: 0)
        var y: CGFloat = 10
        switch gap.state {
        case .idle:
            layout.button = CGRect(x: Self.horizontalInset, y: y, width: textWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        case .loading:
            let textHeight = gapText(gap).map { DrawnText.height(of: $0, width: textWidth) } ?? 0
            layout.spinner = CGRect(x: Self.horizontalInset, y: y, width: Self.spinnerSize, height: Self.spinnerSize)
            layout.label = CGRect(x: Self.horizontalInset, y: y, width: textWidth, height: max(textHeight, Self.spinnerSize))
            y += max(textHeight, Self.spinnerSize)
        case .failed:
            let textHeight = gapText(gap).map { DrawnText.height(of: $0, width: textWidth) } ?? 0
            layout.label = CGRect(x: Self.horizontalInset, y: y, width: textWidth, height: textHeight)
            y += textHeight + 6
            layout.button = CGRect(x: Self.horizontalInset, y: y, width: textWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        }
        layout.height = ceil(y + 10)
        return layout
    }

    func historyStartText(_ name: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: TimelineStrings.historyStart(name), attributes: [
            .font: fonts.font(size: fonts.bodySize, bold: true, italic: false, mono: false),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
    }

    func historyStartLayout(channelName: String, width: CGFloat) -> SeparatorRowLayout {
        let textWidth = max(Self.minimumContentWidth, width - 2 * Self.horizontalInset)
        let textHeight = DrawnText.height(of: historyStartText(channelName), width: textWidth)
        return SeparatorRowLayout(height: ceil(textHeight + 32),
                                  label: CGRect(x: Self.horizontalInset, y: 16, width: textWidth, height: textHeight))
    }

    // MARK: - Estimates

    /// Cheap estimate for a body that has not been measured: counts characters per
    /// block without building attributed text. Linear in document size.
    func estimatedBodyHeight(_ body: MessageBody, contentWidth: CGFloat, budget: ResourceBudget) -> CGFloat {
        let bodyCharsPerLine = max(8, contentWidth / (fonts.bodySize * 0.52))
        let monoCharsPerLine = max(8, contentWidth / max(fonts.monoAdvance, 1))
        var lines: CGFloat = 0
        var extra: CGFloat = 0
        func textLines(_ length: Int, perLine: CGFloat) -> CGFloat { max(1, ceil(CGFloat(length) / perLine)) }

        switch body {
        case .document(let document, let collapsed):
            var remaining = collapsed ? budget.collapsedMessageCharacters : budget.maximumRenderedCharacters
            estimate(document.blocks, bodyPerLine: bodyCharsPerLine, monoPerLine: monoCharsPerLine,
                     lines: &lines, extra: &extra, remaining: &remaining, depth: 0)
            if document.blocks.count > 1 { extra += CGFloat(document.blocks.count - 1) * (fonts.bodyLineHeight * 0.5) }
        case .system(let text):
            lines = textLines(text.utf16.count, perLine: bodyCharsPerLine)
        case .deleted:
            lines = 1
        case .unsupported(let summary, let fallback):
            lines = textLines(summary.utf16.count, perLine: bodyCharsPerLine)
                + (fallback.isEmpty ? 0 : textLines(fallback.utf16.count, perLine: bodyCharsPerLine))
        }
        return ceil(max(1, lines) * fonts.bodyLineHeight + extra)
    }

    private func estimate(_ blocks: [MarkupBlock], bodyPerLine: CGFloat, monoPerLine: CGFloat, lines: inout CGFloat,
                          extra: inout CGFloat, remaining: inout Int, depth: Int) {
        for block in blocks {
            if remaining <= 0 { return }
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines):
                var length = 0
                var breaks = 0
                Self.count(inlines, length: &length, breaks: &breaks, depth: 0)
                remaining -= length
                lines += max(1, ceil(CGFloat(length) / bodyPerLine)) + CGFloat(breaks)
                if case .heading = block { extra += fonts.bodyLineHeight }
            case .codeBlock(_, let code):
                var codeLines: CGFloat = 0
                var lineLength = 0
                for unit in code.utf16 {
                    if unit == 0x0A {
                        codeLines += max(1, ceil(CGFloat(lineLength) / monoPerLine))
                        lineLength = 0
                    } else {
                        lineLength += 1
                    }
                }
                codeLines += max(1, ceil(CGFloat(lineLength) / monoPerLine))
                remaining -= code.utf16.count
                lines += codeLines
                extra += 12
            case .blockQuote(let children):
                if depth < MessageRenderer.maximumBlockDepth {
                    estimate(children, bodyPerLine: bodyPerLine * 0.95, monoPerLine: monoPerLine, lines: &lines,
                             extra: &extra, remaining: &remaining, depth: depth + 1)
                } else {
                    lines += 1
                }
            case .list(_, _, let items):
                for item in items {
                    estimate(item, bodyPerLine: bodyPerLine * 0.92, monoPerLine: monoPerLine, lines: &lines,
                             extra: &extra, remaining: &remaining, depth: depth + 1)
                    if item.isEmpty { lines += 1 }
                }
            case .table(_, let rows):
                lines += CGFloat(rows.count + 2)
            case .thematicBreak:
                lines += 1
            case .plainFallback(let text):
                remaining -= text.utf16.count
                lines += max(1, ceil(CGFloat(text.utf16.count) / monoPerLine))
            }
        }
    }

    private static func count(_ inlines: [MarkupInline], length: inout Int, breaks: inout Int, depth: Int) {
        for inline in inlines {
            switch inline {
            case .text(let text), .code(let text): length += text.utf16.count
            case .emphasis(let children), .strong(let children), .strikethrough(let children),
                 .link(_, let children):
                if depth < MessageRenderer.maximumInlineDepth {
                    count(children, length: &length, breaks: &breaks, depth: depth + 1)
                }
            case .mention(let name), .channelMention(let name), .hashtag(let name): length += name.utf16.count + 1
            case .emoji: length += 2
            case .lineBreak, .softBreak: breaks += 1
            }
        }
    }
}
