import AppKit
import ImageIO
import UniformTypeIdentifiers
import MatterMacModels
import MatterMacCore

/// What cells need from their controller. Implemented by `TimelineViewController`; held
/// weakly by cells (a cell never outlives its table, but it must not pin the controller).
protocol TimelineCellHost: AnyObject {
    func perform(_ action: TimelineAction)
    /// Performs a user-chosen action, first writing pasteboard content it implies
    /// (Copy Link). Used by menus, the hover bar and accessibility actions.
    func performPrepared(_ action: TimelineAction)
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
    /// Control-Return: the selected row's actions menu. Returns `false` if none.
    func presentActionsMenu() -> Bool
    func handleEscapeKey() -> Bool
    func forwardKeyToTable(_ event: NSEvent)
    func contextMenu(for textView: NSTextView, event: NSEvent, link: URL?) -> NSMenu?
    /// The row's context menu for a non-text element, after `leadingItems`.
    func contextMenu(forRowContaining view: NSView, leadingItems: [NSMenuItem]) -> NSMenu?
    /// Space on the selected row previews its first image. Returns `false` if none.
    func handleSpaceKey() -> Bool
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

    override func accessibilityLabel() -> String? { onPress == nil ? nil : attributedText.string }

    /// Optional click action (author names open the profile card).
    var onPress: (() -> Void)? {
        didSet {
            setAccessibilityRole(onPress == nil ? .staticText : .button)
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if onPress == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let onPress else { return super.mouseUp(with: event) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    override func resetCursorRects() {
        if onPress != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// 32 pt round avatar: the image when available, otherwise initials on a stable tint.
final class AvatarView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var initials = "" { didSet { needsDisplay = true } }
    var tint: NSColor = .systemGray { didSet { needsDisplay = true } }
    /// Optional click action (opens the author's profile card).
    var onPress: (() -> Void)? {
        didSet {
            setAccessibilityRole(onPress == nil ? .image : .button)
            window?.invalidateCursorRects(for: self)
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        if onPress == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let onPress else { return super.mouseUp(with: event) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    override func resetCursorRects() {
        if onPress != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

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
/// click, accessibility press, and Return/Space (when Full Keyboard Access lets the
/// element take focus) invoke `onPress`.
class TimelinePressableView: NSView {
    var onPress: (() -> Void)?
    private var isPressed = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool {
        guard onPress != nil, NSApplication.shared.isFullKeyboardAccessEnabled else { return false }
        // Keyboard focus traversal only: a click keeps focus (and arrow keys) on the timeline.
        return NSApplication.shared.currentEvent?.type != .leftMouseDown
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: min(6, bounds.height / 2), yRadius: min(6, bounds.height / 2)).fill()
    }

    override func keyDown(with event: NSEvent) {
        let modified = !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if !modified, [36, 76, 49].contains(event.keyCode), let onPress { // Return, Enter, Space
            onPress()
            return
        }
        super.keyDown(with: event)
    }

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

    /// Draws `body` at the pressed opacity through a transparency layer. Never call
    /// `withAlphaComponent` on a `TimelinePalette` color for this: it *replaces* the
    /// palette's translucent alpha (a 10 % label tint became opaque white in Dark Mode).
    func drawAtPressedOpacity(_ body: () -> Void) {
        guard pressedAlpha < 1, let context = NSGraphicsContext.current?.cgContext else { return body() }
        context.saveGState()
        context.setAlpha(pressedAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }

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

/// Measurement shared by row layout (`TimelineRowMetrics.reactionChipWidth`) and the
/// chip's drawing, so the reserved frame always fits what is drawn.
struct ReactionChipMetrics: Equatable {
    /// Leading/trailing inset; wide enough that the emoji clears the pill's rounded cap.
    static let horizontalPadding: CGFloat = 9
    static let spacing: CGFloat = 4

    /// Advance width of the emoji or `:name:` fallback, or its ink width if wider.
    let emojiWidth: CGFloat
    /// Horizontal offset of the emoji's ink from its origin (negative: ink starts left
    /// of the origin, as some Apple Color Emoji glyphs do).
    let emojiInkMinX: CGFloat
    let countWidth: CGFloat

    init(emoji: String, count: String, fonts: TimelineFonts, custom: Bool = false) {
        let emojiText = NSAttributedString(string: emoji, attributes: [.font: fonts.body])
        let ink = emoji.isEmpty ? .zero : emojiText.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
        emojiInkMinX = custom ? 0 : min(0, floor(ink.minX))
        emojiWidth = custom ? ceil(fonts.body.ascender - fonts.body.descender) : max(DrawnText.width(of: emojiText), ceil(ink.maxX) - emojiInkMinX)
        countWidth = DrawnText.width(of: NSAttributedString(string: count, attributes: [.font: fonts.metaBold]))
    }

    var width: CGFloat { ceil(2 * Self.horizontalPadding + emojiWidth + Self.spacing + countWidth) }
}

final class ReactionChipView: TimelinePressableView {
    var image: NSImage? { didSet { needsDisplay = true } }
    private(set) var emoji = ""
    private(set) var countText = ""
    private(set) var isSelectedByCurrentUser = false
    private var emojiFont: NSFont = .systemFont(ofSize: 13)
    private var countFont: NSFont = .systemFont(ofSize: 11, weight: .semibold)
    private(set) var metrics: ReactionChipMetrics?

    func configure(emoji: String, count: Int, includesCurrentUser: Bool, fonts: TimelineFonts, custom: Bool = false) {
        self.emoji = emoji
        self.countText = "\(count)"
        self.isSelectedByCurrentUser = includesCurrentUser
        self.emojiFont = fonts.body
        self.countFont = fonts.metaBold
        metrics = ReactionChipMetrics(emoji: emoji, count: countText, fonts: fonts, custom: custom)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let metrics else { return }
        drawAtPressedOpacity {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: (bounds.height - 1) / 2,
                                    yRadius: (bounds.height - 1) / 2)
            (isSelectedByCurrentUser ? TimelinePalette.reactionSelectedBackground : TimelinePalette.reactionBackground)
                .setFill()
            path.fill()
            (isSelectedByCurrentUser ? TimelinePalette.reactionSelectedBorder : TimelinePalette.reactionBorder).setStroke()
            path.lineWidth = 1
            path.stroke()
            let emojiText = NSAttributedString(string: emoji, attributes: [
                .font: emojiFont, .foregroundColor: NSColor.labelColor,
            ])
            let countText = NSAttributedString(string: countText, attributes: [
                .font: countFont,
                .foregroundColor: isSelectedByCurrentUser ? TimelinePalette.reactionSelectedCount
                                                          : TimelinePalette.reactionCount,
            ])
            var x = ReactionChipMetrics.horizontalPadding
            if let image {
                image.draw(in: NSRect(x: x, y: (bounds.height - metrics.emojiWidth) / 2,
                                     width: metrics.emojiWidth, height: metrics.emojiWidth),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                emojiText.draw(with: NSRect(x: x - metrics.emojiInkMinX, y: floor((bounds.height - emojiText.size().height) / 2),
                                           width: metrics.emojiWidth, height: bounds.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            x += metrics.emojiWidth + ReactionChipMetrics.spacing
            countText.draw(at: NSPoint(x: x, y: floor((bounds.height - countText.size().height) / 2)))
        }
    }

    func reset() {
        resetPressable()
        image = nil
        emoji = ""
        countText = ""
        isSelectedByCurrentUser = false
        metrics = nil
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
        drawAtPressedOpacity { drawChip() }
    }

    private func drawChip() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        TimelinePalette.reactionBackground.setFill()
        path.fill()
        TimelinePalette.reactionBorder.setStroke()
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
    weak var host: (any TimelineCellHost)?
    /// Explicit save (context menu and accessibility action); `onPress` previews.
    var onSave: (() -> Void)? {
        didSet {
            setAccessibilityCustomActions(onSave == nil ? nil : [
                NSAccessibilityCustomAction(name: TimelineStrings.saveAttachment) { [weak self] in
                    self?.onSave?()
                    return self?.onSave != nil
                },
            ])
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var items: [NSMenuItem] = []
        if onPress != nil {
            let item = NSMenuItem(title: TimelineStrings.openImage, action: #selector(openFromMenu(_:)), keyEquivalent: "")
            item.target = self
            items.append(item)
        }
        if onSave != nil {
            let item = NSMenuItem(title: TimelineStrings.saveAttachment, action: #selector(saveFromMenu(_:)), keyEquivalent: "")
            item.target = self
            items.append(item)
        }
        return host?.contextMenu(forRowContaining: self, leadingItems: items) ?? super.menu(for: event)
    }

    @objc private func openFromMenu(_ sender: Any?) { onPress?() }
    @objc private func saveFromMenu(_ sender: Any?) { onSave?() }

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
        onSave = nil
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
