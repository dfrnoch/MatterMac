import AppKit
import QuartzCore
import MatterMacModels
import MatterMacCore

/// What the media viewer shows: the image attachments of one message, opened at
/// `index`, with the message's author and time when they are known.
struct MediaViewerContent {
    var files: [FileInfo]
    var index: Int
    var authorName: String?
    var timestamp: MattermostTimestamp?

    init(files: [FileInfo], index: Int = 0, authorName: String? = nil, timestamp: MattermostTimestamp? = nil) {
        precondition(!files.isEmpty, "The viewer needs at least one file")
        self.files = files
        self.index = min(max(0, index), files.count - 1)
        self.authorName = authorName
        self.timestamp = timestamp
    }
}

/// In-window viewer for image attachments, opened explicitly from the timeline or
/// file search. It dims the whole window (title bar included) and shows the image
/// fitted in the middle, with the author and time at the top left, actions at the top
/// right, and previous/next for messages with several images.
///
/// - Images come from the bounded `ImagePipeline` (server preview rendition,
///   downsampled to the screen size and at most `maximumImagePixelDimension`). One
///   image lease is held at a time; moving to another image releases the previous one,
///   and closing releases everything. While the full image loads, the timeline's
///   already-leased thumbnail is shown scaled up.
/// - No disk cache, Quick Look, or temporary file. Save uses the conversation's
///   explicit attachment-download path; Copy Image writes the displayed rendition to
///   the pasteboard only when asked.
/// - Escape, Space, ⌘W and a click outside the image close it; ← and → move between
///   images; double-click, pinch, ⌘+, ⌘- and ⌘0 zoom.
final class MediaViewerController {
    enum State: Equatable { case loading, loaded, failed }
    typealias Fetch = @MainActor (FileInfo, Int) async -> ImagePipeline.Decoded?

    private(set) var content: MediaViewerContent
    var file: FileInfo { content.files[content.index] }
    private(set) var state: State = .loading
    /// The displayed image's lease (the full image, or the placeholder while loading).
    private(set) var lease: ImagePipeline.Decoded?
    private(set) var isShowingPlaceholder = false
    private var avatarLease: ImagePipeline.Decoded?
    private var task: Task<Void, Never>?
    private var avatarTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var fetch: Fetch?
    private var maxPixelSize = 1
    private weak var previousResponder: NSResponder?
    private(set) var isClosed = false

    let overlay = MediaViewerOverlayView()
    var imageView: NSImageView { overlay.imageView }
    var messageLabel: NSTextField { overlay.messageLabel }
    var saveButton: NSButton { overlay.saveButton }

    var onSave: ((FileInfo) -> Void)?
    var onClose: (() -> Void)?
    /// An image already leased elsewhere (the timeline thumbnail), shown while loading.
    var placeholder: ((FileInfo) -> ImagePipeline.Decoded?)?

    /// Tests keep the viewer out of the window (it is still created, loaded and closed).
    static var isPresentationSuppressedForTesting = false
    static let loadingText = String(localized: "Loading image…")
    static let failureText = String(localized: """
        The image couldn’t be shown. The server may not provide a preview, the connection may have failed, \
        or MatterMac’s image memory limit is in use by other images. You can still save the attachment.
        """)

    init(content: MediaViewerContent) {
        self.content = content
        overlay.controller = self
        overlay.configureHeader(authorName: content.authorName, timestamp: content.timestamp)
    }

    deinit {
        task?.cancel()
        avatarTask?.cancel()
        feedbackTask?.cancel()
    }

    /// Longest edge (device pixels) worth decoding for `screen`, within the budget.
    static func pixelSize(for screen: NSScreen?, budget: ResourceBudget) -> Int {
        let frame = screen?.frame.size ?? NSSize(width: 1_440, height: 900)
        let scale = screen?.backingScaleFactor ?? 2
        return max(1, min(budget.maximumImagePixelDimension, Int((max(frame.width, frame.height) * scale).rounded(.up))))
    }

