import AppKit
import MatterMacModels
import MatterMacCore

/// AppKit retains neither table delegate nor data source; the controller owns this
/// adapter, which in turn holds only a weak reference back to the controller.
final class TimelineTableAdapter: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var controller: TimelineViewController?
    init(controller: TimelineViewController) { self.controller = controller }

    func numberOfRows(in tableView: NSTableView) -> Int { controller?.items.count ?? 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let c = controller, c.rowHeights.indices.contains(row) else { return 1 }
        return c.rowHeights[row]
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let c = controller, c.items.indices.contains(row) else { return nil }
        let item = c.items[row]
        let layout = c.displayLayout(forRow: row)
        switch (item.content, layout) {
        case (.post(let post), .message(let layout)):
            let cell = tableView.makeView(withIdentifier: MessageCellView.reuseIdentifier, owner: nil) as? MessageCellView
                ?? MessageCellView(frame: .zero)
            cell.configure(item: item, post: post, layout: layout,
                           body: c.layouter.bodyText(for: item, post: post), host: c)
            cell.setHovered(c.hoverTimestampID == item.id)
            return cell
        case (.dateSeparator(let date), .separator(let layout)):
            let cell = tableView.makeView(withIdentifier: DateSeparatorCellView.reuseIdentifier, owner: nil) as? DateSeparatorCellView
                ?? DateSeparatorCellView(frame: .zero)
            cell.configure(date: date, layout: layout, fonts: c.rowMetrics.fonts)
            return cell
        case (.unreadBoundary(let count), .separator(let layout)):
            let cell = tableView.makeView(withIdentifier: UnreadBoundaryCellView.reuseIdentifier, owner: nil) as? UnreadBoundaryCellView
                ?? UnreadBoundaryCellView(frame: .zero)
            cell.configure(count: count, layout: layout, fonts: c.rowMetrics.fonts)
            return cell
        case (.gap(let gap), .separator(let layout)):
            let cell = tableView.makeView(withIdentifier: GapCellView.reuseIdentifier, owner: nil) as? GapCellView
                ?? GapCellView(frame: .zero)
            cell.configure(gap: gap, layout: layout, metrics: c.rowMetrics, host: c)
            return cell
        case (.historyStart(let name), .separator(let layout)):
            let cell = tableView.makeView(withIdentifier: HistoryStartCellView.reuseIdentifier, owner: nil) as? HistoryStartCellView
                ?? HistoryStartCellView(frame: .zero)
            cell.configure(channelName: name, layout: layout, metrics: c.rowMetrics)
            return cell
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: TimelineRowView.reuseIdentifier, owner: nil) as? TimelineRowView
            ?? TimelineRowView(frame: .zero)
        if let c = controller, c.items.indices.contains(row) { rowView.isHovered = c.hoverHighlightedID == c.items[row].id }
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        controller?.refreshHover()
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView.view(atColumn: 0) as? MessageCellView)?.didEndDisplay()
        (rowView.view(atColumn: 0) as? GapCellView)?.didEndDisplay()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let c = controller, c.items.indices.contains(row) else { return false }
        return c.items[row].post != nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let c = controller else { return }
        c.populate(menu, row: c.tableView.clickedRow)
    }
}

