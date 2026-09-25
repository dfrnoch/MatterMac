import AppKit
import MatterMacModels
import MatterMacCore

/// A stable scroll position: the first (partially) visible item and the distance from
/// its top to the top of the viewport. Survives prepends, trims, reflow, and scale
/// changes; `fallbacks` are the following items in case the anchor row disappears.
struct ScrollAnchor: Equatable {
    var itemID: TimelineItemID
    var offset: CGFloat
    var fallbacks: [TimelineItemID]
}

enum PositionTarget: Equatable {
    case bottom
    case anchor(ScrollAnchor?)
}

/// Identifies one state of a gap row. A paging request fires at most once per key, so a
/// gap that is loading (or whose neighbor did not change) never triggers repeatedly.
struct GapTriggerKey: Equatable {
    var revision: UInt64
    var neighbor: TimelineItemID?
}

struct VisibilityReport: Equatable {
    var first: PostID?
    var last: PostID?
    var isAtLiveEdge: Bool
}

extension TimelineViewController {
    // MARK: - Geometry

    func setBottomOverlayInset(_ height: CGFloat) {
        loadViewIfNeeded()
        let height = max(0, height)
        let top = max(0, view.safeAreaInsets.top)
        guard abs(scrollView.contentInsets.bottom - height) > 0.5
                || abs(scrollView.contentInsets.top - top) > 0.5 else { return }
        let target: PositionTarget = isPinnedToLiveEdge ? .bottom : .anchor(captureAnchor())
        performUpdate {
            var content = scrollView.contentInsets
            content.bottom = height
            content.top = top
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = content
            var scrollers = scrollView.scrollerInsets
            scrollers.bottom = height
            scrollers.top = top
            scrollView.scrollerInsets = scrollers
            scrollView.tile()
            settle(target)
            afterScrollPositionSettled()
            layoutNewMessagesButton()
        }
    }

    func widthBucket() -> Int {
        let width = scrollView.contentView.bounds.width
        guard width.isFinite, width >= TimelineMetrics.widthBucket * 20 else { return 80 }
        return Int(floor(width / TimelineMetrics.widthBucket))
    }

    /// The document rect currently visible, excluding content insets.
    var visibleDocumentRect: NSRect {
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        return NSRect(x: clip.bounds.minX, y: clip.bounds.minY + insets.top, width: clip.bounds.width,
                      height: max(0, clip.bounds.height - insets.top - insets.bottom))
    }

    private var maximumClipOriginY: CGFloat {
        let clip = scrollView.contentView
        var proposed = clip.bounds
        proposed.origin.y = tableView.frame.height + clip.bounds.height
        return clip.constrainBoundsRect(proposed).origin.y
    }

    func distanceFromBottom() -> CGFloat {
        max(0, maximumClipOriginY - scrollView.contentView.bounds.origin.y)
    }

    func setVisibleTop(_ top: CGFloat) {
        let clip = scrollView.contentView
        var proposed = clip.bounds
        proposed.origin.y = top - clip.contentInsets.top
        let origin = clip.constrainBoundsRect(proposed).origin
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollToBottomNow() {
        let clip = scrollView.contentView
        let target = NSPoint(x: clip.bounds.origin.x, y: maximumClipOriginY)
        guard target != clip.bounds.origin else { return }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Anchors

    func captureAnchor() -> ScrollAnchor? {
        guard !items.isEmpty else { return nil }
        let top = visibleDocumentRect.minY
        var row = tableView.row(at: NSPoint(x: 1, y: max(top, 0)))
        if row < 0 { row = top <= 0 ? 0 : items.count - 1 }
        row = min(max(row, 0), items.count - 1)
        let rect = tableView.rect(ofRow: row)
        let fallbackEnd = min(items.count, row + 9)
        let fallbacks = row + 1 < fallbackEnd ? items[(row + 1)..<fallbackEnd].map(\.id) : []
        return ScrollAnchor(itemID: items[row].id, offset: top - rect.minY, fallbacks: fallbacks)
    }

    func restore(_ anchor: ScrollAnchor) {
        var targetRow = rowIndex[anchor.itemID]
        var offset = anchor.offset
        if targetRow == nil {
            for id in anchor.fallbacks {
                if let row = rowIndex[id] {
                    targetRow = row
                    offset = 0
                    break
                }
            }
        }
        guard let row = targetRow, row < items.count else { return }
        setVisibleTop(tableView.rect(ofRow: row).minY + offset)
    }

    func position(_ target: PositionTarget) {
        switch target {
        case .bottom: scrollToBottomNow()
        case .anchor(let anchor):
            if let anchor { restore(anchor) } else { scrollToBottomNow() }
        }
    }

    /// Positions, then measures rows around the viewport until heights are stable
    /// (bounded iterations), re-positioning after every height change.
    func settle(_ target: PositionTarget) {
        position(target)
        for _ in 0..<4 {
            let changed = measureRowsNearViewport(screens: view.inLiveResize ? 0 : 1)
            if changed.isEmpty { break }
            noteHeights(changed)
            position(target)
        }
    }

    // MARK: - Measurement

    /// Measures (exactly, with TextKit 1) rows within `screens` viewport heights of the
    /// visible rect that are not yet measured for the current width bucket and font
    /// scale. Returns rows whose height changed.
    func measureRowsNearViewport(screens: CGFloat) -> IndexSet {
        guard !items.isEmpty else { return [] }
        let visible = visibleDocumentRect
        let expanded = visible.insetBy(dx: 0, dy: -visible.height * screens)
        let range = tableView.rows(in: expanded)
        var changed = IndexSet()
        guard range.length > 0 else { return changed }
        for row in range.location..<min(items.count, range.location + range.length) where measure(row: row) {
            changed.insert(row)
        }
        return changed
    }

    /// Returns `true` if the row's height changed.
    @discardableResult
    func measure(row: Int) -> Bool {
        guard row < items.count, rowTokens[row] != currentToken else { return false }
        let layout = layouter.exactLayout(for: items[row], bucket: currentToken.bucket)
        rowTokens[row] = currentToken
        if abs(rowHeights[row] - layout.height) > 0.01 {
            rowHeights[row] = layout.height
            return true
        }
        return false
    }

    func noteHeights(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: rows) }
        tableView.tile()
    }

