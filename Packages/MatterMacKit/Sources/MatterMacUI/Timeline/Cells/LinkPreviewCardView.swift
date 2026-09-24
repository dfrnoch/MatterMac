import AppKit
import MatterMacModels
import MatterMacCore

/// Frames of a link preview card, relative to the card's own bounds (flipped).
struct LinkPreviewLayout: Equatable {
    var frame: CGRect
    var siteName: CGRect?
    var title: CGRect?
    var description: CGRect?
    /// Thumbnail (website card) or the whole image (direct image link).
    var image: CGRect?
}

extension TimelineRowMetrics {
    static let linkPreviewMaximumWidth: CGFloat = 460
    static let linkPreviewPadding: CGFloat = 8
    static let linkPreviewAccentWidth: CGFloat = 3
    static let linkPreviewTitleLines: CGFloat = 2
    static let linkPreviewDescriptionLines: CGFloat = 3

    func linkPreviewSiteText(_ preview: LinkPreview) -> NSAttributedString {
        let site = preview.siteName.isEmpty ? preview.host : preview.siteName
        return NSAttributedString(string: site, attributes: [
            .font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: Self.truncating,
        ])
    }

    func linkPreviewTitleText(_ preview: LinkPreview) -> NSAttributedString {
        var title = preview.title
        if title.isEmpty {
            // A direct image link without a proxied image: show the file name.
            let last = preview.link.url.lastPathComponent
            title = last.isEmpty || last == "/" ? preview.link.url.absoluteString : last
        }
        return NSAttributedString(string: title, attributes: [
            .font: fonts.font(size: fonts.bodySize, bold: true, italic: false, mono: false),
            .foregroundColor: NSColor.linkColor, .paragraphStyle: Self.wrapping,
        ])
    }

    func linkPreviewDescriptionText(_ preview: LinkPreview) -> NSAttributedString? {
        guard !preview.description.isEmpty else { return nil }
        return NSAttributedString(string: preview.description, attributes: [
            .font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: Self.wrapping,
        ])
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private static let wrapping: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    /// Deterministic card layout at `origin` for the content width. `exact == false`
    /// estimates text heights from character counts (used for unmeasured rows).
    func linkPreviewLayout(_ preview: LinkPreview, origin: CGPoint, contentWidth: CGFloat, exact: Bool) -> LinkPreviewLayout {
        if preview.kind == .image, let image = preview.image {
            let size = Self.imageSize(width: image.width, height: image.height, contentWidth: contentWidth)
            return LinkPreviewLayout(frame: CGRect(origin: origin, size: size),
                                     image: CGRect(origin: .zero, size: size))
        }
        let padding = Self.linkPreviewPadding
        let width = min(contentWidth, Self.linkPreviewMaximumWidth)
        let thumb = preview.image == nil ? 0 : TimelineMetrics.linkPreviewThumbnailSize
        let textX = Self.linkPreviewAccentWidth + padding + 2
        let textWidth = max(Self.minimumContentWidth / 2, width - textX - padding - (thumb > 0 ? thumb + padding : 0))
        var y = padding
        var layout = LinkPreviewLayout(frame: .zero)
        layout.siteName = CGRect(x: textX, y: y, width: textWidth, height: fonts.metaLineHeight)
        y += fonts.metaLineHeight + 2
        let title = linkPreviewTitleText(preview)
        let titleLineHeight = fonts.bodyLineHeight
        let titleHeight = min(textHeight(title, width: textWidth, lineHeight: titleLineHeight, exact: exact),
                              Self.linkPreviewTitleLines * titleLineHeight)
        layout.title = CGRect(x: textX, y: y, width: textWidth, height: titleHeight)
        y += titleHeight
        if let description = linkPreviewDescriptionText(preview) {
            y += 2
            let height = min(textHeight(description, width: textWidth, lineHeight: fonts.metaLineHeight, exact: exact),
                             Self.linkPreviewDescriptionLines * fonts.metaLineHeight)
            layout.description = CGRect(x: textX, y: y, width: textWidth, height: height)
            y += height
        }
        if thumb > 0 {
            layout.image = CGRect(x: width - padding - thumb, y: padding, width: thumb, height: thumb)
            y = max(y, padding + thumb)
        }
        layout.frame = CGRect(x: origin.x, y: origin.y, width: width, height: ceil(y + padding))
        return layout
    }

    private func textHeight(_ text: NSAttributedString, width: CGFloat, lineHeight: CGFloat, exact: Bool) -> CGFloat {
        guard text.length > 0 else { return 0 }
        if exact { return max(lineHeight, DrawnText.height(of: text, width: width)) }
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? fonts.meta
        let perLine = max(8, width / (font.pointSize * 0.52))
        return ceil(max(1, ceil(CGFloat(text.length) / perLine)) * lineHeight)
    }

    static func imageSize(width: Int?, height: Int?, contentWidth: CGFloat) -> CGSize {
        let file = FileInfo(id: FileID(unchecked: "linkpreviewzzzzzzzzzzzzzz"), name: "", width: width, height: height)
        return thumbnailSize(for: file, contentWidth: contentWidth)
    }
}

/// A compact, native link preview card (server metadata only): site name, bold title
/// (two lines), description (three lines) and an optional small thumbnail, or a single
/// image for direct image links. Clicking opens the link under the safe-link policy.
final class LinkPreviewCardView: TimelinePressableView {
    private(set) var preview: LinkPreview?
    private var layout = LinkPreviewLayout(frame: .zero)
    private var siteText = NSAttributedString()
    private var titleText = NSAttributedString()
    private var descriptionText: NSAttributedString?
    private(set) var image: NSImage?
    weak var host: (any TimelineCellHost)?

