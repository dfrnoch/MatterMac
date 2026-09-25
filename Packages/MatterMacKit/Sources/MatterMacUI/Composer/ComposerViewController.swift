public import AppKit
public import MatterMacModels
public import MatterMacCore

/// The message composer: a plain-text `ComposerTextView` in a scroll view that
/// grows from one to `maximumVisibleLines` lines, with placeholder, reply/edit
/// banner, attachment chips, Send button, and a server-length counter.
///
/// Ownership and lifetime: the host creates one controller per conversation pane
/// and reuses it across channel switches (`currentDraft()` → store →
/// `load(draft:)`). The controller holds its delegate and completion provider
/// weakly/strongly as documented on each property, owns at most one completion
/// task and one coalesced draft-change task, and never persists anything.
public final class ComposerViewController: NSViewController {
    // MARK: Public configuration

    public weak var delegate: (any ComposerViewControllerDelegate)?

    /// Autocomplete source (held strongly; set `nil` to disable autocomplete).
    public var completionProvider: (any ComposerCompletionProvider)? {
        get { completion.provider }
        set { completion.provider = newValue }
    }

    public var sendBehavior: ComposerSendBehavior = .returnSends {
        didSet {
            textView.sendBehavior = sendBehavior
            updateSendButton()
        }
    }

    /// Server message limit in Unicode scalars (`MaxPostSize`), when known.
    public var maximumMessageCharacters: Int? {
        didSet { refreshLengthState() }
    }

    /// E.g. "Message #town-square" or "Reply…". Also the text view's
    /// accessibility label.
    public var placeholder: String = String(localized: "Message") {
        didSet { updatePlaceholder() }
    }

    public var mode: ComposerMode = .compose {
        didSet {
            guard mode != oldValue else { return }
            updateModeBanner()
            updateSendButton()
            updatePreferredHeight()
        }
    }

    public var attachments: [ComposerAttachment] = [] {
        didSet {
            attachmentStrip.update(attachments)
            attachmentStrip.isHidden = attachments.isEmpty
            updateSendButton()
            if attachments.isEmpty != oldValue.isEmpty { updatePreferredHeight() }
        }
    }

    /// Host-controlled gate (e.g. uploads still running, read-only channel). When
    /// `false`, Send is disabled and Return does not send; text is unaffected.
    public var isSendAllowed = true {
        didSet { updateSendButton() }
    }

    /// Called when the composer's preferred height changes (for SwiftUI sizing).
    public var onPreferredHeightChange: ((CGFloat) -> Void)?

    public private(set) var preferredHeight: CGFloat = 0

    /// The number of visible lines before the text scrolls.
    public static let maximumVisibleLines = 10

    // MARK: Public state

    /// Exact current text (including any uncommitted composition).
    public var text: String { textView.string }

    /// UTF-8 size of the current text, maintained incrementally (cheap to read on
    /// every keystroke, e.g. from `composerRemainingDraftBytes()`).
    public var draftByteCount: Int { textView.metrics.utf8 }

    /// Unicode scalars in the current text (the server's message-length unit).
    public var messageCharacterCount: Int { textView.metrics.scalars }

    /// Whether Send would currently do something.
    public var canSend: Bool { isSendAllowed && hasSendableContent && !lengthState.blocksSending }

    // MARK: Internals

    let budget: ResourceBudget
    let diagnostics: DiagnosticRing?
    let textView = ComposerTextView.make()
    let completion = ComposerCompletionController()
    let attachmentStrip = ComposerAttachmentStrip()

    /// Coalescing window for `composerDraftDidChange()` (≤ 4 Hz).
    var draftChangeInterval: Duration = .milliseconds(250)

    private(set) var lengthState = ComposerLengthState.hidden
    /// Transient explanation of the last refusal; cleared by the next user edit.
    private(set) var notice: String?

    private let scrollView = NSScrollView()
    private let inputBox = NSBox()
    private let placeholderLabel = PassthroughLabel(labelWithString: "")
    let sendButton = ComposerIconButton()
    let attachButton = ComposerIconButton()
    /// Both icon buttons are exactly as tall as the one-line input box and bottom-aligned
    /// with it: centered on a single line, beside the last line when the box grows.
    private var iconButtonHeightConstraints: [NSLayoutConstraint] = []
    public var isAttachmentSelectionAllowed = true { didSet { updateSendButton() } }
    private let bannerView = NSStackView()
    private let bannerIcon = NSImageView()
    private let bannerLabel = NSTextField(labelWithString: "")
    let bannerCancelButton = NSButton()
    private let statusRow = NSStackView()
    let statusLabel = NSTextField(labelWithString: "")
    let counterLabel = NSTextField(labelWithString: "")
    private var inputHeightConstraint: NSLayoutConstraint?
    private var draftChangeTask: Task<Void, Never>?
    private var heightUpdateTask: Task<Void, Never>?
    private var lastLayoutWidth: CGFloat = -1
    private var isLoadingDraft = false

