import AppKit
import MatterMacModels

/// Callbacks from the text view to the controller that owns it.
@MainActor
protocol ComposerTextViewHost: AnyObject {
    var isCompletionVisible: Bool { get }
    func composerTextView(_ textView: ComposerTextView, moveCompletionSelectionBy delta: Int)
    /// Returns `false` when nothing could be accepted (the popup is then closed).
    func composerTextViewAcceptCompletion(_ textView: ComposerTextView) -> Bool
    func composerTextViewDismissCompletion(_ textView: ComposerTextView)
    func composerTextViewRequestsSend(_ textView: ComposerTextView)
    func composerTextViewDidPressEscape(_ textView: ComposerTextView)
    func composerTextViewRequestsEditLastMessage(_ textView: ComposerTextView)
    func composerTextViewRemainingDraftBytes(_ textView: ComposerTextView) -> Int
    func composerTextView(_ textView: ComposerTextView, didRefuse refusal: ComposerRefusal)
    func composerTextView(_ textView: ComposerTextView, didReceiveImage data: Data, typeIdentifier: String) -> Bool
    func composerTextView(_ textView: ComposerTextView, didReceiveFiles urls: [URL])
    func composerTextViewDidResignFirstResponder(_ textView: ComposerTextView)
    func composerTextViewDidApplyHistory(_ textView: ComposerTextView)
}

/// Plain-text `NSTextView` for composing messages (SPEC §13).
///
/// - TextKit 1, built explicitly (`NSTextStorage` → `NSLayoutManager` →
///   `NSTextContainer`), so the view never starts in TextKit 2 and silently flips to
///   compatibility mode later (docs/architecture.md).
/// - Keys are handled in `doCommand(by:)`, after the input method had its chance;
///   while marked text exists, Return confirms the composition and never sends.
/// - Every text change goes through `shouldChangeText(inRanges:replacementStrings:)`,
///   where the growth in UTF-8 bytes is computed from the replaced fragments only and
///   checked against the host's remaining unsent-text budget. Input-method
///   composition updates are exempt; the committed insertion is checked instead.
/// - Owns its undo manager (bounded levels and an estimated byte cap) so undo
///   history can be cleared independently of the window, e.g. on sign-out.
final class ComposerTextView: NSTextView {
    weak var host: (any ComposerTextViewHost)?
    var sendBehavior: ComposerSendBehavior = .returnSends

    /// Largest text accepted from one paste or drop (UTF-8 bytes).
    var maximumImageBytes = ResourceBudget.standard.pastedImageBytes
    var maximumPasteBytes = ResourceBudget.standard.maximumPasteBytes
    /// Estimated text retained by undo history before older history is dropped.
    var undoByteLimit = ComposerTextView.undoByteLimit(for: .standard)
    var undoLevels: Int {
        get { composerUndoManager.levelsOfUndo }
        set { composerUndoManager.levelsOfUndo = max(1, newValue) }
    }

    /// File URLs accepted from one paste or drop. The host applies the server's
    /// attachment-count limit; this only bounds the transient array.
    static let maximumFilesPerInput = 100
    static let pasteTypes: [NSPasteboard.PasteboardType] = [.fileURL, .string, .png, .tiff]

    /// Undo retains at most as much text as the whole unsent-text budget.
    static func undoByteLimit(for budget: ResourceBudget) -> Int { budget.unsentText.bytes }

    private let composerUndoManager = ComposerUndoManager()
    /// TextKit 1 ownership root: the view holds its storage, the storage owns the
    /// layout manager, which owns the container (whose back-reference is weak).
    private var retainedTextStorage: NSTextStorage?

    /// Running sizes of the whole text (including marked text), updated per edit.
    private(set) var metrics = ComposerTextMetrics.zero
    private var pendingDelta = ComposerTextMetrics.zero
    private(set) var metricsRecountCount = 0
    private(set) var undoRetainedBytesEstimate = 0

