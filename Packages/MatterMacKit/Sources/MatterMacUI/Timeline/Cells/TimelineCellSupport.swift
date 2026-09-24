import AppKit
import ImageIO
import UniformTypeIdentifiers
import MatterMacModels
import MatterMacCore

/// What cells need from their controller. Implemented by `TimelineViewController`; held
/// weakly by cells (a cell never outlives its table, but it must not pin the controller).
protocol TimelineCellHost: AnyObject {
    func perform(_ action: TimelineAction)
    func image(for request: TimelineImageRequest) -> NSImage?
    func registerImageDemand(_ request: TimelineImageRequest)
    func unregisterImageDemand(_ request: TimelineImageRequest)
    func requestOlderFromGapButton()
    func requestNewerFromGapButton()
    /// A mouse-down landed in a message body; the host selects that row.
    func bodyTextViewReceivedMouseDown(_ textView: NSTextView)
    /// Cmd-C without a text selection. Returns `false` if nothing is selected.
    func copySelectedMessages() -> Bool
    func canCopySelectedMessages() -> Bool
    func handleReturnKey() -> Bool
    func handleEscapeKey() -> Bool
    func forwardKeyToTable(_ event: NSEvent)
    func contextMenu(for textView: NSTextView, event: NSEvent, link: URL?) -> NSMenu?
    var renderer: MessageRenderer { get }
    var rowMetrics: TimelineRowMetrics { get }
}

/// A single- or multi-line text view drawn with NSStringDrawing. Measured by
/// `DrawnText` with identical options so its frame always fits its text. Exposed to
/// accessibility as static text.
final class TimelineLabel: NSView {
    var attributedText = NSAttributedString() {
        didSet {
            needsDisplay = true
            setAccessibilityValue(attributedText.string)
        }
    }

    /// When `true`, text is truncated at the tail on one line.
    var isSingleLine = true

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard attributedText.length > 0 else { return }
        var options = DrawnText.options
        if isSingleLine { options.insert(.truncatesLastVisibleLine) }
        var text = attributedText
        if isSingleLine {
            let truncated = NSMutableAttributedString(attributedString: attributedText)
            let paragraph = (attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            truncated.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: truncated.length))
            text = truncated
        }
        text.draw(with: bounds, options: options, context: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func accessibilityLabel() -> String? { nil }
}

/// 32 pt round avatar: the image when available, otherwise initials on a stable tint.
final class AvatarView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var initials = "" { didSet { needsDisplay = true } }
    var tint: NSColor = .systemGray { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds)
        if let image {
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        tint.withAlphaComponent(0.85).setFill()
        circle.fill()
        guard !initials.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: floor(bounds.height * 0.4), weight: .semibold)
        let text = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.joined()
    }
}

/// Base for custom-drawn clickable elements (reaction chips, file chips, thumbnails):
/// click and accessibility press both invoke `onPress`.
class TimelinePressableView: NSView {
    var onPress: (() -> Void)?
    private var isPressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    var pressedAlpha: CGFloat { isPressed ? 0.6 : 1 }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func resetPressable() {
        onPress = nil
        isPressed = false
        toolTip = nil
        setAccessibilityLabel(nil)
    }
}

final class ReactionChipView: TimelinePressableView {
    var emoji = ""
    var countText = ""
    var isSelectedByCurrentUser = false
    var emojiFont: NSFont = .systemFont(ofSize: 13)
    var countFont: NSFont = .systemFont(ofSize: 11, weight: .semibold)

    func configure(emoji: String, count: Int, includesCurrentUser: Bool, fonts: TimelineFonts) {
        self.emoji = emoji
        self.countText = "\(count)"
        self.isSelectedByCurrentUser = includesCurrentUser
        self.emojiFont = fonts.body
        self.countFont = fonts.metaBold
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2,
                                yRadius: bounds.height / 2)
        (isSelectedByCurrentUser ? TimelinePalette.reactionSelectedBackground : TimelinePalette.reactionBackground)
            .withAlphaComponent(pressedAlpha).setFill()
        path.fill()
        if isSelectedByCurrentUser {
            TimelinePalette.reactionSelectedBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let emojiText = NSAttributedString(string: emoji, attributes: [.font: emojiFont])
        let countText = NSAttributedString(string: countText, attributes: [
            .font: countFont,
            .foregroundColor: isSelectedByCurrentUser ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
        ])
        let emojiSize = emojiText.size()
        let countSize = countText.size()
        var x: CGFloat = 8
        emojiText.draw(at: NSPoint(x: x, y: (bounds.height - emojiSize.height) / 2))
        x += ceil(emojiSize.width) + 4
        countText.draw(at: NSPoint(x: x, y: (bounds.height - countSize.height) / 2))
    }
}

