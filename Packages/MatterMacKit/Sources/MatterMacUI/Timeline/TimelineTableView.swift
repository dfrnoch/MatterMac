import AppKit

/// The timeline's table: keyboard handling (Return → reply, Escape → clear selection,
/// Cmd-C → copy selected messages), first-click text selection in message bodies, and
/// debug counters for row operations (tests assert that ordinary events never reload
/// the whole table).
final class TimelineTableView: NSTableView {
    struct Counters: Equatable {
        var fullReloads = 0
        var rowReloads = 0
        var insertCalls = 0
        var insertedRows = 0
        var removeCalls = 0
        var removedRows = 0
        var moveCalls = 0
        var heightNotes = 0
        var notedRows = 0
    }

    var counters = Counters()
    weak var host: (any TimelineCellHost)?

    override func reloadData() {
        counters.fullReloads += 1
        super.reloadData()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        counters.rowReloads += 1
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    override func insertRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        counters.insertCalls += 1
        counters.insertedRows += indexes.count
        super.insertRows(at: indexes, withAnimation: animationOptions)
    }

    override func removeRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        counters.removeCalls += 1
        counters.removedRows += indexes.count
        super.removeRows(at: indexes, withAnimation: animationOptions)
    }

    override func moveRow(at oldIndex: Int, to newIndex: Int) {
        counters.moveCalls += 1
        super.moveRow(at: oldIndex, to: newIndex)
    }

    // MARK: - Column width

    /// The single column always spans the table. `NSTableColumn` starts at 100 pt and
    /// column autoresizing only applies size *deltas*, so without this the cell view
    /// stays ~100 pt wide while its subviews (laid out for the viewport width) draw
    /// outside it — visible, but unreachable by hit testing: links, thumbnails and
    /// reaction chips beyond the first 100 pt ignored clicks.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitColumnToWidth()
    }

    func fitColumnToWidth() {
        guard tableColumns.count == 1, let column = tableColumns.first else { return }
        let width = max(column.minWidth, bounds.width)
        if abs(column.width - width) > 0.25 { column.width = width }
    }

    override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
        counters.heightNotes += 1
        counters.notedRows += indexSet.count
        super.noteHeightOfRows(withIndexesChanged: indexSet)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            // Control-Return: the selected message's actions menu; Return: reply.
            if event.modifierFlags.intersection([.command, .option, .shift, .control]) == .control {
                if host?.presentActionsMenu() == true { return }
            } else if host?.handleReturnKey() == true {
                return
            }
        case 53:
            if host?.handleEscapeKey() == true { return }
        case 49 where event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty:
            if host?.handleSpaceKey() == true { return } // Space: preview the row's image
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if host?.handleEscapeKey() != true { super.cancelOperation(sender) }
    }

    @objc func copy(_ sender: Any?) {
        _ = host?.copySelectedMessages()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return host?.canCopySelectedMessages() ?? false }
        return super.validateUserInterfaceItem(item)
    }

    /// Allow message text to take the first click so selection/drag works immediately.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is MessageBodyTextView { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}