    /// Shows the viewer over `window`'s whole frame and loads the current image with
    /// `fetch` (called with the file and the pixel size). `avatar` optionally loads the
    /// author's picture for the header (called with its pixel size).
    func show(in window: NSWindow?, budget: ResourceBudget, fetch: @escaping Fetch,
              avatar: (@MainActor (Int) async -> ImagePipeline.Decoded?)? = nil) {
        self.fetch = fetch
        maxPixelSize = Self.pixelSize(for: window?.screen ?? NSScreen.main, budget: budget)
        if let window, !Self.isPresentationSuppressedForTesting {
            present(in: window)
        }
        if let avatar {
            let pixels = Int((MediaViewerOverlayView.avatarSize * (window?.backingScaleFactor ?? 2)).rounded(.up))
            avatarTask = Task { [weak self] in
                let decoded = await avatar(pixels)
                guard let self, !Task.isCancelled, !isClosed, let decoded else { return }
                avatarLease = decoded
                overlay.setAvatar(NSImage(cgImage: decoded.image, size: .zero))
            }
        }
        loadCurrent()
    }

    private func present(in window: NSWindow) {
        // Above the title bar too: the frame view hosts the content view and the
        // title bar container, so the dim and the viewer's chrome cover both.
        let container = window.contentView?.superview ?? window.contentView
        guard let container else { return }
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.layoutSubtreeIfNeeded()
        previousResponder = window.firstResponder
        window.makeFirstResponder(overlay)
        overlay.animateIn()
        NSAccessibility.post(element: overlay, notification: .layoutChanged)
    }

    // MARK: - Navigation

    var canMoveBackward: Bool { content.index > 0 }
    var canMoveForward: Bool { content.index < content.files.count - 1 }

    func move(_ delta: Int) {
        select(content.index + delta)
    }