    private var isApplyingMarkedText = false
    private var programmaticChangeDepth = 0
    private var currentKeyEvent: NSEvent?
    private(set) var isApplyingHistory = false

    /// `true` while the composer itself replaces text (draft load, clear). Such
    /// changes bypass the budget, never register undo, and are not user edits.
    var isPerformingProgrammaticChange: Bool { programmaticChangeDepth > 0 }

    // MARK: Construction

    static func make() -> ComposerTextView {
        ComposerTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    }

    override convenience init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: frameRect.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        // `storage` stays alive until the designated initializer retains it.
        self.init(frame: frameRect, textContainer: container)
        withExtendedLifetime(storage) {}
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        retainedTextStorage = textStorage
        composerUndoManager.owner = self
        configure()
    }

    @available(*, unavailable, message: "The composer is built in code only")
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        allowsImageEditing = false
        allowsDocumentBackgroundColorChange = false
        isFieldEditor = false
        // Substitutions corrupt code and usernames; users can still enable them for
        // this view and session from Edit ▸ Substitutions.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false  // keeps pastes byte-exact
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = true  // system-managed; see docs/research/apple.md
        inlinePredictionType = .no  // predictions interfere with Return-to-send
        if #available(macOS 15.0, *) {
            mathExpressionCompletionType = .no
            writingToolsBehavior = .limited
        }
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        allowsUndo = true
        displaysLinkToolTips = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 0, height: 4)
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        font = bodyFont
        textColor = .textColor
        insertionPointColor = .textColor
        typingAttributes = [.font: bodyFont, .foregroundColor: NSColor.textColor]
        composerUndoManager.levelsOfUndo = ResourceBudget.standard.composerUndoLevels
        updateDragTypeRegistration()
        setAccessibilityRole(.textArea)
    }

    /// Applies the injected budget (undo levels, paste and undo byte ceilings).
    func apply(budget: ResourceBudget) {
        maximumPasteBytes = budget.maximumPasteBytes
        undoByteLimit = Self.undoByteLimit(for: budget)
        undoLevels = budget.composerUndoLevels
    }

    // MARK: Undo

    override var undoManager: UndoManager? { composerUndoManager }

    /// Drops all undo/redo history (after send, on draft switch, on sign-out).
    func clearUndoHistory() {
        breakUndoCoalescing()
        composerUndoManager.removeAllActions()
        undoRetainedBytesEstimate = 0
    }

    // `NSWindow.undo(_:)` would use the window's undo manager, so the composer
    // answers the Edit menu's Undo/Redo itself.
    @objc func undo(_ sender: Any?) { applyHistory(redo: false) }

    @objc func redo(_ sender: Any?) { applyHistory(redo: true) }

    /// NSTextView does not expose the resulting size of an undo group. Apply the
    /// whole group synchronously, without publishing intermediate draft changes;
    /// if its final growth cannot be admitted, apply its inverse immediately.
    /// Never veto an individual edit inside AppKit's group: that corrupts history.
    fileprivate func applyHistory(redo: Bool) {
        guard isEditable, !hasMarkedText(), !isApplyingHistory,
              redo ? composerUndoManager.canRedo : composerUndoManager.canUndo else { return }
        breakUndoCoalescing()
        let before = metrics.utf8
        let selection = selectedRanges
        let remaining = host?.composerTextViewRemainingDraftBytes(self) ?? .max
        isApplyingHistory = true
        if redo { composerUndoManager.applyRedo() } else { composerUndoManager.applyUndo() }
        let growth = metrics.utf8 - before
        if growth > 0, growth > remaining {
            if redo { composerUndoManager.applyUndo() } else { composerUndoManager.applyRedo() }
            selectedRanges = selection
            isApplyingHistory = false
            host?.composerTextView(self, didRefuse: .draftBudgetExceeded(limit: max(0, remaining)))
        } else {
            isApplyingHistory = false
            host?.composerTextViewDidApplyHistory(self)
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let result = validateUndoRedo(menuItem.action, menuItem: menuItem) { return result }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let result = validateUndoRedo(item.action, menuItem: item as? NSMenuItem) { return result }
        return super.validateUserInterfaceItem(item)
    }

    private func validateUndoRedo(_ action: Selector?, menuItem: NSMenuItem?) -> Bool? {
        switch action {
        case #selector(undo(_:)):
            menuItem?.title = composerUndoManager.undoMenuItemTitle
            return isEditable && !hasMarkedText() && composerUndoManager.canUndo
        case #selector(redo(_:)):
            menuItem?.title = composerUndoManager.redoMenuItemTitle
            return isEditable && !hasMarkedText() && composerUndoManager.canRedo
        default:
            return nil
        }
    }

    // MARK: Session-only state

    // Nothing about the composer (text, selection, find state) is encoded into
    // window restoration state.
    override class var restorableStateKeyPaths: [String] { [] }

    override func encodeRestorableState(with coder: NSCoder) {}

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Remember the event so `doCommand(by:)` can read its modifiers even when
        // AppKit did not route it through `NSApp.currentEvent`. Always call super:
        // the input context must see every key.
        let previous = currentKeyEvent
        currentKeyEvent = event
        defer { currentKeyEvent = previous }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only the exact Command-Return / Command-Enter chord, only when this view is
        // focused and no composition is active. Everything else goes to super.
        if Self.isCommandReturn(event), window?.firstResponder === self, !hasMarkedText() {
            host?.composerTextViewDismissCompletion(self)
            host?.composerTextViewRequestsSend(self)
            return true
        }
        if window?.firstResponder === self, !hasMarkedText(), let style = Self.markdownStyle(for: event) {
            applyMarkdown(style)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if hasMarkedText() {
            // The input method owns Return/Escape during composition. If one of
            // those still reaches us, Return confirms the composition (it never
            // sends and never inserts a newline) and Escape does nothing.
            switch selector {
            case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)),
                 #selector(insertLineBreak(_:)), #selector(insertParagraphSeparator(_:)):
                confirmComposition()
            case #selector(cancelOperation(_:)):
                break
            default:
                super.doCommand(by: selector)
            }
            return
        }

        let completionVisible = host?.isCompletionVisible ?? false
        switch selector {
        case #selector(insertNewline(_:)):
            handleReturn(completionVisible: completionVisible)
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)),
             #selector(insertParagraphSeparator(_:)):
            // Option-Return, Control-Return, and friends: always a plain "\n" (never
            // U+2028/U+2029, which do not round-trip as line breaks in messages).
            host?.composerTextViewDismissCompletion(self)
            insertPlainNewline()
        case #selector(insertTab(_:)) where completionVisible:
            _ = host?.composerTextViewAcceptCompletion(self)
        case #selector(moveDown(_:)) where completionVisible:
            host?.composerTextView(self, moveCompletionSelectionBy: 1)
        case #selector(moveUp(_:)) where completionVisible:
            host?.composerTextView(self, moveCompletionSelectionBy: -1)
        case #selector(moveUp(_:)) where (textStorage?.length ?? 0) == 0:
            host?.composerTextViewRequestsEditLastMessage(self)
        case Self.noopSelector where currentKeyEventIsCommandReturn:
            // Command-Return that reached the key-binding system (no key equivalent
            // intercepted it earlier) arrives as `noop:`.
            host?.composerTextViewDismissCompletion(self)
            host?.composerTextViewRequestsSend(self)
        default:
            super.doCommand(by: selector)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        // NSTextView would open the system completion list; Escape means "close the
        // popup, else cancel/dismiss" in the composer.
        if hasMarkedText() { return }
        if host?.isCompletionVisible == true {
            host?.composerTextViewDismissCompletion(self)
            return
        }
        host?.composerTextViewDidPressEscape(self)
    }

    private func handleReturn(completionVisible: Bool) {
        if completionVisible {
            // Return accepts the highlighted suggestion; it never also sends, even
            // when the acceptance is refused (e.g. by the draft budget).
            _ = host?.composerTextViewAcceptCompletion(self)
            return
        }
        let modifiers = activeModifierFlags
        if modifiers.contains(.shift) || modifiers.contains(.option) {
            insertPlainNewline()
            return
        }
        switch sendBehavior {
        case .returnSends:
            host?.composerTextViewRequestsSend(self)
        case .commandReturnSends:
            if modifiers.contains(.command) {
                host?.composerTextViewRequestsSend(self)
            } else {
                insertPlainNewline()
            }
        }
    }

    private func insertPlainNewline() {
        insertNewlineIgnoringFieldEditor(nil)
    }

    private static let noopSelector = Selector(("noop:"))

    private var keyEventForCommands: NSEvent? {
        if let currentKeyEvent { return currentKeyEvent }
        if let event = NSApp.currentEvent, event.type == .keyDown { return event }
        return nil
    }

    private var activeModifierFlags: NSEvent.ModifierFlags {
        keyEventForCommands?.modifierFlags.intersection([.shift, .option, .command, .control]) ?? []
    }

    private var currentKeyEventIsCommandReturn: Bool {
        keyEventForCommands.map(Self.isCommandReturn) ?? false
    }

    /// Return (kVK_Return = 36) or keypad Enter (kVK_ANSI_KeypadEnter = 76) with
    /// Command as the only modifier.
    static func isCommandReturn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .option, .command, .control])
        return modifiers == .command && (event.keyCode == 36 || event.keyCode == 76)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { host?.composerTextViewDidResignFirstResponder(self) }
        return resigned
    }

    // MARK: Input method composition

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasApplying = isApplyingMarkedText
        isApplyingMarkedText = true
        defer { isApplyingMarkedText = wasApplying }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Composition updates were exempt from the budget; the commit is checked
        // here, before AppKit unmarks the text, so a refused commit can remove the
        // uncommitted composition instead of leaving it behind as plain text.
        if hasMarkedText(), programmaticChangeDepth == 0, !compositionCommitFits(string, replacementRange) {
            let marked = markedRange()
            super.insertText("", replacementRange: marked)
            inputContext?.discardMarkedText()
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Commits the current composition as-is (used when Return reaches the view
    /// during composition, and before programmatic insertions).
    func confirmComposition() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
    }

    override func unmarkText() {
        if hasMarkedText(), programmaticChangeDepth == 0, !isApplyingMarkedText,
           let storage = textStorage {
            let marked = markedRange()
            let text = storage.mutableString.substring(with: marked)
            if !compositionCommitFits(text, marked) {
                super.insertText("", replacementRange: marked)
            }
        }
        super.unmarkText()
    }

    private func compositionCommitFits(_ string: Any, _ replacementRange: NSRange) -> Bool {
        let committed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let target = replacementRange.location == NSNotFound ? markedRange() : replacementRange
        let growth = committed.utf8.count - utf8Count(in: target)
        let remaining = host?.composerTextViewRemainingDraftBytes(self) ?? .max
        if growth <= remaining { return true }
        host?.composerTextView(self, didRefuse: .draftBudgetExceeded(limit: max(0, remaining)))
        return false
    }

    // MARK: Budget enforcement and metrics

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard let replacementStrings, let storage = textStorage else {
            // Attribute-only change.
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        var removed = ComposerTextMetrics.zero
        var inserted = ComposerTextMetrics.zero
        for (index, value) in affectedRanges.enumerated() {
            let range = value.rangeValue
            guard range.location != NSNotFound, NSMaxRange(range) <= storage.length else {
                return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
            }
            if range.length > 0 {
                removed += ComposerTextMetrics(storage.mutableString.substring(with: range))
            }
            let replacement = index < replacementStrings.count ? replacementStrings[index] : ""
            inserted += ComposerTextMetrics(replacement)
        }

        let growth = inserted.utf8 - removed.utf8
        let isUndoOrRedo = composerUndoManager.isUndoing || composerUndoManager.isRedoing
        // Composition churn, programmatic loads, and undo/redo are not refused:
        // refusing an undo step would desynchronize NSTextView's undo stack.
        if growth > 0, !isApplyingMarkedText, programmaticChangeDepth == 0, !isUndoOrRedo {
            let remaining = host?.composerTextViewRemainingDraftBytes(self) ?? .max
            if growth > remaining {
                host?.composerTextView(self, didRefuse: .draftBudgetExceeded(limit: max(0, remaining)))
                return false
            }
        }

        if allowsUndo, !isApplyingMarkedText, programmaticChangeDepth == 0, !isUndoOrRedo {
            accountUndoCost(removed.utf8 + inserted.utf8)
        }
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else {
            return false
        }
        pendingDelta += inserted - removed
        return true
    }

    override func didChangeText() {
        applyPendingMetrics()
        super.didChangeText()
    }

    /// Keeps undo history's retained text within `undoByteLimit`. Older history is
    /// dropped *before* the new change registers, so the change itself (for
    /// example a large paste) stays undoable.
    private func accountUndoCost(_ cost: Int) {
        if undoRetainedBytesEstimate + cost > undoByteLimit, undoRetainedBytesEstimate > 0 {
            clearUndoHistory()
        }
        undoRetainedBytesEstimate += cost
    }

    private func applyPendingMetrics() {
        metrics += pendingDelta
        pendingDelta = .zero
        if metrics.utf16 != (textStorage?.length ?? 0) {
            // A change bypassed shouldChangeText (or was vetoed after approval).
            recountMetrics()
        }
    }

    private func recountMetrics() {
        metricsRecountCount += 1
        metrics = ComposerTextMetrics(textStorage?.string ?? "")
        pendingDelta = .zero
    }

    private func utf8Count(in range: NSRange) -> Int {
        guard let storage = textStorage, range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= storage.length
        else { return 0 }
        return storage.mutableString.substring(with: range).utf8.count
    }

    // MARK: Programmatic and user edits

    /// Replaces the whole text without undo registration, budget checks, or
    /// user-edit notifications (draft load/clear). Ends any composition first.
    func replaceAllTextProgrammatically(with text: String, selection: NSRange) {
        programmaticChangeDepth += 1
        defer { programmaticChangeDepth -= 1 }
        if hasMarkedText() {
            unmarkText()
            inputContext?.discardMarkedText()
        }
        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: NSAttributedString(string: text, attributes: typingAttributes))
        storage.endEditing()
        metrics = ComposerTextMetrics(text)
        pendingDelta = .zero
        setSelectedRange(Self.clamp(selection, in: storage.mutableString))
        clearUndoHistory()
        scrollRangeToVisible(selectedRange())
    }

    /// Replaces `range` as one undoable user edit (completion acceptance, emoji
    /// insertion). Subject to the draft budget. Returns `false` when refused.
    @discardableResult
    func replaceAsUserEdit(_ range: NSRange, with text: String) -> Bool {
        guard let storage = textStorage, range.location != NSNotFound, NSMaxRange(range) <= storage.length else {
            return false
        }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        didChangeText()
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// Inserts text at the caret (replacing the selection), committing any active
    /// composition first. Used by the emoji picker.
    @discardableResult
    func insertAtCaret(_ text: String) -> Bool {
        confirmComposition()
        let range = rangeForUserTextChange
        guard range.location != NSNotFound else { return false }
        return replaceAsUserEdit(range, with: text)
    }

    /// Clamps a restored selection to the text and to composed-character
    /// boundaries, so a stale selection never splits a surrogate pair or cluster.
    static func clamp(_ range: NSRange, in string: NSString) -> NSRange {
        let length = string.length
        var start = range.location == NSNotFound ? length : min(max(0, range.location), length)
        var end = range.length > length - start ? length : start + max(0, range.length)
        if start < length { start = string.rangeOfComposedCharacterSequence(at: start).location }
        if end > start, end < length {
            let cluster = string.rangeOfComposedCharacterSequence(at: end)
            if cluster.location < end { end = NSMaxRange(cluster) }
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: Paste and drop

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { Self.pasteTypes }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { Self.pasteTypes }

    override func preferredPasteboardType(
        from availableTypes: [NSPasteboard.PasteboardType],
        restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?
    ) -> NSPasteboard.PasteboardType? {
        // Files win over their icon/name representations, text wins over a picture
        // of the same text (as Office apps provide), images come last.
        let allowed = allowedTypes ?? Self.pasteTypes
        return Self.pasteTypes.first { allowed.contains($0) && availableTypes.contains($0) }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch Self.normalizedPasteType(type) {
        case .fileURL?: readFiles(from: pboard)
        case .string?: readText(from: pboard)
        case .png?, .tiff?: readImage(from: pboard, type: Self.normalizedPasteType(type) ?? type)
        default: false
        }
    }

    static func normalizedPasteType(_ type: NSPasteboard.PasteboardType) -> NSPasteboard.PasteboardType? {
        switch type.rawValue {
        case NSPasteboard.PasteboardType.fileURL.rawValue, "NSFilenamesPboardType": .fileURL
        case NSPasteboard.PasteboardType.string.rawValue, "NSStringPboardType": .string
        case NSPasteboard.PasteboardType.png.rawValue, "Apple PNG pasteboard type": .png
        case NSPasteboard.PasteboardType.tiff.rawValue, "NeXT TIFF v4.0 pasteboard type": .tiff
        default: nil
        }
    }

    /// Checks the size of pasted text from its UTF-8 representation before any
    /// attributed or storage copy exists; refusals leave the text unchanged and
    /// return `false` (so a refused drag-move never deletes its source).
    private func readText(from pboard: NSPasteboard) -> Bool {
        guard let data = pboard.data(forType: .string) else { return false }
        if data.count > maximumPasteBytes {
            host?.composerTextView(self, didRefuse: .pasteTooLarge(limit: maximumPasteBytes))
            return false
        }
        guard let text = pboard.string(forType: .string) else { return false }
        // AppKit can report success even when shouldChangeText vetoes insertion.
        // Use the shared editing path so a rejected drag cannot delete its source.
        return insertAtCaret(text)
    }

    private func readFiles(from pboard: NSPasteboard) -> Bool {
        let itemCount = pboard.pasteboardItems?.count ?? 0
        guard itemCount <= Self.maximumFilesPerInput else {
            host?.composerTextView(self, didRefuse: .tooManyFiles(limit: Self.maximumFilesPerInput))
            return false
        }
        let objects = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        let urls = objects.compactMap { ($0 as? NSURL) as URL? }.filter(\.isFileURL)
        guard !urls.isEmpty else { return false }
        host?.composerTextView(self, didReceiveFiles: Array(urls.prefix(Self.maximumFilesPerInput)))
        return true
    }

    private func readImage(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let data = pboard.data(forType: type) else { return false }
        guard data.count <= maximumImageBytes else {
            host?.composerTextView(self, didRefuse: .pasteTooLarge(limit: maximumImageBytes))
            return false
        }
        return host?.composerTextView(self, didReceiveImage: data, typeIdentifier: type.rawValue) ?? false
    }
}

/// Every caller, including AppKit commands using the manager directly, goes
/// through the same whole-group admission check.
private final class ComposerUndoManager: UndoManager {
    weak var owner: ComposerTextView?
    override func undo() { owner?.applyHistory(redo: false) }
    override func redo() { owner?.applyHistory(redo: true) }
    func applyUndo() { super.undo() }
    func applyRedo() { super.redo() }
}