    private static let bannerHeight: CGFloat = 24
    private static let statusHeight: CGFloat = 16
    private static let stackSpacing: CGFloat = 6
    private static let outerInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
    private static let boxInsets = NSSize(width: 8, height: 3)
    private static let sendButtonSize: CGFloat = 28
    private static let attachButtonWidth: CGFloat = 24
    private static let fieldInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
    private static let fieldCornerRadius: CGFloat = 18

    public init(budget: ResourceBudget = .standard, diagnostics: DiagnosticRing? = nil) {
        self.budget = budget
        self.diagnostics = diagnostics
        super.init(nibName: nil, bundle: nil)
        textView.apply(budget: budget)
        textView.host = self
        textView.delegate = self
        completion.textView = textView
        attachmentStrip.onRemove = { [weak self] id in self?.delegate?.composerDidRemoveAttachment(id: id) }
    }

    @available(*, unavailable, message: "The composer is built in code only")
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        draftChangeTask?.cancel()
        heightUpdateTask?.cancel()
    }

    // MARK: Public API

    /// Restores a draft's text and selection without registering undo, then
    /// clears undo history. Cancels a pending (not yet delivered) draft-change
    /// notification: capture `currentDraft()` for the previous key *before*
    /// calling this.
    public func load(draft: Draft) {
        cancelPendingDraftChange()
        completion.dismiss()
        isLoadingDraft = true
        defer { isLoadingDraft = false }
        textView.replaceAllTextProgrammatically(with: draft.text, selection: draft.selectedRange)
        notice = nil
        refreshAfterTextChange()
    }

    /// Text plus selection. Uncommitted composition text is included as plain text.
    public func currentDraft() -> Draft {
        Draft(text: textView.string, selectedRange: textView.selectedRange())
    }

    /// Empties the composer and its undo history. The host calls this only after
    /// it accepted a send (or after the user explicitly discarded the draft).
    public func clear() {
        load(draft: Draft(text: ""))
    }

    /// Makes the text view first responder.
    public func focus() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(textView)
    }

    /// Inserts text at the caret as one undoable user edit (emoji picker).
    /// Returns `false` when refused by the draft budget.
    @discardableResult
    public func insertAtCaret(_ text: String) -> Bool {
        textView.insertAtCaret(text)
    }

    /// Drops undo/redo history (sign-out, explicit discard).
    public func clearUndoHistory() {
        textView.clearUndoHistory()
    }

    /// Delivers a pending coalesced `composerDraftDidChange()` immediately.
    public func flushPendingDraftChange() {
        guard draftChangeTask != nil else { return }
        cancelPendingDraftChange()
        delegate?.composerDraftDidChange()
    }

    /// Closes the completion popup (e.g. when the pane is hidden).
    public func dismissTransientUI() {
        completion.dismiss()
    }

    /// Same as pressing Send: commits a composition, then requests a send unless
    /// the text is empty, over the server limit, or sending is not allowed.
    public func requestSend() {
        textView.confirmComposition()
        guard isSendAllowed else { return }
        if case .exceeded(_, let limit) = lengthState {
            showNotice(Self.explanation(for: .messageTooLong(limit: limit)))
            diagnostics?.record(.send, .info, "composer send blocked: message too long", code: Int64(limit))
            delegate?.composerDidRefuseInput(.messageTooLong(limit: limit))
            return
        }
        guard hasSendableContent else { return }
        completion.dismiss()
        delegate?.composerDidRequestSend(text: textView.string)
    }

    // MARK: View lifecycle

    public override func loadView() {
        let root = ComposerRootView()
        root.translatesAutoresizingMaskIntoConstraints = true

        configureInputBox()
        configureSendButton()
        configureBanner()
        configureStatusRow()
        attachmentStrip.isHidden = true
        attachmentStrip.translatesAutoresizingMaskIntoConstraints = false
        attachmentStrip.heightAnchor.constraint(equalToConstant: ComposerAttachmentStrip.height).isActive = true

        attachButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach Files")
        attachButton.isBordered = false
        attachButton.target = self
        attachButton.action = #selector(chooseFiles(_:))
        attachButton.setAccessibilityLabel("Attach Files")
        attachButton.toolTip = "Attach Files"
        attachButton.title = ""
        attachButton.imagePosition = .imageOnly
        attachButton.contentTintColor = .secondaryLabelColor
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.widthAnchor.constraint(equalToConstant: Self.attachButtonWidth).isActive = true
        iconButtonHeightConstraints = [attachButton, sendButton].map {
            $0.heightAnchor.constraint(equalToConstant: singleLineBoxHeight)
        }
        NSLayoutConstraint.activate(iconButtonHeightConstraints)
        let inputRow = NSStackView(views: [attachButton, inputBox, sendButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 6
        let stack = NSStackView(views: [bannerView, attachmentStrip, inputRow, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.stackSpacing
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        let field = Self.makeFieldChrome(containing: stack)
        root.addSubview(field)

        let insets = Self.outerInsets
        let top = field.topAnchor.constraint(equalTo: root.topAnchor, constant: insets.top)
        top.priority = .defaultLow
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: insets.left),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -insets.right),
            field.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -insets.bottom),
            field.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor),
            top,
            bannerView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            attachmentStrip.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        root.frame = NSRect(x: 0, y: 0, width: 480, height: 60)
        view = root

        updatePlaceholder()
        updateModeBanner()
        refreshAfterTextChange()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        guard width != lastLayoutWidth else { return }
        lastLayoutWidth = width
        // Re-wrapping at a new width can change the height. Report it after this
        // layout pass (never mutate the host's layout state from inside it); at
        // most one such update is outstanding.
        guard heightUpdateTask == nil else { return }
        heightUpdateTask = Task { [weak self] in
            guard let self else { return }
            self.heightUpdateTask = nil
            self.updatePreferredHeight()
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        completion.dismiss()
        flushPendingDraftChange()
    }

    // MARK: Layout construction

    /// One rounded surface for the input and its optional banners/status/attachments,
    /// so every control remains readable over scrolling messages. Liquid Glass on
    /// macOS 26 and later, a filled rounded box before that.
    private static func makeFieldChrome(containing row: NSView) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        let inset = fieldInsets
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset.left),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset.right),
            row.topAnchor.constraint(equalTo: host.topAnchor, constant: inset.top),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset.bottom),
        ])
        // A plain container whose first subview is the chrome (glass or box) and whose
        // second is the row, both pinned to its edges. Using the glass view's
        // `contentView` would let it size the content; siblings keep full width.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = fieldCornerRadius
            background = glass
        } else {
            let box = NSBox()
            box.boxType = .custom
            box.cornerRadius = fieldCornerRadius
            box.borderWidth = 1
            box.borderColor = .separatorColor
            box.fillColor = .textBackgroundColor
            box.titlePosition = .noTitle
            background = box
        }
        background.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)
        container.addSubview(host)
        for view in [background, host] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        let chrome = container
        return chrome
    }

    private func configureInputBox() {
        // The surrounding field chrome draws the border; the text box is transparent.
        inputBox.boxType = .custom
        inputBox.cornerRadius = 0
        // Keep the 1 pt border (it is part of the box's content geometry) but hide it.
        inputBox.borderWidth = 1
        inputBox.borderColor = .clear
        inputBox.fillColor = .clear
        inputBox.titlePosition = .noTitle
        inputBox.contentViewMargins = Self.boxInsets
        inputBox.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 24)

        // Secondary label colour: placeholder grey fails contrast on the glass field.
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.font = textView.font
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.maximumNumberOfLines = 1
        placeholderLabel.setAccessibilityElement(false)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        guard let content = inputBox.contentView else { return }
        content.addSubview(scrollView)
        content.addSubview(placeholderLabel)
        let heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: minimumInputHeight)
        heightConstraint.priority = NSLayoutConstraint.Priority(999)
        inputHeightConstraint = heightConstraint
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            heightConstraint,
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor,
                                                      constant: padding + textView.textContainerInset.width),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor,
                                                  constant: textView.textContainerInset.height),
        ])
    }

    private func configureSendButton() {
        let image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil) ?? NSImage()
        sendButton.image = image
        sendButton.imagePosition = .imageOnly
        sendButton.isBordered = false
        sendButton.target = self
        sendButton.action = #selector(sendButtonPressed(_:))
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.widthAnchor.constraint(equalToConstant: Self.sendButtonSize).isActive = true
    }

    private func configureBanner() {
        bannerIcon.setContentHuggingPriority(.required, for: .horizontal)
        bannerIcon.contentTintColor = .secondaryLabelColor
        bannerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        bannerLabel.textColor = .secondaryLabelColor
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.maximumNumberOfLines = 1
        bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bannerCancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        bannerCancelButton.imagePosition = .imageOnly
        bannerCancelButton.isBordered = false
        bannerCancelButton.contentTintColor = .secondaryLabelColor
        bannerCancelButton.target = self
        bannerCancelButton.action = #selector(cancelModePressed(_:))
        bannerCancelButton.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bannerView.setViews([bannerIcon, bannerLabel, spacer, bannerCancelButton], in: .leading)
        bannerView.orientation = .horizontal
        bannerView.alignment = .centerY
        bannerView.spacing = 6
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        bannerView.heightAnchor.constraint(equalToConstant: Self.bannerHeight).isActive = true
        bannerView.isHidden = true
    }

    private func configureStatusRow() {
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counterLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        counterLabel.textColor = .secondaryLabelColor
        counterLabel.alignment = .right
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusRow.setViews([statusLabel, spacer, counterLabel], in: .leading)
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.heightAnchor.constraint(equalToConstant: Self.statusHeight).isActive = true
        statusRow.isHidden = true
    }

    // MARK: Updates

    private var hasSendableContent: Bool {
        !attachments.isEmpty || !isTextBlank
    }

    private var isTextBlank: Bool {
        guard let storage = textView.textStorage, storage.length > 0 else { return true }
        // Stops at the first non-whitespace character: O(1) for ordinary text.
        return storage.mutableString.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
            .location == NSNotFound
    }

    private func refreshAfterTextChange() {
        placeholderLabel.isHidden = (textView.textStorage?.length ?? 0) > 0
        refreshLengthState()
        updateSendButton()
        updatePreferredHeight()
    }

    private func refreshLengthState() {
        let newState = ComposerLengthState(scalarCount: textView.metrics.scalars, limit: maximumMessageCharacters)
        let crossedIntoExceeded = newState.blocksSending && !lengthState.blocksSending
        lengthState = newState
        updateStatusRow()
        updateSendButton()
        if crossedIntoExceeded, let text = lengthExplanation {
            announce(text)
        }
    }

    private var lengthExplanation: String? {
        guard case .exceeded(let count, let limit) = lengthState else { return nil }
        let over = count - limit
        return String(localized: "\(over) characters over the server limit of \(limit). Shorten the message to send it.")
    }

    private func updateStatusRow() {
        guard isViewLoaded else { return }
        let wasHidden = statusRow.isHidden
        switch lengthState {
        case .hidden:
            counterLabel.stringValue = ""
            counterLabel.textColor = .secondaryLabelColor
        case .nearLimit(let count, let limit):
            counterLabel.stringValue = Self.counterText(count: count, limit: limit)
            counterLabel.textColor = .secondaryLabelColor
        case .exceeded(let count, let limit):
            counterLabel.stringValue = Self.counterText(count: count, limit: limit)
            counterLabel.textColor = .systemRed
        }
        counterLabel.setAccessibilityLabel(counterLabel.stringValue.isEmpty ? nil : String(
            localized: "\(textView.metrics.scalars) of \(maximumMessageCharacters ?? 0) characters"))
        let explanation = lengthExplanation ?? notice
        statusLabel.stringValue = explanation ?? ""
        statusLabel.toolTip = explanation
        statusLabel.textColor = lengthState.blocksSending ? .systemRed : .secondaryLabelColor
        statusRow.isHidden = explanation == nil && counterLabel.stringValue.isEmpty
        if wasHidden != statusRow.isHidden { updatePreferredHeight() }
    }

    static func counterText(count: Int, limit: Int) -> String {
        "\(count.formatted()) / \(limit.formatted())"
    }

    private func updateSendButton() {
        guard isViewLoaded else { return }
        attachButton.isEnabled = isAttachmentSelectionAllowed
        sendButton.isEnabled = canSend
        sendButton.contentTintColor = canSend ? .controlAccentColor : .tertiaryLabelColor
        let isEdit: Bool
        if case .edit = mode { isEdit = true } else { isEdit = false }
        sendButton.setAccessibilityLabel(isEdit ? String(localized: "Save edit") : String(localized: "Send message"))
        let shortcut = sendBehavior == .returnSends ? String(localized: "Return") : String(localized: "Command-Return")
        sendButton.toolTip = isEdit ? String(localized: "Save (\(shortcut))") : String(localized: "Send (\(shortcut))")
    }

    private func updatePlaceholder() {
        placeholderLabel.stringValue = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.setAccessibilityPlaceholderValue(placeholder)
    }

    private func updateModeBanner() {
        guard isViewLoaded else { return }
        switch mode {
        case .compose:
            bannerView.isHidden = true
        case .reply(let authorName):
            bannerView.isHidden = false
            bannerIcon.image = NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: nil)
            bannerLabel.stringValue = String(localized: "Replying to \(authorName)")
            bannerCancelButton.setAccessibilityLabel(String(localized: "Cancel reply"))
            bannerCancelButton.toolTip = String(localized: "Cancel reply (Escape)")
        case .edit:
            bannerView.isHidden = false
            bannerIcon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            bannerLabel.stringValue = String(localized: "Editing message")
            bannerCancelButton.setAccessibilityLabel(String(localized: "Cancel editing"))
            bannerCancelButton.toolTip = String(localized: "Cancel editing (Escape)")
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        updateStatusRow()
        announce(text)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: textView, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    static func explanation(for refusal: ComposerRefusal) -> String {
        switch refusal {
        case .pasteTooLarge(let limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .memory)
            return String(localized: "Pasted text is larger than \(size) and was not inserted.")
        case .draftBudgetExceeded:
            return String(localized: "Unsent text has reached this session’s limit. Send or discard drafts to add more.")
        case .tooManyFiles(let limit):
            return String(localized: "Too many files at once (at most \(limit)). Nothing was attached.")
        case .messageTooLong(let limit):
            return String(localized: "This message is longer than the server allows (\(limit) characters). Shorten it to send it.")
        }
    }

    // MARK: Height

    private var lineHeight: CGFloat {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        return textView.layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender + font.leading)
    }

    /// Input box height for a text area of `inputHeight`: content margins plus border.
    private func boxHeight(forInputHeight inputHeight: CGFloat) -> CGFloat {
        inputHeight + Self.boxInsets.height * 2 + 2
    }

    private var singleLineBoxHeight: CGFloat { boxHeight(forInputHeight: minimumInputHeight) }

    private var minimumInputHeight: CGFloat {
        ceil(lineHeight + textView.textContainerInset.height * 2)
    }

    private var maximumInputHeight: CGFloat {
        ceil(lineHeight * CGFloat(Self.maximumVisibleLines) + textView.textContainerInset.height * 2)
    }

    /// Height of the text area for the current text, laid out only as far as the
    /// maximum visible height (bounded work regardless of draft size).
    func desiredInputHeight() -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return minimumInputHeight
        }
        let maximum = maximumInputHeight
        layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: max(1, container.size.width),
                                                           height: maximum + lineHeight),
                                   in: container)
        let used = layoutManager.usedRect(for: container).height
        return min(max(ceil(used + textView.textContainerInset.height * 2), minimumInputHeight), maximum)
    }

    private func updatePreferredHeight() {
        guard isViewLoaded else { return }
        let inputHeight = desiredInputHeight()
        if inputHeightConstraint?.constant != inputHeight { inputHeightConstraint?.constant = inputHeight }
        let buttonHeight = singleLineBoxHeight
        for constraint in iconButtonHeightConstraints where constraint.constant != buttonHeight {
            constraint.constant = buttonHeight
        }
        let insets = Self.outerInsets
        var sections: [CGFloat] = [boxHeight(forInputHeight: inputHeight) + Self.fieldInsets.top + Self.fieldInsets.bottom]
        if !bannerView.isHidden { sections.append(Self.bannerHeight) }
        if !attachmentStrip.isHidden { sections.append(ComposerAttachmentStrip.height) }
        if !statusRow.isHidden { sections.append(Self.statusHeight) }
        let total = ceil(insets.top + insets.bottom + sections.reduce(0, +)
                         + Self.stackSpacing * CGFloat(sections.count - 1))
        guard total != preferredHeight else { return }
        preferredHeight = total
        (view as? ComposerRootView)?.preferredHeight = total
        onPreferredHeightChange?(total)
    }

    // MARK: Draft-change coalescing

    private func scheduleDraftChange() {
        guard draftChangeTask == nil else { return }
        let interval = draftChangeInterval
        draftChangeTask = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.draftChangeTask = nil
            self.delegate?.composerDraftDidChange()
        }
    }

    private func cancelPendingDraftChange() {
        draftChangeTask?.cancel()
        draftChangeTask = nil
    }

    var hasPendingDraftChange: Bool { draftChangeTask != nil }

    // MARK: Actions

    @objc private func chooseFiles(_ sender: Any?) { delegate?.composerRequestsFileSelection() }

    @objc private func sendButtonPressed(_ sender: Any?) {
        requestSend()
    }

    @objc private func cancelModePressed(_ sender: Any?) {
        delegate?.composerDidRequestCancelMode()
    }

    private func userEdited() {
        notice = nil
        refreshAfterTextChange()
        completion.update()
        delegate?.composerUserDidType()
        scheduleDraftChange()
    }
}

