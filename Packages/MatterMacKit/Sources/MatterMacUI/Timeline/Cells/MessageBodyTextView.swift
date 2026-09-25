import AppKit

/// Selectable, non-editable message body. TextKit 1 (`NSTextView(usingTextLayoutManager:
/// false)`), configured exactly like `TextMeasurer` so display matches measurement.
///
/// - Links: `.link` runs (SafeLink only) are reported through the cell's delegate
///   method `textView(_:clickedOnLink:at:)`; the text view never opens anything.
/// - Mentions: clicks on `.matterMacMention` / `.matterMacChannelMention` runs without a
///   drag are reported to the host.
/// - Cmd-C without a text selection copies the selected message(s) via the host;
///   Return/Escape/arrow keys are forwarded to the table for keyboard navigation.
final class MessageBodyTextView: NSTextView {
    weak var host: (any TimelineCellHost)?
    /// Called for a click on a mention run: (attribute key, value).
    var onMentionClick: ((NSAttributedString.Key, String) -> Void)?

    /// Configures a freshly created instance. Call once after
    /// `MessageBodyTextView(usingTextLayoutManager: false)`.
    func configureForTimeline() {
        textContainer?.replaceLayoutManager(TimelineLayoutManager())
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsUndo = false
        usesFontPanel = false
        usesRuler = false
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
        drawsBackground = false
        backgroundColor = .clear
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        displaysLinkToolTips = true
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        if let container = textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
        }
        layoutManager?.allowsNonContiguousLayout = true
        layoutManager?.backgroundLayoutEnabled = false
    }

    /// Replaces the text and lays it out at exactly `width` (the measured width).
    func setText(_ text: NSAttributedString, width: CGFloat) {
        textContainer?.size = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        textStorage?.setAttributedString(text)
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    func clear() {
        textStorage?.setAttributedString(NSAttributedString())
        setSelectedRange(NSRange(location: 0, length: 0))
        onMentionClick = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let mention = mentionAttribute(at: event)
        host?.bodyTextViewReceivedMouseDown(self)
        super.mouseDown(with: event)
        // super runs the selection tracking loop until mouse-up. A click without a drag
        // leaves an empty selection; only then is it a mention activation.
        if let mention, selectedRange().length == 0 {
            onMentionClick?(mention.key, mention.value)
        }
    }

    private func mentionAttribute(at event: NSEvent) -> (key: NSAttributedString.Key, value: String)? {
        guard event.clickCount == 1, let index = characterIndex(at: convert(event.locationInWindow, from: nil)),
              let storage = textStorage, index < storage.length
        else { return nil }
        for key in [NSAttributedString.Key.matterMacMention, .matterMacChannelMention] {
            if let value = storage.attribute(key, at: index, effectiveRange: nil) as? String { return (key, value) }
        }
        return nil
    }

    /// Character under a point, only if the point is inside that glyph's bounds.
    func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                             fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    func link(at point: NSPoint) -> URL? {
        guard let index = characterIndex(at: point), let storage = textStorage, index < storage.length else { return nil }
        return storage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }

    // MARK: - Menus

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return host?.contextMenu(for: self, event: event, link: link(at: point))
    }

    // MARK: - Copy and keys

    override func copy(_ sender: Any?) {
        if selectedRange().length == 0 {
            _ = host?.copySelectedMessages()
        } else {
            super.copy(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), selectedRange().length == 0 {
            return host?.canCopySelectedMessages() ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if host?.handleReturnKey() == true { return }
        case 49 where selectedRange().length == 0
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty:
            if host?.handleSpaceKey() == true { return } // Space: preview the row's image
        case 53: // Escape
            setSelectedRange(NSRange(location: 0, length: 0))
            if host?.handleEscapeKey() == true { return }
        case 125, 126: // Down, Up: row navigation
            if event.modifierFlags.intersection([.shift, .command, .option]).isEmpty {
                host?.forwardKeyToTable(event)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }
}
