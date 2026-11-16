import AppKit
import MatterMacModels
import MatterMacCore

/// The line above a reply in a channel timeline: a connector curving from the reply's
/// avatar up into a small avatar of the thread root's author, the author's name and the
/// start of the root's text. Pressing it opens the thread.
///
/// The frame starts at the avatar column (`TimelineRowMetrics.horizontalInset`); the
/// connector area is not interactive, so clicks there still select the row.
final class ReplyContextView: TimelinePressableView {
    var avatarImage: NSImage? { didSet { needsDisplay = true } }
    private var context: ReplyContextPresentation?
    private var nameFont: NSFont = .systemFont(ofSize: 11, weight: .semibold)
    private var previewFont: NSFont = .systemFont(ofSize: 11)
    private var drawsConnector = true
    private var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    static let avatarSize: CGFloat = 16
    static let connectorRadius: CGFloat = 6
    static let connectorWidth: CGFloat = 2

    /// Avatar column center and content start, relative to this view.
    private var connectorX: CGFloat { TimelineRowMetrics.avatarSize / 2 }
    private var contentX: CGFloat { TimelineRowMetrics.contentLeading - TimelineRowMetrics.horizontalInset }

    func configure(_ context: ReplyContextPresentation, fonts: TimelineFonts, drawsConnector: Bool) {
        self.context = context
        self.drawsConnector = drawsConnector
        nameFont = fonts.metaBold
        previewFont = fonts.meta
        let label = TimelineStrings.replyContextAccessibility(context)
        setAccessibilityLabel(label)
        setAccessibilityHelp(TimelineStrings.menuOpenThread)
        toolTip = TimelineStrings.menuOpenThread
        needsDisplay = true
    }

    func reset() {
        resetPressable()
        context = nil
        avatarImage = nil
        isHovered = false
    }