// MARK: - NSTextViewDelegate

extension ComposerViewController: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        guard !textView.isApplyingHistory else { return }
        if textView.isPerformingProgrammaticChange || isLoadingDraft {
            refreshAfterTextChange()
            return
        }
        userEdited()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !textView.isApplyingHistory, !textView.isPerformingProgrammaticChange, !isLoadingDraft else { return }
        completion.update()
        scheduleDraftChange()
    }
}

// MARK: - ComposerTextViewHost

extension ComposerViewController: ComposerTextViewHost {
    var isCompletionVisible: Bool { completion.isVisible }

    func composerTextView(_ textView: ComposerTextView, moveCompletionSelectionBy delta: Int) {
        completion.moveSelection(by: delta)
    }

    func composerTextViewAcceptCompletion(_ textView: ComposerTextView) -> Bool {
        completion.acceptSelected()
    }

    func composerTextViewDismissCompletion(_ textView: ComposerTextView) {
        completion.dismiss(suppressingCurrentQuery: true)
    }

    func composerTextViewRequestsSend(_ textView: ComposerTextView) {
        requestSend()
    }

    func composerTextViewDidPressEscape(_ textView: ComposerTextView) {
        if mode == .compose {
            delegate?.composerDidPressEscape()
        } else {
            delegate?.composerDidRequestCancelMode()
        }
    }