    func select(_ index: Int) {
        guard !isClosed, content.files.indices.contains(index), index != content.index else { return }
        content.index = index
        overlay.resetZoom()
        loadCurrent()
        NSAccessibility.post(element: overlay, notification: .announcementRequested, userInfo: [
            .announcement: overlay.positionText(index: index, count: content.files.count),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func loadCurrent() {
        task?.cancel()
        let file = file
        overlay.showFile(file, index: content.index, count: content.files.count,
                         canMoveBackward: canMoveBackward, canMoveForward: canMoveForward)
        // Release the previous image before asking for the next one.
        overlay.setImage(nil, pointSize: .zero)
        lease = nil
        if let placeholder = placeholder?(file) {
            lease = placeholder
            isShowingPlaceholder = true
            overlay.setImage(NSImage(cgImage: placeholder.image, size: .zero), pointSize: expectedPointSize(for: file, placeholder: placeholder))
        } else {
            isShowingPlaceholder = false
        }
        setState(.loading)
        guard let fetch else { return }
        let pixels = maxPixelSize
        task = Task { [weak self] in
            let decoded = await fetch(file, pixels)
            guard let self, !Task.isCancelled, !isClosed, self.file.id == file.id else { return }
            task = nil
            guard let decoded else { return setState(.failed) }
            lease = decoded
            isShowingPlaceholder = false
            let scale = overlay.window?.backingScaleFactor ?? 2
            // Native point size, so Retina shows every decoded pixel; the NSImage wraps
            // the leased CGImage without another bitmap.
            let size = NSSize(width: CGFloat(decoded.image.width) / scale, height: CGFloat(decoded.image.height) / scale)
            overlay.setImage(NSImage(cgImage: decoded.image, size: size), pointSize: size)
            setState(.loaded)
        }
    }

    /// The full image's point size, from the server's dimensions fitted to the decode
    /// limit, so the placeholder already has its final size.
    private func expectedPointSize(for file: FileInfo, placeholder: ImagePipeline.Decoded) -> NSSize {
        let scale = overlay.window?.backingScaleFactor ?? 2
        var width = CGFloat(file.width ?? placeholder.image.width)
        var height = CGFloat(file.height ?? placeholder.image.height)
        guard width > 0, height > 0 else { return NSSize(width: 1, height: 1) }
        let fit = min(1, CGFloat(maxPixelSize) / max(width, height))
        width *= fit
        height *= fit
        return NSSize(width: floor(width) / scale, height: floor(height) / scale)
    }

    private func setState(_ state: State) {
        self.state = state
        overlay.showState(state, hasPlaceholder: isShowingPlaceholder)
        if state == .failed {
            lease = nil
            isShowingPlaceholder = false
            overlay.setImage(nil, pointSize: .zero)
        }
    }

    // MARK: - Actions

    func save() {
        guard !isClosed else { return }
        onSave?(file)
    }

    /// Writes the displayed rendition (not the original file) to the pasteboard.
    func copyImage() {
        guard !isClosed, state == .loaded, let image = imageView.image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        showFeedback(String(localized: "Image copied"))
    }

    private func showFeedback(_ message: String) {
        feedbackTask?.cancel()
        overlay.showFeedback(message)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled else { return }
            overlay.showFeedback(nil)
        }
    }

    /// Closes the viewer: cancels loading, removes it from the window and releases its
    /// images (after the fade, when animated).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel()
        task = nil
        avatarTask?.cancel()
        avatarTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        let window = overlay.window
        let restore = previousResponder
        let onClose = onClose
        self.onClose = nil
        onSave = nil
        placeholder = nil
        fetch = nil
        // `onClose` usually releases this controller before the fade ends, so the
        // completion holds the overlay itself. A leftover transparent overlay would keep
        // its stage under the title bar, which takes the toolbar's scroll edge effect
        // away from the timeline.
        let overlay = overlay
        overlay.animateOut { [weak self] in
            overlay.removeFromSuperview()
            overlay.setImage(nil, pointSize: .zero)
            overlay.setAvatar(nil)
            self?.lease = nil
            self?.avatarLease = nil
        }
        if let window {
            if let restore, (restore as? NSView)?.window === window || restore === window {
                window.makeFirstResponder(restore)
            } else {
                window.makeFirstResponder(nil)
            }
        }
        onClose?()
    }
}

// MARK: - Overlay

/// The viewer's view, added above the window's content and title bar.
final class MediaViewerOverlayView: NSView, NSMenuItemValidation {
    static let avatarSize: CGFloat = 34
    static let controlHeight: CGFloat = 36
    static let edgeInset: CGFloat = 16
    /// The header starts after the (dimmed) traffic lights.
    static let headerLeading: CGFloat = 84
    static let stageTopInset: CGFloat = 72
    static let stageSideInset: CGFloat = 72
    static let stageBottomInset: CGFloat = 28

    weak var controller: MediaViewerController?
    let stage = MediaViewerStageView()
    var imageView: NSImageView { stage.imageView }
    let spinner = NSProgressIndicator()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let saveButton = CapsuleHoverButton(frame: .zero)
    let copyButton = CapsuleHoverButton(frame: .zero)
    let zoomButton = CapsuleHoverButton(frame: .zero)
    let closeButton = CapsuleHoverButton(frame: .zero)
    let previousButton = CapsuleHoverButton(frame: .zero)
    let nextButton = CapsuleHoverButton(frame: .zero)
    private let avatarView = NSImageView()
    private let initialsLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let header = NSStackView()
    private let actions: NSView
    private let closeBackground: NSView
    private let previousBackground: NSView
    private let nextBackground: NSView
    private let feedback: NSView
    private let feedbackLabel = NSTextField(labelWithString: "")
    private var authorName: String?
    private var timestamp: MattermostTimestamp?
    private var mouseDownOnBackdrop = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        actions = Self.glass(cornerRadius: Self.controlHeight / 2)
        closeBackground = Self.glass(cornerRadius: Self.controlHeight / 2)
        previousBackground = Self.glass(cornerRadius: 20)
        nextBackground = Self.glass(cornerRadius: 20)
        feedback = Self.glass(cornerRadius: 16)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Image viewer"))
        setAccessibilityModal(true)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Building