    // MARK: Hit testing and hover

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return local.x >= contentX - 2 ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: contentX - 2, y: 0, width: max(0, bounds.width - contentX + 2), height: bounds.height),
                      cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context else { return }
        if drawsConnector { drawConnector() }
        drawAtPressedOpacity { drawContent(context) }
    }

    private func drawConnector() {
        let midY = floor(bounds.midY) + 0.5
        let x = connectorX
        let radius = Self.connectorRadius
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: bounds.maxY))
        path.line(to: NSPoint(x: x, y: midY + radius))
        path.curve(to: NSPoint(x: x + radius, y: midY), controlPoint1: NSPoint(x: x, y: midY + radius * 0.45),
                   controlPoint2: NSPoint(x: x + radius * 0.45, y: midY))
        path.line(to: NSPoint(x: contentX - 4, y: midY))
        path.lineWidth = Self.connectorWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        TimelinePalette.replyConnector.setStroke()
        path.stroke()
    }

    private func drawContent(_ context: ReplyContextPresentation) {
        let size = Self.avatarSize
        let avatarRect = NSRect(x: contentX, y: floor((bounds.height - size) / 2), width: size, height: size)
        let circle = NSBezierPath(ovalIn: avatarRect)
        if let author = context.author {
            if let avatarImage {
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                avatarImage.draw(in: avatarRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                                 hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                TimelinePalette.avatarTint(for: author.userID.rawValue).withAlphaComponent(0.85).setFill()
                circle.fill()
                let initials = NSAttributedString(string: AvatarView.initials(for: author.displayName).prefix(1).description,
                                                  attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .bold),
                                                               .foregroundColor: NSColor.white])
                let textSize = initials.size()
                initials.draw(at: NSPoint(x: avatarRect.midX - textSize.width / 2, y: avatarRect.midY - textSize.height / 2))
            }
        } else {
            TimelinePalette.placeholderFill.setFill()
            circle.fill()
            if let symbol = NSImage.symbol("arrowshape.turn.up.left.fill", pointSize: 8, color: .secondaryLabelColor) {
                let symbolSize = symbol.size
                symbol.draw(in: NSRect(x: avatarRect.midX - symbolSize.width / 2, y: avatarRect.midY - symbolSize.height / 2,
                                       width: symbolSize.width, height: symbolSize.height))
            }
        }

        let previewColor: NSColor = isHovered ? .labelColor : .secondaryLabelColor
        let text = NSMutableAttributedString()
        if let author = context.author {
            text.append(NSAttributedString(string: author.displayName, attributes: [
                .font: nameFont, .foregroundColor: isHovered ? NSColor.labelColor : TimelinePalette.replyName,
            ]))
            text.append(NSAttributedString(string: "  ", attributes: [.font: previewFont]))
        }
        let previewFont: NSFont
        switch context.preview {
        case .text: previewFont = self.previewFont
        default: previewFont = NSFontManager.shared.convert(self.previewFont, toHaveTrait: .italicFontMask)
        }
        text.append(NSAttributedString(string: TimelineStrings.replyContextPreview(context.preview), attributes: [
            .font: previewFont, .foregroundColor: previewColor,
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        let textX = avatarRect.maxX + 5
        let lineHeight = ceil(max(nameFont.ascender - nameFont.descender, previewFont.ascender - previewFont.descender))
        text.draw(with: NSRect(x: textX, y: floor((bounds.height - lineHeight) / 2), width: max(0, bounds.width - textX),
                               height: lineHeight + 2),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The reply summary under a thread root: "N replies · Last reply 14:05 ›" in a
/// rounded chip. Pressing it opens the thread.
final class ThreadSummaryView: TimelinePressableView {
    private var title = NSAttributedString()
    private var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    static let horizontalPadding: CGFloat = 8
    static let iconSize: CGFloat = 14
    static let spacing: CGFloat = 6

    func configure(replyCount: Int, lastReplyAt: MattermostTimestamp?, rootCreatedAt: MattermostTimestamp,
                   fonts: TimelineFonts) {
        title = Self.title(replyCount: replyCount, lastReplyAt: lastReplyAt, rootCreatedAt: rootCreatedAt, fonts: fonts)
        setAccessibilityLabel(title.string)
        setAccessibilityHelp(TimelineStrings.menuOpenThread)
        toolTip = TimelineStrings.menuOpenThread
        needsDisplay = true
    }

    static func title(replyCount: Int, lastReplyAt: MattermostTimestamp?, rootCreatedAt: MattermostTimestamp,
                      fonts: TimelineFonts) -> NSAttributedString {
        let text = NSMutableAttributedString(string: TimelineStrings.replies(replyCount), attributes: [
            .font: fonts.metaBold, .foregroundColor: NSColor.linkColor,
        ])
        if let lastReplyAt {
            text.append(NSAttributedString(string: "   " + TimelineStrings.lastReply(lastReplyAt, rootCreatedAt: rootCreatedAt),
                                           attributes: [.font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    /// Width that fits the icon, title and chevron.
    var fittingWidth: CGFloat {
        ceil(2 * Self.horizontalPadding + Self.iconSize + Self.spacing + DrawnText.width(of: title) + Self.spacing + 8)
    }

    func reset() {
        resetPressable()
        title = NSAttributedString()
        isHovered = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        drawAtPressedOpacity { drawChip() }
    }

    private func drawChip() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isHovered ? TimelinePalette.reactionBorder : TimelinePalette.reactionBackground).setFill()
        path.fill()
        TimelinePalette.reactionBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        var x = Self.horizontalPadding
        if let icon = NSImage.symbol("bubble.left.and.bubble.right.fill", pointSize: 10, color: .secondaryLabelColor) {
            let size = icon.size
            icon.draw(in: NSRect(x: x + (Self.iconSize - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height))
        }
        x += Self.iconSize + Self.spacing
        let titleHeight = ceil(title.size().height)
        let chevronSpace = Self.spacing + 8
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let truncating = NSMutableAttributedString(attributedString: title)
        truncating.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: truncating.length))
        truncating.draw(with: NSRect(x: x, y: floor((bounds.height - titleHeight) / 2),
                                     width: max(0, bounds.width - x - Self.horizontalPadding - chevronSpace),
                                     height: titleHeight),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let chevron = NSImage.symbol("chevron.right", pointSize: 9, color: .tertiaryLabelColor) {
            let size = chevron.size
            chevron.draw(in: NSRect(x: bounds.width - Self.horizontalPadding - size.width,
                                    y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

private extension NSImage {
    /// The symbol drawn in `color` (symbols are templates and draw black otherwise).
    static func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
    }
}