    /// Exact layout for a row about to be displayed. If it differs from the height the
    /// table used (a row that became visible before it was measured), the correction is
    /// applied on the next run-loop turn with the scroll anchor preserved.
    func displayLayout(forRow row: Int) -> RowLayout {
        let item = items[row]
        let layout = layouter.exactLayout(for: item, bucket: currentToken.bucket)
        if rowTokens[row] != currentToken || abs(rowHeights[row] - layout.height) > 0.01 {
            rowTokens[row] = currentToken
            if abs(rowHeights[row] - layout.height) > 0.01 {
                rowHeights[row] = layout.height
                pendingHeightFixups.insert(item.id)
                scheduleHeightFixups()
            }
        }
        return layout
    }

    private func scheduleHeightFixups() {
        guard !heightFixupScheduled else { return }
        heightFixupScheduled = true
        perform(#selector(flushHeightFixups), with: nil, afterDelay: 0, inModes: [.common])
    }

    @objc func flushHeightFixups() {
        heightFixupScheduled = false
        guard !pendingHeightFixups.isEmpty else { return }
        let rows = IndexSet(pendingHeightFixups.compactMap { rowIndex[$0] })
        pendingHeightFixups.removeAll()
        guard !rows.isEmpty else { return }
        performUpdate {
            let target: PositionTarget = isPinnedToLiveEdge ? .bottom : .anchor(captureAnchor())
            noteHeights(rows)
            position(target)
        }
    }

    // MARK: - Viewport changes

    func handleViewportResize() {
        let bucket = widthBucket()
        let target: PositionTarget = isPinnedToLiveEdge ? .bottom : .anchor(lastAnchor ?? captureAnchor())
        if bucket != currentToken.bucket {
            currentToken = LayoutToken(bucket: bucket, scaleKey: layouter.fontScaleKey)
            var changed = IndexSet()
            for row in items.indices {
                if let cached = layouter.cachedLayout(for: items[row], bucket: bucket) {
                    rowTokens[row] = currentToken
                    if abs(cached.height - rowHeights[row]) > 0.01 {
                        rowHeights[row] = cached.height
                        changed.insert(row)
                    }
                } else if layouter.isCheap(items[row]) {
                    rowTokens[row] = currentToken
                    let height = layouter.exactLayout(for: items[row], bucket: bucket).height
                    if abs(height - rowHeights[row]) > 0.01 {
                        rowHeights[row] = height
                        changed.insert(row)
                    }
                } else {
                    // Keep the previous height as an estimate until the row is near.
                    rowTokens[row] = nil
                }
            }
            noteHeights(changed)
            // Displayed cells lay out at the old width; refresh them at the new one.
            reloadVisibleRows()
        }
        lastClipSize = scrollView.contentView.bounds.size
        settle(target)
        afterScrollPositionSettled()
    }

    @objc func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isPerformingUpdate, snapshot != nil else { return }
        performUpdate {
            if scrollView.contentView.bounds.size != lastClipSize {
                handleViewportResize()
                return
            }
            let anchor = captureAnchor()
            let changed = measureRowsNearViewport(screens: view.inLiveResize ? 0 : 1)
            if !changed.isEmpty {
                noteHeights(changed)
                if let anchor { restore(anchor) }
            }
            if distanceFromBottom() > TimelineMetrics.liveEdgeTolerance { explicitLiveEdgeJump = false }
            // Outside `performUpdate`, a bounds change is the user scrolling.
            userScrolledSinceReport = true
            afterScrollPositionSettled()
        }
    }