extension TimelineViewController: TimelineCellHost {
    var renderer: MessageRenderer { layouter.renderer }
    var rowMetrics: TimelineRowMetrics { layouter.metrics }
    func perform(_ action: TimelineAction) { delegate?.timeline(perform: action) }
    func image(for request: TimelineImageRequest) -> NSImage? { delegate?.timelineImage(for: request) }
    func registerImageDemand(_ request: TimelineImageRequest) {
        let count = imageDemand[request, default: 0]
        imageDemand[request] = count + 1
        if count == 0 { delegate?.timelineNeedsImage(request) }
    }
    func unregisterImageDemand(_ request: TimelineImageRequest) {
        guard let count = imageDemand[request] else { return }
        if count > 1 { imageDemand[request] = count - 1 }
        else {
            imageDemand[request] = nil
            delegate?.timelineNoLongerNeedsImage(request)
        }
    }
    func requestOlderFromGapButton() { delegate?.timelineRequestsOlder() }
    func requestNewerFromGapButton() { delegate?.timelineRequestsNewer() }
    func bodyTextViewReceivedMouseDown(_ textView: NSTextView) {
        let row = tableView.row(for: textView)
        if row >= 0, !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
    func canCopySelectedMessages() -> Bool {
        tableView.selectedRowIndexes.contains { items.indices.contains($0) && items[$0].post != nil }
    }
    func copySelectedMessages() -> Bool {
        let texts = tableView.selectedRowIndexes.compactMap { row -> String? in
            guard items.indices.contains(row), let post = items[row].post else { return nil }
            switch post.body {
            case .document(let document, _): return document.plainText
            case .system(let text): return text
            case .unsupported(_, let text): return text
            case .deleted: return nil
            }
        }
        guard !texts.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texts.joined(separator: "\n\n"), forType: .string)
        return true
    }
    func handleReturnKey() -> Bool {
        let row = tableView.selectedRow
        guard items.indices.contains(row), let post = items[row].post,
              post.actions.canReply, let id = post.rootID ?? post.postID else { return false }
        perform(.reply(id))
        return true
    }
    func presentActionsMenu() -> Bool { presentActionsMenuForSelection() }
    func handleEscapeKey() -> Bool {
        guard tableView.selectedRow >= 0 else { return false }
        tableView.deselectAll(nil)
        return true
    }
    func forwardKeyToTable(_ event: NSEvent) { tableView.keyDown(with: event) }
    func contextMenu(for textView: NSTextView, event: NSEvent, link: URL?) -> NSMenu? {
        let menu = NSMenu()
        populate(menu, row: tableView.row(for: textView))
        if let link, let safe = SafeLink(link.absoluteString) {
            if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            let open = NSMenuItem(title: TimelineStrings.menuOpenLink, action: #selector(menuAction(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = TimelineAction.openLink(safe)
            let copy = NSMenuItem(title: TimelineStrings.menuCopyLinkAddress, action: #selector(menuAction(_:)),
                                  keyEquivalent: "")
            copy.target = self
            copy.representedObject = TimelineAction.copyLink(safe.url)
            menu.insertItem(copy, at: 0)
            menu.insertItem(open, at: 0)
        }
        return menu.items.isEmpty ? nil : menu
    }
    func contextMenu(forRowContaining view: NSView, leadingItems: [NSMenuItem]) -> NSMenu? {
        let menu = NSMenu()
        populate(menu, row: tableView.row(for: view))
        if !leadingItems.isEmpty {
            if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            for item in leadingItems.reversed() { menu.insertItem(item, at: 0) }
        }
        return menu.items.isEmpty ? nil : menu
    }
    func handleSpaceKey() -> Bool {
        let row = tableView.selectedRow
        guard items.indices.contains(row), let post = items[row].post,
              let image = post.files.prefix(TimelineRowMetrics.maximumDisplayedFiles)
                  .first(where: TimelineRowMetrics.showsThumbnail) else { return false }
        perform(.previewImage(image))
        return true
    }
    func populate(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        guard items.indices.contains(row), let post = items[row].post else { return }
        populate(menu, post: post)
    }
    func populate(_ menu: NSMenu, post: PostPresentation) {
        for entry in TimelinePostActions.entries(for: post) {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            addMenuItem(entry.title, action: entry.action, symbol: entry.symbol, to: menu)
        }
    }
    private func addMenuItem(_ title: String, action: TimelineAction, symbol: String? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? TimelineAction else { return }
        performPrepared(action)
    }
    /// Performs a user-chosen action after writing any pasteboard content it implies.
    func performPrepared(_ action: TimelineAction) {
        TimelinePostActions.prepare(action)
        perform(action)
    }
}
