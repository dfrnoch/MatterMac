import AppKit

/// Root view of a conversation pane: accepts file drops anywhere over the timeline
/// and composer (like the official client) and hands them to the existing
/// attachment path, which enforces the budget, capability and permission rules.
final class ConversationDropView: NSView {
    /// Whether a drop would currently be accepted (attachments allowed here).
    var canAcceptFiles: () -> Bool = { false }
    var onFiles: ([URL]) -> Void = { _ in }
    var onLayout: () -> Void = {}

    override func layout() {
        super.layout()
        onLayout()
    }
    private let overlay = DropOverlayView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        overlay.isHidden = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== overlay else { return }
        // Keep the overlay above the content.
        if overlay.superview == nil {
            addSubview(overlay, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                overlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                overlay.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                overlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
        } else {
            addSubview(overlay, positioned: .above, relativeTo: subview)
        }
    }

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canAcceptFiles(), !fileURLs(sender).isEmpty else { return [] }
        overlay.isHidden = false
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        overlay.isHidden ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        overlay.isHidden = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        overlay.isHidden = true
        let urls = fileURLs(sender)
        guard canAcceptFiles(), !urls.isEmpty else { return false }
        onFiles(urls)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        overlay.isHidden = true
    }
}

private final class DropOverlayView: NSView {
    private let label = NSTextField(labelWithString: String(localized: "Drop files to attach"))
    private let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil) ?? NSImage())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        label.textColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(label.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // Drops are handled by the parent; the overlay never intercepts them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        path.lineWidth = 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.stroke()
    }
}