    func configure(_ preview: LinkPreview, layout: LinkPreviewLayout, metrics: TimelineRowMetrics, image: NSImage?) {
        self.preview = preview
        self.layout = layout
        siteText = metrics.linkPreviewSiteText(preview)
        titleText = metrics.linkPreviewTitleText(preview)
        descriptionText = metrics.linkPreviewDescriptionText(preview)
        self.image = image
        toolTip = preview.link.url.absoluteString
        setAccessibilityLabel(TimelineStrings.linkPreviewAccessibility(preview))
        setAccessibilityRole(.link)
        needsDisplay = true
    }

    func setImage(_ image: NSImage?) {
        self.image = image
        needsDisplay = true
    }

    func reset() {
        resetPressable()
        preview = nil
        image = nil
        siteText = NSAttributedString()
        titleText = NSAttributedString()
        descriptionText = nil
    }

    var displayedTitle: String { titleText.string }
    var displayedSite: String { siteText.string }

    override func menu(for event: NSEvent) -> NSMenu? {
        var items: [NSMenuItem] = []
        if onPress != nil {
            let open = NSMenuItem(title: TimelineStrings.actionOpenLink, action: #selector(openFromMenu(_:)), keyEquivalent: "")
            open.target = self
            items.append(open)
            let copy = NSMenuItem(title: TimelineStrings.menuCopyLinkAddress, action: #selector(copyFromMenu(_:)),
                                  keyEquivalent: "")
            copy.target = self
            items.append(copy)
        }
        return host?.contextMenu(forRowContaining: self, leadingItems: items) ?? super.menu(for: event)
    }

    @objc private func openFromMenu(_ sender: Any?) { onPress?() }
    @objc private func copyFromMenu(_ sender: Any?) {
        guard let url = preview?.link.url else { return }
        host?.performPrepared(.copyLink(url))
    }

    override func draw(_ dirtyRect: NSRect) {
        drawAtPressedOpacity { drawCard() }
    }

    private func drawCard() {
        guard let preview else { return }
        if preview.kind == .image, layout.image == bounds {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            TimelinePalette.placeholderFill.setFill()
            bounds.fill()
            if let image { image.draw(in: aspectFill(image.size, in: bounds), from: .zero, operation: .sourceOver, fraction: 1,
                                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue]) }
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        TimelinePalette.reactionBackground.setFill()
        path.fill()
        TimelinePalette.reactionBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        TimelinePalette.linkPreviewAccent.setFill()
        NSRect(x: 0, y: 0, width: TimelineRowMetrics.linkPreviewAccentWidth, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let truncate: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        if let frame = layout.siteName { siteText.draw(with: frame, options: truncate, context: nil) }
        if let frame = layout.title { titleText.draw(with: frame, options: truncate, context: nil) }
        if let frame = layout.description, let descriptionText { descriptionText.draw(with: frame, options: truncate, context: nil) }
        if let frame = layout.image {
            let clip = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            TimelinePalette.placeholderFill.setFill()
            frame.fill()
            if let image {
                image.draw(in: aspectFill(image.size, in: frame), from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func aspectFill(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
