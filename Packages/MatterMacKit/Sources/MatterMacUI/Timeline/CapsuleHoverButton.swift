import AppKit

/// A borderless button for floating glass bars: on hover and press it shows a soft
/// capsule behind its content, matching the capsule bar, instead of the square
/// accessory-bar bezel.
final class CapsuleHoverButton: NSButton {
    /// Highlight tint; `nil` uses the label color.
    var highlightColor: NSColor?
    private var isHovered = false {
        didSet { if oldValue != isHovered { updateBackground() } }
    }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override var isEnabled: Bool {
        didSet { updateBackground() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        let alpha: CGFloat = !isEnabled ? 0 : isHighlighted ? 0.2 : isHovered ? 0.11 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = alpha == 0 ? nil
                : (highlightColor ?? .labelColor).withAlphaComponent(alpha).cgColor
        }
    }
}
