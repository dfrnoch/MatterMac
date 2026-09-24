import AppKit

/// Horizontal row of host-provided attachment chips (name, size, progress,
/// remove). Chips are reused by attachment ID, so frequent progress updates only
/// reconfigure existing views. The host bounds the number of attachments (server
/// file limit); the strip renders what it is given.
final class ComposerAttachmentStrip: NSView {
    static let height: CGFloat = 44

    var onRemove: ((String) -> Void)?

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private var chips: [String: AttachmentChipView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Attachments"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Number of chip views currently alive (reuse test hook).
    var chipCount: Int { chips.count }

    func update(_ attachments: [ComposerAttachment]) {
        var next: [String: AttachmentChipView] = [:]
        var ordered: [AttachmentChipView] = []
        for attachment in attachments where next[attachment.id] == nil {
            let chip = chips[attachment.id] ?? AttachmentChipView(id: attachment.id)
            chip.onRemove = { [weak self] id in self?.onRemove?(id) }
            chip.configure(attachment)
            next[attachment.id] = chip
            ordered.append(chip)
        }
        for (id, chip) in chips where next[id] == nil {
            stack.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        chips = next
        if stack.arrangedSubviews != ordered {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view) }
            for chip in ordered { stack.addArrangedSubview(chip) }
        }
    }

    func chip(for id: String) -> AttachmentChipView? { chips[id] }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One attachment chip. The file name is untrusted and shown as plain text only.
final class AttachmentChipView: NSView {
    let attachmentID: String
    var onRemove: ((String) -> Void)?

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private(set) var removeButton = NSButton()
    private let box = NSBox()

    init(id: String) {
        attachmentID = id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        box.boxType = .custom
        box.cornerRadius = 6
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 6, height: 4)
        box.titlePosition = .noTitle
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 1
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1

        removeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill",
                                               accessibilityDescription: nil) ?? NSImage(),
                                target: self, action: #selector(removeClicked(_:)))
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        let texts = NSStackView(views: [nameLabel, detailLabel, progress])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(row)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                row.topAnchor.constraint(equalTo: content.topAnchor),
                row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170),
            progress.widthAnchor.constraint(equalToConstant: 120),
            heightAnchor.constraint(equalToConstant: ComposerAttachmentStrip.height - 4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(_ attachment: ComposerAttachment) {
        nameLabel.stringValue = attachment.name
        nameLabel.toolTip = attachment.name
        let size = ByteCountFormatter.string(fromByteCount: max(0, attachment.byteCount), countStyle: .file)
        let status: String
        switch attachment.status {
        case .waiting:
            status = String(localized: "Ready to upload")
            progress.isHidden = true
        case .uploading(let fraction):
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            status = String(localized: "Uploading \(percent)%")
            progress.isHidden = false
            progress.doubleValue = min(max(fraction, 0), 1)
        case .ready:
            status = String(localized: "Ready")
            progress.isHidden = true
        case .failed:
            status = String(localized: "Upload failed")
            progress.isHidden = true
        }
        detailLabel.stringValue = "\(size) · \(status)"
        detailLabel.textColor = attachment.status == .failed ? .systemRed : .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: attachment.status == .failed ? "exclamationmark.triangle" : "doc",
                             accessibilityDescription: nil)
        setAccessibilityLabel("\(attachment.name), \(size), \(status)")
        removeButton.setAccessibilityLabel(String(localized: "Remove \(attachment.name)"))
        removeButton.toolTip = String(localized: "Remove attachment")
    }

    @objc private func removeClicked(_ sender: Any?) {
        onRemove?(attachmentID)
    }
}