    private static func glass(cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = NSView()
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return effect
    }

    private static func contentView(of glass: NSView) -> NSView {
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView, let content = glass.contentView {
            return content
        }
        return glass
    }

    private func configure(_ button: CapsuleHoverButton, symbol: String, label: String, action: Selector,
                           pointSize: CGFloat = 15) {
        button.highlightColor = .white
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.focusRingType = .default
    }

    private func build() {
        addSubview(stage)
        stage.onDoubleClick = { [weak self] point in self?.stage.toggleZoom(at: point) }
        stage.onMagnificationChange = { [weak self] in self?.updateZoomButton() }

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        messageLabel.alignment = .center
        messageLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageLabel.stringValue = MediaViewerController.loadingText
        addSubview(messageLabel)

        // Header: avatar, author and time.
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = Self.avatarSize / 2
        avatarView.layer?.masksToBounds = true
        avatarView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        initialsLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        initialsLabel.textColor = .white
        initialsLabel.alignment = .center
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarView.addSubview(initialsLabel)
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            initialsLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
        ])
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.shadow = {
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 6
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
                return shadow
            }()
        }
        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        header.setViews([avatarView, text], in: .leading)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.staticText)
        addSubview(header)

        // Actions: Copy Image, Save…, zoom; Close on its own.
        configure(copyButton, symbol: "doc.on.doc", label: String(localized: "Copy Image"), action: #selector(copyImage(_:)))
        configure(saveButton, symbol: "arrow.down.to.line", label: TimelineStrings.saveAttachment, action: #selector(save(_:)))
        configure(zoomButton, symbol: "plus.magnifyingglass", label: String(localized: "Actual Size"), action: #selector(toggleZoom(_:)))
        configure(closeButton, symbol: "xmark", label: String(localized: "Close"), action: #selector(close(_:)), pointSize: 14)
        let row = NSStackView(views: [copyButton, saveButton, zoomButton])
        row.orientation = .horizontal
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        Self.contentView(of: actions).addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: Self.contentView(of: actions).leadingAnchor),
            row.trailingAnchor.constraint(equalTo: Self.contentView(of: actions).trailingAnchor),
            row.centerYAnchor.constraint(equalTo: Self.contentView(of: actions).centerYAnchor),
        ])
        for button in [copyButton, saveButton, zoomButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 32),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
        addSubview(actions)
        embed(closeButton, in: closeBackground)
        addSubview(closeBackground)

        // Previous / next.
        configure(previousButton, symbol: "chevron.left", label: String(localized: "Previous Image"), action: #selector(previous(_:)))
        configure(nextButton, symbol: "chevron.right", label: String(localized: "Next Image"), action: #selector(next(_:)))
        embed(previousButton, in: previousBackground)
        embed(nextButton, in: nextBackground)
        addSubview(previousBackground)
        addSubview(nextBackground)

        // Feedback ("Image copied").
        feedbackLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        feedbackLabel.textColor = .white
        feedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        Self.contentView(of: feedback).addSubview(feedbackLabel)
        NSLayoutConstraint.activate([
            feedbackLabel.centerXAnchor.constraint(equalTo: Self.contentView(of: feedback).centerXAnchor),
            feedbackLabel.centerYAnchor.constraint(equalTo: Self.contentView(of: feedback).centerYAnchor),
        ])
        feedback.isHidden = true
        addSubview(feedback)
        for view in [actions, closeBackground, previousBackground, nextBackground, feedback] {
            view.shadow = {
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 10
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                return shadow
            }()
        }
    }

    private func embed(_ button: NSButton, in background: NSView) {
        let content = Self.contentView(of: background)
        button.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            // Square, so the hover highlight is a circle inside the circular glass.
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let inset = Self.edgeInset
        let height = Self.controlHeight
        let closeFrame = NSRect(x: bounds.maxX - inset - height, y: inset, width: height, height: height)
        closeBackground.frame = closeFrame
        let actionsWidth: CGFloat = 3 * 32 + 2 * 2 + 8
        actions.frame = NSRect(x: closeFrame.minX - 10 - actionsWidth, y: inset, width: actionsWidth, height: height)
        let headerSize = header.fittingSize
        header.frame = NSRect(x: Self.headerLeading, y: inset + (height - headerSize.height) / 2,
                              width: min(headerSize.width, max(0, actions.frame.minX - inset - Self.headerLeading)),
                              height: headerSize.height)
        stage.frame = NSRect(x: Self.stageSideInset, y: Self.stageTopInset,
                             width: max(1, bounds.width - Self.stageSideInset * 2),
                             height: max(1, bounds.height - Self.stageTopInset - Self.stageBottomInset))
        let navSize: CGFloat = 40
        let midY = floor(stage.frame.midY - navSize / 2)
        previousBackground.frame = NSRect(x: inset, y: midY, width: navSize, height: navSize)
        nextBackground.frame = NSRect(x: bounds.maxX - inset - navSize, y: midY, width: navSize, height: navSize)
        spinner.sizeToFit()
        let messageWidth = min(460, bounds.width - 80)
        let messageHeight = messageLabel.sizeThatFits(NSSize(width: messageWidth, height: .greatestFiniteMagnitude)).height
        spinner.frame.origin = NSPoint(x: floor(bounds.midX - spinner.frame.width / 2),
                                       y: floor(stage.frame.midY - spinner.frame.height - 6))
        messageLabel.frame = NSRect(x: floor(bounds.midX - messageWidth / 2), y: floor(stage.frame.midY + 6),
                                    width: messageWidth, height: ceil(messageHeight))
        let feedbackWidth = ceil(feedbackLabel.intrinsicContentSize.width) + 32
        feedback.frame = NSRect(x: floor(bounds.midX - feedbackWidth / 2), y: bounds.maxY - 32 - 44,
                                width: feedbackWidth, height: 32)
    }

    // MARK: Content

    func configureHeader(authorName: String?, timestamp: MattermostTimestamp?) {
        self.authorName = authorName
        self.timestamp = timestamp
        initialsLabel.stringValue = authorName.map { TeamIconView.initials($0) } ?? ""
        avatarView.isHidden = authorName == nil
    }

    func setAvatar(_ image: NSImage?) {
        avatarView.image = image
        initialsLabel.isHidden = image != nil
    }

    func positionText(index: Int, count: Int) -> String {
        String(localized: "\(index + 1) of \(count)")
    }

    func showFile(_ file: FileInfo, index: Int, count: Int, canMoveBackward: Bool, canMoveForward: Bool) {
        nameLabel.stringValue = authorName ?? file.name
        var detail: [String] = []
        if let timestamp { detail.append(TimelineStrings.fullDateTime(timestamp)) }
        if authorName != nil { detail.append(file.name) }
        if count > 1 { detail.append(positionText(index: index, count: count)) }
        detailLabel.stringValue = detail.joined(separator: " · ")
        detailLabel.isHidden = detail.isEmpty
        header.setAccessibilityLabel(([nameLabel.stringValue] + detail).joined(separator: ", "))
        imageView.setAccessibilityLabel(TimelineStrings.imageAccessibility(name: file.name))
        previousBackground.isHidden = count < 2
        nextBackground.isHidden = count < 2
        previousButton.isEnabled = canMoveBackward
        nextButton.isEnabled = canMoveForward
        previousBackground.alphaValue = canMoveBackward ? 1 : 0.4
        nextBackground.alphaValue = canMoveForward ? 1 : 0.4
        needsLayout = true
    }

    func setImage(_ image: NSImage?, pointSize: NSSize) {
        stage.setImage(image, pointSize: pointSize)
        updateZoomButton()
    }

    func resetZoom() { stage.resetZoom() }

    func showState(_ state: MediaViewerController.State, hasPlaceholder: Bool) {
        switch state {
        case .loading:
            spinner.startAnimation(nil)
            messageLabel.stringValue = MediaViewerController.loadingText
            messageLabel.isHidden = hasPlaceholder
        case .loaded:
            spinner.stopAnimation(nil)
            messageLabel.isHidden = true
        case .failed:
            spinner.stopAnimation(nil)
            messageLabel.stringValue = MediaViewerController.failureText
            messageLabel.isHidden = false
        }
        copyButton.isEnabled = state == .loaded
        zoomButton.isEnabled = state == .loaded
        needsLayout = true
    }

    func showFeedback(_ message: String?) {
        if let message {
            feedbackLabel.stringValue = message
            feedback.isHidden = false
            needsLayout = true
        } else {
            feedback.isHidden = true
        }
    }

    private func updateZoomButton() {
        let zoomed = stage.userZoomed
        let label = zoomed ? String(localized: "Fit to Window") : String(localized: "Actual Size")
        zoomButton.image = NSImage(systemSymbolName: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass",
                                   accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        zoomButton.toolTip = label
        zoomButton.setAccessibilityLabel(label)
    }

    // MARK: Presentation

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func animateIn() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducesMotion ? 0.1 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        guard !reducesMotion, let layer = stage.layer else { return }
        let scale = CABasicAnimation(keyPath: "transform")
        let bounds = layer.bounds
        var from = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        from = CATransform3DScale(from, 0.96, 0.96, 1)
        from = CATransform3DTranslate(from, -bounds.midX, -bounds.midY, 0)
        scale.fromValue = from
        scale.toValue = CATransform3DIdentity
        scale.duration = 0.28
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(scale, forKey: "present")
    }

    func animateOut(completion: @escaping @MainActor () -> Void) {
        guard window != nil, !MediaViewerController.isPresentationSuppressedForTesting else { return completion() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducesMotion ? 0.08 : 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }

    // MARK: Input

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, controller?.isClosed == false else { return nil }
        return super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownOnBackdrop = !stage.imageFrameInView(self).contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mouseDownOnBackdrop, !stage.imageFrameInView(self).contains(point) {
            controller?.close()
        }
        mouseDownOnBackdrop = false
    }

    // Wheel input never reaches the conversation underneath.
    override func scrollWheel(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func cancelOperation(_ sender: Any?) { controller?.close() }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .leftArrow?: controller?.move(-1)
        case .rightArrow?: controller?.move(1)
        default:
            if event.charactersIgnoringModifiers == " " { controller?.close() } else { super.keyDown(with: event) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, controller?.isClosed == false, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command || modifiers == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w": controller?.close()
        case "c": controller?.copyImage()
        case "s": controller?.save()
        case "0": stage.fit(animated: true)
        case "=", "+": stage.zoom(by: 1.5)
        case "-": stage.zoom(by: 1 / 1.5)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return controller?.state == .loaded }
        return true
    }

    @objc func copy(_ sender: Any?) { controller?.copyImage() }
    @objc func copyImage(_ sender: Any?) { controller?.copyImage() }
    @objc func save(_ sender: Any?) { controller?.save() }
    @objc func close(_ sender: Any?) { controller?.close() }
    @objc func previous(_ sender: Any?) { controller?.move(-1) }
    @objc func next(_ sender: Any?) { controller?.move(1) }
    @objc func toggleZoom(_ sender: Any?) { stage.toggleZoom(at: nil) }
}

// MARK: - Stage

/// The zoomable image: a magnifying scroll view that fits the image (never enlarging
/// it past its native size) and keeps it centered while it is smaller than the view.
final class MediaViewerStageView: NSScrollView {
    let imageView = MediaViewerImageView()
    var onDoubleClick: ((NSPoint?) -> Void)?
    var onMagnificationChange: (() -> Void)?
    private var pointSize: NSSize = .zero
    /// Zoomed past the fitted size by the user (also while a zoom animation runs).
    private(set) var userZoomed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = MediaViewerClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        borderType = .noBorder
        allowsMagnification = true
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.isEditable = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.onDoubleClick = { [weak self] point in self?.onDoubleClick?(point) }
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(didEndMagnify(_:)),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func scrollWheel(with event: NSEvent) {
        // Scrolling pans a zoomed image; otherwise it is ignored (and not forwarded).
        if isZoomedIn { super.scrollWheel(with: event) }
    }

    var fitMagnification: CGFloat {
        guard pointSize.width > 0, pointSize.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(1, bounds.width / pointSize.width, bounds.height / pointSize.height)
    }

    var isZoomedIn: Bool { pointSize.width > 0 && magnification > fitMagnification + 0.001 }

    func setImage(_ image: NSImage?, pointSize: NSSize) {
        let sizeChanged = pointSize != self.pointSize
        self.pointSize = pointSize
        imageView.image = image
        if sizeChanged {
            imageView.frame = NSRect(origin: .zero, size: pointSize)
            if !userZoomed { applyFit() }
        }
    }

    func resetZoom() {
        userZoomed = false
        applyFit()
    }

    private func applyFit() {
        let fit = fitMagnification
        minMagnification = fit
        maxMagnification = max(4, fit * 4)
        magnification = fit
        onMagnificationChange?()
    }

    override func layout() {
        super.layout()
        let fit = fitMagnification
        minMagnification = fit
        maxMagnification = max(4, fit * 4)
        if !userZoomed || magnification < fit { magnification = fit }
    }

    func fit(animated: Bool) {
        userZoomed = false
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animator().magnification = fitMagnification
        } else {
            magnification = fitMagnification
        }
        onMagnificationChange?()
    }

    func zoom(by factor: CGFloat) {
        guard pointSize.width > 0 else { return }
        let target = min(maxMagnification, max(minMagnification, magnification * factor))
        userZoomed = target > fitMagnification + 0.001
        setMagnification(target, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
        onMagnificationChange?()
    }

    /// Double-click: fit ↔ actual size (or 2× for images already shown at native size),
    /// centered on the clicked point (document coordinates) when there is one.
    func toggleZoom(at point: NSPoint?) {
        guard pointSize.width > 0 else { return }
        if isZoomedIn { return fit(animated: true) }
        let target = min(maxMagnification, fitMagnification < 0.999 ? 1 : 2)
        userZoomed = true
        let center = point ?? NSPoint(x: pointSize.width / 2, y: pointSize.height / 2)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setMagnification(target, centeredAt: center)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                animator().setMagnification(target, centeredAt: center)
            }
        }
        onMagnificationChange?()
    }

    @objc private func didEndMagnify(_ notification: Notification) {
        userZoomed = isZoomedIn
        onMagnificationChange?()
    }

    /// The displayed image's frame in `view`'s coordinates.
    func imageFrameInView(_ view: NSView) -> NSRect {
        guard imageView.image != nil else { return .zero }
        return imageView.convert(imageView.bounds, to: view).intersection(convert(bounds, to: view))
    }
}

/// Keeps the document centered when it is smaller than the visible area.
final class MediaViewerClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}

/// The image: double-click zooms, dragging pans a zoomed image.
final class MediaViewerImageView: NSImageView {
    var onDoubleClick: ((NSPoint) -> Void)?
    private var dragOrigin: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            dragOrigin = nil
        } else {
            dragOrigin = event.locationInWindow
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let clip = superview as? NSClipView,
              let scroll = clip.enclosingScrollView else { return }
        let location = event.locationInWindow
        let magnification = max(scroll.magnification, 0.01)
        var bounds = clip.bounds
        bounds.origin.x -= (location.x - origin.x) / magnification
        bounds.origin.y += (location.y - origin.y) / magnification * (isFlipped ? 1 : -1)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
        dragOrigin = location
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }
}