    func composerTextViewRequestsEditLastMessage(_ textView: ComposerTextView) {
        delegate?.composerRequestsEditLastMessage()
    }

    func composerTextViewRemainingDraftBytes(_ textView: ComposerTextView) -> Int {
        delegate?.composerRemainingDraftBytes() ?? .max
    }

    func composerTextView(_ textView: ComposerTextView, didRefuse refusal: ComposerRefusal) {
        diagnostics?.record(.budget, .info, "composer input refused", code: Self.diagnosticCode(for: refusal))
        showNotice(Self.explanation(for: refusal))
        delegate?.composerDidRefuseInput(refusal)
    }

    func composerTextView(_ textView: ComposerTextView, didReceiveImage data: Data, typeIdentifier: String) -> Bool {
        return delegate?.composerDidPasteImage(data: data, typeIdentifier: typeIdentifier) ?? false
    }

    func composerTextView(_ textView: ComposerTextView, didReceiveFiles urls: [URL]) {
        delegate?.composerDidReceiveFiles(urls)
    }

    func composerTextViewDidApplyHistory(_ textView: ComposerTextView) {
        userEdited()
    }

    func composerTextViewDidResignFirstResponder(_ textView: ComposerTextView) {
        completion.dismiss()
    }

    private static func diagnosticCode(for refusal: ComposerRefusal) -> Int64 {
        switch refusal {
        case .pasteTooLarge: 1
        case .draftBudgetExceeded: 2
        case .tooManyFiles: 3
        case .messageTooLong: 4
        }
    }
}

/// Root view reporting the composer's preferred height as its intrinsic height.
final class ComposerRootView: NSView {
    var preferredHeight: CGFloat = 0 {
        didSet {
            if preferredHeight != oldValue { invalidateIntrinsicContentSize() }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }
}

/// A label that never intercepts clicks, so clicking the placeholder focuses the
/// text view underneath.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Borderless icon button whose layout rect is its frame. `NSButton`'s default
/// alignment-rect insets for symbol images shifted the paperclip and send icons
/// below the input box's center under stack-view bottom alignment.
final class ComposerIconButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}
