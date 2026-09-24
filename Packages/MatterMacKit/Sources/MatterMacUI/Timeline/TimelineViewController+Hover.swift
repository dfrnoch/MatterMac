import AppKit
import MatterMacModels
import MatterMacCore

/// Hover handling: one `HoverActionBar` overlay for the hovered message row (or, when
/// the pointer is not over a message, the single selected row), a subtle hover
/// background, and the continuation-row timestamp. Driven by a mouse-moved tracking area
/// on the container, scrolling, snapshot application and selection changes; there is
/// no timer. Nothing here changes row heights.
extension TimelineViewController {
    func installHoverBar(in container: NSView) {
        hoverBar.onAction = { [weak self] action in self?.performPrepared(action) }
        hoverBar.onMore = { [weak self] button in self?.presentMoreMenu(from: button) }
        container.addSubview(hoverBar)
    }

    // MARK: - Events

    func hoverMouseMoved(_ event: NSEvent) {
        hoverPointerLocation = event.locationInWindow
        updateHover()
    }

    func hoverMouseExited() {
        hoverPointerLocation = nil
        updateHover()
    }

    /// Re-evaluates the hovered row after scrolling, content or selection changes.
    func refreshHover() {
        guard isViewLoaded else { return }
        if hoverPointerLocation != nil, NSApp.isActive, let window = view.window, window.isKeyWindow {
            // The pointer may have stayed still while rows moved beneath it.
            hoverPointerLocation = window.mouseLocationOutsideOfEventStream
        }
        updateHover()
    }

    // MARK: - State

    /// The message row the bar belongs to: the row under the pointer (kept while the
    /// pointer is over the bar itself), else the only selected row.
    func hoverTargetRow() -> (row: Int, isPointer: Bool)? {
        if let location = hoverPointerLocation {
            let local = view.convert(location, from: nil)
            if !hoverBar.isHidden, hoverBar.frame.contains(local), let id = hoverBar.itemID, let row = rowIndex[id] {
                return (row, true)
            }
            let clip = scrollView.contentView
            if clip.bounds.contains(clip.convert(location, from: nil)) {
                let row = tableView.row(at: tableView.convert(location, from: nil))
                if items.indices.contains(row), items[row].post?.postID != nil { return (row, true) }
            }
        }
        let selected = tableView.selectedRowIndexes
        if selected.count == 1, let row = selected.first, items.indices.contains(row), items[row].post != nil {
            return (row, false)
        }
        return nil
    }

    func updateHover() {
        let target = hoverTargetRow()
        let pointerID = target.flatMap { $0.isPointer ? items[$0.row].id : nil }
        setHoverHighlight(pointerID)
        setHoverTimestamp(target.map { items[$0.row].id })
        guard let target, let post = items[target.row].post,
              hoverBar.configure(item: items[target.row].id, post: post, emojiText: { [renderer] in renderer.emojiText(for: $0) })
        else {
            hoverBar.reset()
            return
        }
        positionHoverBar(row: target.row)
    }

    func positionHoverBar(row: Int) {
        let rowRect = view.convert(tableView.rect(ofRow: row), from: tableView)
        let clip = view.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let visibleRow = rowRect.intersection(clip)
        guard !visibleRow.isNull, visibleRow.height > 4 else {
            hoverBar.reset()
            return
        }
        let width = hoverBar.preferredWidth
        let height = HoverActionBar.height
        let x = max(clip.minX + 4, rowRect.maxX - width - TimelineRowMetrics.horizontalInset)
        // Straddle the row's top edge (like the official client), kept inside the viewport.
        var frame: NSRect
        if view.isFlipped {
            let top = min(max(rowRect.minY - height / 2 + 4, clip.minY + 2), clip.maxY - height - 2)
            frame = NSRect(x: x, y: top, width: width, height: height)
        } else {
            let bottom = max(min(rowRect.maxY - height / 2 - 4, clip.maxY - height - 2), clip.minY + 2)
            frame = NSRect(x: x, y: bottom, width: width, height: height)
        }
        frame = frame.integral
        if hoverBar.frame != frame { hoverBar.frame = frame }
        hoverBar.isHidden = false
        hoverBar.needsLayout = true
    }

    private func setHoverHighlight(_ id: TimelineItemID?) {
        guard id != hoverHighlightedID else { return }
        if let old = hoverHighlightedID, let row = rowIndex[old] {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? TimelineRowView)?.isHovered = false
        }
        hoverHighlightedID = id
        if let id, let row = rowIndex[id] {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? TimelineRowView)?.isHovered = true
        }
    }

    private func setHoverTimestamp(_ id: TimelineItemID?) {
        guard id != hoverTimestampID else { return }
        if let old = hoverTimestampID, let row = rowIndex[old] {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?.setHovered(false)
        }
        hoverTimestampID = id
        if let id, let row = rowIndex[id] {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?.setHovered(true)
        }
    }

    // MARK: - Menus

    /// The "More" menu: the row's context-menu items.
    func moreMenu(for postID: PostID) -> NSMenu? {
        guard let row = rowIndex[TimelineItemID(.post(postID))], let post = items[row].post else { return nil }
        let menu = NSMenu()
        populate(menu, post: post)
        return menu.items.isEmpty ? nil : menu
    }

    func presentMoreMenu(from button: NSButton) {
        guard let postID = hoverBar.postID, let menu = moreMenu(for: postID) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    /// Keyboard access to the actions of the selected row (Control-Return).
    func presentActionsMenuForSelection() -> Bool {
        let row = tableView.selectedRow
        guard items.indices.contains(row), let post = items[row].post, post.postID != nil else { return false }
        let menu = NSMenu()
        populate(menu, post: post)
        guard !menu.items.isEmpty else { return false }
        updateHover()
        if !hoverBar.isHidden, hoverBar.postID == post.postID, let more = hoverBar.button(.more) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
        } else {
            let rect = tableView.rect(ofRow: row)
            menu.popUp(positioning: nil, at: NSPoint(x: TimelineRowMetrics.contentLeading, y: rect.minY + 20), in: tableView)
        }
        return true
    }
}