    /// Bookkeeping after any change of scroll position or content.
    func afterScrollPositionSettled() {
        guard let snapshot else { return }
        let atBottom = distanceFromBottom() <= TimelineMetrics.liveEdgeTolerance
        isPinnedToLiveEdge = atBottom && (snapshot.isAtLiveEdge || explicitLiveEdgeJump)
        if atBottom && snapshot.isAtLiveEdge {
            newItemsBelow = 0
            explicitLiveEdgeJump = false
        }
        lastAnchor = captureAnchor()
        lastClipSize = scrollView.contentView.bounds.size
        checkPagingTriggers()
        scheduleVisibilityReport()
        updateNewMessagesButton()
        refreshHover()
    }

    // MARK: - Paging

    func checkPagingTriggers() {
        let visible = visibleDocumentRect
        let threshold = visible.height * 1.5
        let olderID = TimelineItemID(.olderGap)
        if let row = rowIndex[olderID], case .gap(let gap) = items[row].content, gap.state == .idle {
            let rect = tableView.rect(ofRow: row)
            if visible.minY - rect.maxY <= threshold {
                let key = GapTriggerKey(revision: items[row].revision,
                                        neighbor: row + 1 < items.count ? items[row + 1].id : nil)
                if key != lastOlderTrigger {
                    lastOlderTrigger = key
                    counters.olderRequests += 1
                    delegate?.timelineRequestsOlder()
                }
            }
        }
        let newerID = TimelineItemID(.newerGap)
        if let row = rowIndex[newerID], case .gap(let gap) = items[row].content, gap.state == .idle {
            let rect = tableView.rect(ofRow: row)
            if rect.minY - visible.maxY <= threshold {
                let key = GapTriggerKey(revision: items[row].revision, neighbor: row > 0 ? items[row - 1].id : nil)
                if key != lastNewerTrigger {
                    lastNewerTrigger = key
                    counters.newerRequests += 1
                    delegate?.timelineRequestsNewer()
                }
            }
        }
    }

    // MARK: - Visibility reporting

    var isWindowVisibleForReporting: Bool {
        if let override = visibilityOverrideForTesting { return override }
        guard let window = view.window else { return false }
        return window.occlusionState.contains(.visible)
    }

    func scheduleVisibilityReport() {
        guard delegate != nil, isWindowVisibleForReporting, !visibilityReportScheduled else { return }
        visibilityReportScheduled = true
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, lastVisibilityReportUptime + Self.visibilityReportInterval - now)
        perform(#selector(flushVisibilityReport), with: nil, afterDelay: delay, inModes: [.common])
    }

    @objc func flushVisibilityReport() {
        visibilityReportScheduled = false
        guard let snapshot, isWindowVisibleForReporting else { return }
        let report = currentVisibilityReport(snapshot)
        guard report != lastVisibilityReport || userScrolledSinceReport else { return }
        lastVisibilityReport = report
        lastVisibilityReportUptime = ProcessInfo.processInfo.systemUptime
        counters.visibilityReports += 1
        let scrolled = userScrolledSinceReport
        userScrolledSinceReport = false
        delegate?.timelineVisibleRangeDidChange(first: report.first, last: report.last,
                                                isAtLiveEdge: report.isAtLiveEdge, userScrolled: scrolled)
    }

    func currentVisibilityReport(_ snapshot: TimelineSnapshot) -> VisibilityReport {
        let range = tableView.rows(in: visibleDocumentRect)
        var first: PostID?
        var last: PostID?
        if range.length > 0 {
            for row in range.location..<min(items.count, range.location + range.length) {
                guard let id = items[row].post?.postID else { continue }
                if first == nil { first = id }
                last = id
            }
        }
        let atLiveEdge = snapshot.isAtLiveEdge && distanceFromBottom() <= TimelineMetrics.liveEdgeTolerance
        return VisibilityReport(first: first, last: last, isAtLiveEdge: atLiveEdge)
    }

