import AppKit
import MatterMacModels
import MatterMacCore

/// In-memory viewer for one image attachment, opened explicitly from the timeline.
///
/// - The image comes from the bounded `ImagePipeline` (server preview rendition,
///   downsampled to the screen size and at most `maximumImagePixelDimension`); its
///   decoded bytes stay charged through the `Decoded` lease until the window closes.
/// - No disk cache, Quick Look, or temporary file. "Save…" uses the conversation's
///   explicit attachment-download path.
/// - Escape and ⌘W close; closing cancels the fetch and releases the image.
final class ImageViewerWindowController: NSWindowController, NSWindowDelegate {
    enum State: Equatable { case loading, loaded, failed }

    let file: FileInfo
    private(set) var state: State = .loading
    private(set) var lease: ImagePipeline.Decoded?
    private var task: Task<Void, Never>?
    let imageView = NSImageView()
    let spinner = NSProgressIndicator()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let saveButton = NSButton(title: String(localized: "Save…"), target: nil, action: nil)
    var onSave: ((FileInfo, NSWindow) -> Void)?
    var onClose: (() -> Void)?

    static let minimumContentSize = NSSize(width: 320, height: 240)
    /// Tests keep the viewer off screen (it is still created, loaded and closed).
    static var isPresentationSuppressedForTesting = false
    static let loadingText = String(localized: "Loading image…")
    static let failureText = String(localized: """
        The image couldn’t be shown. The server may not provide a preview, the connection may have failed, \
        or MatterMac’s image memory limit is in use by other images. You can still save the attachment.
        """)

    init(file: FileInfo) {
        self.file = file
        let panel = ImageViewerPanel(contentRect: NSRect(origin: .zero, size: Self.minimumContentSize),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .documentWindow
        panel.tabbingMode = .disallowed
        panel.title = file.name
        panel.contentMinSize = Self.minimumContentSize
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { task?.cancel() }

    private func buildContent(in panel: NSPanel) {
        let content = NSView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.isEditable = false
        imageView.setAccessibilityLabel(TimelineStrings.imageAccessibility(name: file.name))
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = Self.loadingText
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.bezelStyle = .push
        saveButton.setAccessibilityLabel(TimelineStrings.saveAttachment)
        saveButton.toolTip = TimelineStrings.saveAttachment
        let status = NSStackView(views: [spinner, messageLabel])
        status.orientation = .vertical
        status.alignment = .centerX
        status.spacing = 8
        let bar = NSStackView(views: [NSView(), saveButton])
        bar.orientation = .horizontal
        for view in [imageView, status, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            status.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        panel.contentView = content
    }

    /// Longest edge (device pixels) worth decoding for `screen`, within the budget.
    static func pixelSize(for screen: NSScreen?, budget: ResourceBudget) -> Int {
        let frame = screen?.frame.size ?? NSSize(width: 1_440, height: 900)
        let scale = screen?.backingScaleFactor ?? 2
        return max(1, min(budget.maximumImagePixelDimension, Int((max(frame.width, frame.height) * scale).rounded(.up))))
    }

    /// Initial content size: the server-reported aspect ratio at native point size,
    /// fitted into 85 % of the visible screen.
    static func contentSize(for file: FileInfo, screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1_440, height: 900)
        let scale = screen?.backingScaleFactor ?? 2
        let bounds = NSSize(width: visible.width * 0.85, height: visible.height * 0.85 - 48)
        guard let width = file.width, let height = file.height, width > 0, height > 0 else {
            return NSSize(width: min(bounds.width, 720), height: min(bounds.height, 540) + 48)
        }
        let native = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let fit = min(1, bounds.width / native.width, bounds.height / native.height)
        return NSSize(width: max(minimumContentSize.width, floor(native.width * fit)),
                      height: max(minimumContentSize.height, floor(native.height * fit) + 48))
    }

    /// Shows the window over `parent` and starts `fetch` (called with the pixel size).
    func show(over parent: NSWindow?, budget: ResourceBudget,
              fetch: @escaping @MainActor (Int) async -> ImagePipeline.Decoded?) {
        guard let window else { return }
        let screen = parent?.screen ?? NSScreen.main
        window.setContentSize(Self.contentSize(for: file, screen: screen))
        if let parent {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2))
            window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
        } else {
            window.center()
        }
        if !Self.isPresentationSuppressedForTesting { showWindow(nil) }
        load(maxPixelSize: Self.pixelSize(for: screen, budget: budget), fetch: fetch)
    }

    func load(maxPixelSize: Int, fetch: @escaping @MainActor (Int) async -> ImagePipeline.Decoded?) {
        task?.cancel()
        setState(.loading)
        task = Task { [weak self] in
            let decoded = await fetch(maxPixelSize)
            guard let self, !Task.isCancelled else { return }
            task = nil
            guard let decoded else { return setState(.failed) }
            lease = decoded
            let scale = window?.backingScaleFactor ?? 2
            // Native point size, so Retina shows every decoded pixel; the NSImage wraps
            // the leased CGImage without another bitmap.
            imageView.image = NSImage(cgImage: decoded.image, size: NSSize(width: CGFloat(decoded.image.width) / scale,
                                                                          height: CGFloat(decoded.image.height) / scale))
            setState(.loaded)
        }
    }

    private func setState(_ state: State) {
        self.state = state
        switch state {
        case .loading:
            spinner.startAnimation(nil)
            messageLabel.stringValue = Self.loadingText
            messageLabel.isHidden = false
        case .loaded:
            spinner.stopAnimation(nil)
            messageLabel.isHidden = true
        case .failed:
            spinner.stopAnimation(nil)
            imageView.image = nil
            messageLabel.stringValue = Self.failureText
            messageLabel.isHidden = false
        }
    }

    @objc func save(_ sender: Any?) {
        guard let window else { return }
        onSave?(file, window)
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        task = nil
        imageView.image = nil
        lease = nil
        let onClose = onClose
        self.onClose = nil
        onSave = nil
        onClose?()
    }
}

/// Escape and ⌘W close the viewer even without a File ▸ Close menu item.
final class ImageViewerPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