final class FileChipView: TimelinePressableView {
    private var icon: NSImage?
    private var name = ""
    private var detail = ""
    private var nameFont: NSFont = .systemFont(ofSize: 13)
    private var detailFont: NSFont = .systemFont(ofSize: 11)

    func configure(file: FileInfo, fonts: TimelineFonts) {
        // Icon from the file-name extension's type only; the file is never accessed.
        let type = UTType(filenameExtension: file.fileExtension.isEmpty
                          ? (file.name as NSString).pathExtension : file.fileExtension) ?? .data
        icon = NSWorkspace.shared.icon(for: type)
        name = file.name
        detail = TimelineStrings.fileSize(file.size)
        nameFont = fonts.body
        detailFont = fonts.meta
        setAccessibilityLabel(TimelineStrings.fileAccessibility(name: file.name, size: detail))
        toolTip = file.name
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        TimelinePalette.reactionBackground.withAlphaComponent(pressedAlpha).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let iconRect = NSRect(x: 8, y: (bounds.height - 32) / 2, width: 32, height: 32)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let textX = iconRect.maxX + 8
        let textWidth = max(0, bounds.width - textX - 8)
        let nameText = NSAttributedString(string: name, attributes: [
            .font: nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        let detailText = NSAttributedString(string: detail, attributes: [
            .font: detailFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
        let nameHeight = ceil(nameText.size().height)
        let detailHeight = ceil(detailText.size().height)
        let top = (bounds.height - nameHeight - detailHeight) / 2
        nameText.draw(with: NSRect(x: textX, y: top, width: textWidth, height: nameHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        detailText.draw(with: NSRect(x: textX, y: top + nameHeight, width: textWidth, height: detailHeight),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    func reset() {
        resetPressable()
        icon = nil
        name = ""
        detail = ""
    }
}

/// Image attachment with its space reserved from the server-provided dimensions. Shows
/// a placeholder (or the tiny server mini preview) until the pipeline supplies a
/// downsampled thumbnail.
final class ImageThumbnailView: TimelinePressableView {
    private(set) var image: NSImage?
    private var miniPreview: NSImage?

    /// Mini previews are tiny JPEGs; anything larger is ignored rather than decoded.
    static let maximumMiniPreviewBytes = 16 * 1_024
    static let miniPreviewPixels = 48

    func configure(file: FileInfo, image: NSImage?) {
        self.image = image
        miniPreview = image == nil ? Self.decodeMiniPreview(file.miniPreview) : nil
        setAccessibilityLabel(TimelineStrings.imageAccessibility(name: file.name))
        toolTip = file.name
        needsDisplay = true
    }

    func setImage(_ image: NSImage?) {
        self.image = image
        if image != nil { miniPreview = nil }
        needsDisplay = true
    }

    func reset() {
        resetPressable()
        image = nil
        miniPreview = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let shown = image ?? miniPreview {
            TimelinePalette.placeholderFill.setFill()
            bounds.fill()
            shown.draw(in: aspectFill(shown.size), from: .zero, operation: .sourceOver, fraction: pressedAlpha,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            TimelinePalette.placeholderFill.setFill()
            bounds.fill()
            if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
               bounds.width >= 32, bounds.height >= 32 {
                let configured = symbol.withSymbolConfiguration(.init(pointSize: 22, weight: .regular)
                    .applying(.init(hierarchicalColor: .tertiaryLabelColor))) ?? symbol
                let size = configured.size
                configured.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                           width: size.width, height: size.height),
                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func aspectFill(_ size: NSSize) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// Decodes the server's mini preview with Image I/O, downsampled to a few pixels.
    static func decodeMiniPreview(_ data: Data?) -> NSImage? {
        guard let data, !data.isEmpty, data.count <= maximumMiniPreviewBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: miniPreviewPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// Small borderless text button (link-colored) used for "Show more", reply counts, and
/// pending/gap actions.
final class TimelineTextButton: NSButton {
    var onPress: (() -> Void)?

    convenience init(style: Style) {
        self.init(frame: .zero)
        self.style = style
        target = self
        action = #selector(pressed)
        applyStyle()
    }

    enum Style { case link, bordered }
    private var style: Style = .link

    private func applyStyle() {
        switch style {
        case .link:
            isBordered = false
            contentTintColor = .linkColor
            setButtonType(.momentaryChange)
        case .bordered:
            bezelStyle = .push
            controlSize = .small
        }
        font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    func configure(title: String, font: NSFont) {
        self.title = title
        self.font = font
        setAccessibilityLabel(title)
    }

    @objc private func pressed() { onPress?() }

    func reset() {
        onPress = nil
        title = ""
    }

    var fittingWidth: CGFloat { ceil(intrinsicContentSize.width) }
}