    func windowDidChange(_ window: NSWindow?) {
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: observedWindow)
        }
        observedWindow = window
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionDidChange(_:)),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    @objc func windowOcclusionDidChange(_ notification: Notification) {
        guard snapshot != nil else { return }
        if isWindowVisibleForReporting {
            lastVisibilityReport = nil
            scheduleVisibilityReport()
        }
    }

    func lastVisibleItemID() -> TimelineItemID? {
        let range = tableView.rows(in: visibleDocumentRect)
        guard range.length > 0 else { return items.last?.id }
        let row = min(items.count - 1, range.location + range.length - 1)
        return row >= 0 ? items[row].id : nil
    }

    // MARK: - New messages button

    func updateNewMessagesButton() {
        guard let snapshot, !items.isEmpty else {
            newMessagesButton.isHidden = true
            return
        }
        let distance = distanceFromBottom()
        let title: String?
        if newItemsBelow > 0 {
            title = TimelineStrings.newMessagesButton(newItemsBelow)
        } else if !isPinnedToLiveEdge,
                  !snapshot.isAtLiveEdge || distance > visibleDocumentRect.height {
            title = TimelineStrings.jumpToLatest
        } else {
            title = nil
        }
        guard let title else {
            newMessagesButton.isHidden = true
            return
        }
        let wasHidden = newMessagesButton.isHidden
        if newMessagesButton.title != title {
            newMessagesButton.title = title
            newMessagesButton.setAccessibilityLabel(title)
        }
        layoutNewMessagesButton()
        newMessagesButton.isHidden = false
        if wasHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            newMessagesButton.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                newMessagesButton.animator().alphaValue = 1
            }
        } else {
            newMessagesButton.alphaValue = 1
        }
    }

    func layoutNewMessagesButton() {
        guard isViewLoaded else { return }
        newMessagesButton.sizeToFit()
        var frame = newMessagesButton.frame
        frame.size.width += 16
        frame.origin.x = floor((view.bounds.width - frame.width) / 2)
        let bottomInset = scrollView.contentView.contentInsets.bottom
        frame.origin.y = view.isFlipped ? view.bounds.height - frame.height - 12 - bottomInset : 12 + bottomInset
        newMessagesButton.frame = frame
    }

    var newMessagesCount: Int { newItemsBelow }

    // MARK: - Scroll requests

    /// Target for this snapshot's scroll request, if it has not been honored yet.
    func scrollTarget(for snapshot: TimelineSnapshot) -> PositionTarget? {
        guard let request = snapshot.scrollRequest, lastScrollRequestGeneration != snapshot.generation else { return nil }
        let visibleHeight = visibleDocumentRect.height
        switch request {
        case .liveEdge:
            explicitLiveEdgeJump = true
            newItemsBelow = 0
            return .bottom
        case .unreadBoundary:
            guard let row = rowIndex[TimelineItemID(.unreadBoundary)] else { return nil }
            return .anchor(ScrollAnchor(itemID: items[row].id, offset: -min(80, visibleHeight / 4), fallbacks: []))
        case .post(let id):
            guard let row = rowIndex[TimelineItemID(.post(id))] else { return nil }
            if measure(row: row) { noteHeights(IndexSet(integer: row)) }
            let height = rowHeights[row]
            let offset = height >= visibleHeight ? 0 : -floor((visibleHeight - height) / 2)
            explicitLiveEdgeJump = false
            return .anchor(ScrollAnchor(itemID: items[row].id, offset: offset, fallbacks: []))
        }
    }

    /// Marks the snapshot's request as honored (exactly once per generation) and starts
    /// the flash for `.post`.
    func finishScrollRequest(for snapshot: TimelineSnapshot) {
        guard let request = snapshot.scrollRequest, lastScrollRequestGeneration != snapshot.generation else { return }
        lastScrollRequestGeneration = snapshot.generation
        counters.scrollRequestsHandled += 1
        if case .post(let id) = request, rowIndex[TimelineItemID(.post(id))] != nil {
            flash(TimelineItemID(.post(id)))
        }
    }

    // MARK: - Flash

    static let flashDuration: Duration = .milliseconds(1_500)

    func flash(_ id: TimelineItemID) {
        endFlash()
        flashingItemID = id
        if let row = rowIndex[id], let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? TimelineRowView {
            rowView.isFlashing = true
        }
        // One-shot; no repeating timer. Reduce Motion: the highlight appears and
        // disappears without any animation (it never animates).
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashDuration)
            guard !Task.isCancelled else { return }
            self?.endFlash()
        }
    }

    func endFlash() {
        flashTask?.cancel()
        flashTask = nil
        guard let id = flashingItemID else { return }
        flashingItemID = nil
        if let row = rowIndex[id], let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? TimelineRowView {
            rowView.isFlashing = false
        }
    }
}
