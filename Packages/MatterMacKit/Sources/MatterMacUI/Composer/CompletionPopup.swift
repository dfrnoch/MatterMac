import AppKit

/// Borderless, non-activating panel that never becomes key or main, so the
/// composer keeps first responder (and its input method) while suggestions show.
final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The suggestion list next to the caret. Keyboard navigation is driven by the
/// text view (Up/Down/Tab/Return/Escape arrive through `doCommand(by:)`); the list
/// only renders, reports clicks, and announces the selection to VoiceOver.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let maximumItems = 8
    static let rowHeight: CGFloat = 26
    static let width: CGFloat = 320
    static let verticalPadding: CGFloat = 4

    private(set) var items: [CompletionItem] = []
    private(set) var selectedIndex = 0
    private(set) var isVisible = false
    /// Last VoiceOver announcement text (content of visible suggestions only).
    private(set) var lastAnnouncement: String?

    /// Called with the clicked row after the selection moved to it.
    var onClickAccept: (() -> Void)?
    /// Element that VoiceOver announcements are posted for (the text view).
    weak var announcementElement: NSView?

    private var panel: CompletionPanel?
    private let tableView = NSTableView()

    var selectedItem: CompletionItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// The panel window, if it was created (for tests and positioning checks).
    var window: NSWindow? { panel }

    func show(items newItems: [CompletionItem], anchor: NSRect, parent: NSWindow) {
        items = Array(newItems.prefix(Self.maximumItems))
        guard !items.isEmpty else {
            dismiss()
            return
        }
        selectedIndex = 0
        let panel = panel ?? makePanel()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)

        let size = NSSize(width: Self.width,
                          height: CGFloat(items.count) * Self.rowHeight + Self.verticalPadding * 2)
        panel.setFrame(NSRect(origin: Self.origin(for: size, anchor: anchor, screen: parent.screen), size: size),
                       display: false)
        // Only attach to a window that is on screen; an offscreen (test) window
        // keeps the list logical-only instead of flashing a panel on the display.
        if parent.isVisible {
            if panel.parent !== parent {
                panel.parent?.removeChildWindow(panel)
                parent.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }
        isVisible = true
        announceSelection()
    }

    func moveSelection(by delta: Int) {
        guard isVisible, !items.isEmpty else { return }
        let count = items.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
        announceSelection()
    }

    func dismiss() {
        let wasVisible = isVisible
        isVisible = false
        items = []
        selectedIndex = 0
        guard let panel else { return }
        if wasVisible { tableView.reloadData() }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Above the trigger character (the composer sits at the bottom of the
    /// window); below it when there is no room above; kept inside the screen.
    static func origin(for size: NSSize, anchor: NSRect, screen: NSScreen?) -> NSPoint {
        var origin = NSPoint(x: anchor.minX - 8, y: anchor.maxY + 4)
        if let visible = screen?.visibleFrame {
            if origin.y + size.height > visible.maxY { origin.y = anchor.minY - 4 - size.height }
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        }
        return origin
    }

    private func announceSelection() {
        guard let item = selectedItem else { return }
        var text = item.title
        if let subtitle = item.subtitle, !subtitle.isEmpty { text += ", " + subtitle }
        text += ", " + String(localized: "\(selectedIndex + 1) of \(items.count)")
        lastAnnouncement = text
        NSAccessibility.post(element: announcementElement ?? tableView, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func makePanel() -> CompletionPanel {
        let panel = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.refusesFirstResponder = true
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.setAccessibilityLabel(String(localized: "Suggestions"))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.verticalPadding),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.verticalPadding),
        ])
        panel.contentView = background
        self.panel = panel
        return panel
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        selectedIndex = row
        onClickAccept?()
    }

    // MARK: NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = CompletionCellView.reuseIdentifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? CompletionCellView)
            ?? CompletionCellView(identifier: identifier)
        cell.configure(with: items[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if items.indices.contains(row), row != selectedIndex {
            selectedIndex = row
            announceSelection()
        }
    }
}

/// One suggestion row: optional leading glyph, title, secondary subtitle.
final class CompletionCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("CompletionCellView")

    private let leadingLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        leadingLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        leadingLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [leadingLabel, titleLabel, subtitleLabel] {
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
        }
        let stack = NSStackView(views: [leadingLabel, titleLabel, subtitleLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = titleLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with item: CompletionItem) {
        leadingLabel.stringValue = item.leadingText ?? ""
        leadingLabel.isHidden = (item.leadingText ?? "").isEmpty
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle ?? ""
        subtitleLabel.isHidden = (item.subtitle ?? "").isEmpty
        setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
