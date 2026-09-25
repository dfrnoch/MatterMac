public import AppKit
public import MatterMacModels
public import MatterMacCore

/// The reusable AppKit message timeline: an `NSScrollView` around a view-based
/// `NSTableView` (plain style, one column, no header, fixed row heights from a bounded
/// row-layout cache).
///
/// Data flow: Core publishes immutable `TimelineSnapshot`s; `apply(_:)` rejects stale
/// generations, diffs by `TimelineItemID` + revision, and applies minimal row
/// operations inside `beginUpdates`/`endUpdates`. Only rows within ±1 screen of the
/// viewport are rendered and measured (TextKit 1); other rows use cheap estimates and
/// are measured as they approach. Every height change preserves a (post id, pixel
/// offset) scroll anchor, or keeps the view pinned to the live edge when the user was
/// there.
///
/// Idle behavior: no timers. Work happens only on snapshot application, scrolling,
/// resizing, and explicit user actions (plus one-shot coalesced visibility reports and
/// a one-shot highlight after jumping to a post).
public final class TimelineViewController: NSViewController {
    // MARK: Public configuration

    public weak var delegate: (any TimelineViewControllerDelegate)?
    public let budget: ResourceBudget
    /// Shared bounded layout caches (render + row layout). Pass one instance to several
    /// timelines to keep the layout budget global.
    public let layoutCaches: TimelineLayoutCaches
    public private(set) var snapshot: TimelineSnapshot?

    /// Text scale applied to the system body font (session-only preference).
    public var fontScale: CGFloat = 1 {
        didSet { if TimelineFonts.scaleKey(for: oldValue) != TimelineFonts.scaleKey(for: fontScale) { rendererDidChange(fontScaleChanged: true) } }
    }

    /// 24-hour (`true`) or 12-hour message times from the account's server
    /// preference; `nil` follows the Mac. Re-renders visible rows when it changes.
    public var uses24HourClock: Bool? {
        didSet {
            guard oldValue != uses24HourClock || TimelineStrings.clockOverride != uses24HourClock else { return }
            TimelineStrings.clockOverride = uses24HourClock
            rendererDidChange(fontScaleChanged: false)
        }
    }

    /// With a window theme the timeline draws no background of its own, so the themed
    /// backdrop behind the pane shows through (the theme keeps text contrast; see
    /// `ThemePalette`). Otherwise it draws the standard text background.
    public var drawsThemedBackground = false {
        didSet { if oldValue != drawsThemedBackground { applyBackground() } }
    }

    /// The signed-in user's username for mention highlighting.
    public var currentUsername: String? {
        didSet { if oldValue != currentUsername { rendererDidChange(fontScaleChanged: false) } }
    }

    /// Emoji short-name lookup. Setting it re-renders visible rows.
    public var emojiLookup: TimelineEmojiLookup? {
        didSet { rendererDidChange(fontScaleChanged: false) }
    }

    // MARK: Views

    let scrollView = NSScrollView()
    let tableView = TimelineTableView()
    let newMessagesButton = JumpToLatestPill(frame: .zero)
    let contextMenu = NSMenu()
    private(set) lazy var adapter = TimelineTableAdapter(controller: self)
    /// Floating actions for the hovered/selected message (see `+Hover`).
    let hoverBar = HoverActionBar(frame: .zero)
    /// Pointer location (window coordinates) while it is inside the timeline.
    var hoverPointerLocation: NSPoint?
    var hoverHighlightedID: TimelineItemID?
    var hoverTimestampID: TimelineItemID?

    // MARK: Row model (parallel arrays, bounded by the snapshot size)

    var items: [TimelineItem] = []
    var rowIndex: [TimelineItemID: Int] = [:]
    var rowHeights: [CGFloat] = []
    var rowTokens: [LayoutToken?] = []

    struct LayoutToken: Hashable {
        var bucket: Int
        var scaleKey: Int
    }

    var currentToken = LayoutToken(bucket: 80, scaleKey: 100)
    let layouter: TimelineRowLayouter
    let diagnostics: DiagnosticRing?

    // MARK: Scroll and paging state

    var isPerformingUpdate = false
    var pendingSnapshot: TimelineSnapshot?
    var lastAnchor: ScrollAnchor?
    var isPinnedToLiveEdge = true
    var explicitLiveEdgeJump = false
    var newItemsBelow = 0
    var lastScrollRequestGeneration: UInt64?
    var lastOlderTrigger: GapTriggerKey?
    var lastNewerTrigger: GapTriggerKey?
    var lastClipSize: NSSize = .zero
    var pendingHeightFixups: Set<TimelineItemID> = []
    var heightFixupScheduled = false
    var flashingItemID: TimelineItemID?
    var flashTask: Task<Void, Never>?

    // Visibility reporting (≤ 4 Hz, one pending report at most).
    static let visibilityReportInterval: TimeInterval = 0.25
    var visibilityReportScheduled = false
    var lastVisibilityReportUptime: TimeInterval = -1
    var lastVisibilityReport: VisibilityReport?
    /// A user scroll happened since the last visibility report (ends a manual-unread hold).
    var userScrolledSinceReport = false
    /// Tests set this to bypass the window occlusion check.
    var visibilityOverrideForTesting: Bool?
    weak var observedWindow: NSWindow?

    // Image demand across displayed cells: request → number of cells waiting. Bounded by
    // displayed cells × (1 avatar + maximumDisplayedFiles).
    var imageDemand: [TimelineImageRequest: Int] = [:]

    var counters = DebugCounters()

    struct DebugCounters: Equatable {
        var resets = 0
        var boundedReplacements = 0
        var incrementalUpdates = 0
        var rejectedSnapshots = 0
        var olderRequests = 0
        var newerRequests = 0
        var visibilityReports = 0
        var scrollRequestsHandled = 0
    }

    // MARK: Lifecycle

    public init(budget: ResourceBudget = .standard, layoutCaches: TimelineLayoutCaches? = nil,
                diagnostics: DiagnosticRing? = nil) {
        self.budget = budget
        let caches = layoutCaches ?? TimelineLayoutCaches(budget: budget)
        self.layoutCaches = caches
        self.layouter = TimelineRowLayouter(caches: caches, budget: budget)
        self.diagnostics = diagnostics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let container = TimelineContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        container.controller = self

        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MatterMacTimelineColumn"))
        column.resizingMask = .autoresizingMask
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsTypeSelect = false
        tableView.gridStyleMask = []
        tableView.floatsGroupRows = false
        tableView.focusRingType = .none
        tableView.dataSource = adapter
        tableView.delegate = adapter
        tableView.host = self
        contextMenu.delegate = adapter
        tableView.menu = contextMenu
        tableView.setAccessibilityLabel(String(localized: "Messages"))
        scrollView.documentView = tableView
        container.addSubview(scrollView)
        applyBackground()
        tableView.fitColumnToWidth()
        installHoverBar(in: container)

        newMessagesButton.button.target = self
        newMessagesButton.button.action = #selector(newMessagesButtonPressed(_:))
        newMessagesButton.isHidden = true
        container.addSubview(newMessagesButton)

        view = container
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        layouter.appearance = RenderAppearance(container.effectiveAppearance)
        currentToken = LayoutToken(bucket: widthBucket(), scaleKey: layouter.fontScaleKey)
        lastClipSize = scrollView.contentView.bounds.size
    }

    private func applyBackground() {
        let color: NSColor = drawsThemedBackground ? .clear : .textBackgroundColor
        scrollView.drawsBackground = !drawsThemedBackground
        scrollView.backgroundColor = color
        tableView.backgroundColor = color
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutNewMessagesButton()
        if !isPerformingUpdate, snapshot != nil, widthBucket() != currentToken.bucket {
            performUpdate { handleViewportResize() }
        }
    }

    // MARK: - Applying snapshots

    /// Applies a snapshot. Older generations for the same (scope, target) are ignored; a
    /// different scope or target resets the timeline. Safe to call from delegate
    /// callbacks (queued, latest wins).
    public func apply(_ snapshot: TimelineSnapshot) {
        loadViewIfNeeded()
        if isPerformingUpdate {
            if let pending = pendingSnapshot, Self.sameTimeline(pending, snapshot),
               snapshot.generation <= pending.generation {
                counters.rejectedSnapshots += 1
                return
            }
            pendingSnapshot = snapshot
            return
        }
        performUpdate { applyNow(snapshot) }
    }

    static func sameTimeline(_ lhs: TimelineSnapshot, _ rhs: TimelineSnapshot) -> Bool {
        lhs.scope == rhs.scope && lhs.target == rhs.target
    }

    /// Runs `body` with scroll notifications suppressed, then applies any snapshot
    /// queued meanwhile.
    func performUpdate(_ body: () -> Void) {
        if isPerformingUpdate {
            body()
            return
        }
        isPerformingUpdate = true
        body()
        isPerformingUpdate = false
        if let pending = pendingSnapshot {
            pendingSnapshot = nil
            apply(pending)
        }
    }

    private func applyNow(_ snapshot: TimelineSnapshot) {
        if let current = self.snapshot, Self.sameTimeline(current, snapshot) {
            guard snapshot.generation > current.generation else {
                counters.rejectedSnapshots += 1
                diagnostics?.record(.render, .debug, "timeline stale snapshot ignored", code: 0)
                return
            }
            applyIncremental(snapshot)
        } else {
            reset(with: snapshot)
        }
    }

    private func deduplicated(_ items: [TimelineItem]) -> [TimelineItem] {
        var seen = Set<TimelineItemID>()
        seen.reserveCapacity(items.count)
        var result: [TimelineItem] = []
        result.reserveCapacity(items.count)
        var duplicates = 0
        for item in items {
            if seen.insert(item.id).inserted { result.append(item) } else { duplicates += 1 }
        }
        if duplicates > 0 {
            diagnostics?.record(.render, .warning, "timeline snapshot contained duplicate item ids", code: Int64(duplicates))
        }
        return result
    }

    private func reset(with snapshot: TimelineSnapshot) {
        counters.resets += 1
        let context = TimelineContextKey(scope: snapshot.scope, target: snapshot.target)
        if let previous = self.snapshot, previous.scope != snapshot.scope {
            // Another account: nothing rendered for the old one may be reused.
            layoutCaches.purge(scope: previous.scope)
        }
        self.snapshot = snapshot
        layouter.context = context
        currentToken = LayoutToken(bucket: widthBucket(), scaleKey: layouter.fontScaleKey)
        let newItems = deduplicated(snapshot.items)
        rebuildRows(newItems, previous: [], previousHeights: [], previousTokens: [], previousIndex: [:])
        newItemsBelow = 0
        explicitLiveEdgeJump = false
        lastOlderTrigger = nil
        lastNewerTrigger = nil
        lastScrollRequestGeneration = nil
        lastAnchor = nil
        lastVisibilityReport = nil
        endFlash()
        hoverBar.reset()
        hoverHighlightedID = nil
        hoverTimestampID = nil
        pendingHeightFixups.removeAll()
        tableView.deselectAll(nil)
        tableView.reloadData()
        tableView.tile()

        let requested = scrollTarget(for: snapshot)
        settle(requested ?? .bottom)
        finishScrollRequest(for: snapshot)
        afterScrollPositionSettled()
    }

    private func applyIncremental(_ snapshot: TimelineSnapshot) {
        let wasPinned = isPinnedToLiveEdge || explicitLiveEdgeJump
        let anchor = captureAnchor()
        let lastVisibleID = lastVisibleItemID()
        let newItems = deduplicated(snapshot.items)
        let diff = TimelineDiff.compute(old: items, new: newItems)
        self.snapshot = snapshot

        if !diff.isEmpty {
            counters.incrementalUpdates += 1
            let selectedIDs = tableView.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].id : nil }
            let previousItems = items
            let previousHeights = rowHeights
            let previousTokens = rowTokens
            let previousIndex = rowIndex
            rebuildRows(newItems, previous: previousItems, previousHeights: previousHeights,
                        previousTokens: previousTokens, previousIndex: previousIndex)

            if diff.isLarge {
                counters.boundedReplacements += 1
                tableView.reloadData()
                let restored = IndexSet(selectedIDs.compactMap { rowIndex[$0] })
                tableView.selectRowIndexes(restored, byExtendingSelection: false)
            } else {
                withoutAnimation {
                    tableView.beginUpdates()
                    if !diff.removed.isEmpty { tableView.removeRows(at: diff.removed, withAnimation: []) }
                    for move in diff.moves { tableView.moveRow(at: move.from, to: move.to) }
                    if !diff.inserted.isEmpty { tableView.insertRows(at: diff.inserted, withAnimation: []) }
                    tableView.endUpdates()
                    if !diff.changed.isEmpty {
                        tableView.noteHeightOfRows(withIndexesChanged: diff.changed)
                        tableView.reloadData(forRowIndexes: diff.changed, columnIndexes: IndexSet(integer: 0))
                    }
                }
            }
            tableView.tile()

            if !wasPinned {
                let boundary = lastVisibleID.flatMap { rowIndex[$0] } ?? Int.max
                var added = 0
                for row in diff.inserted where row > boundary {
                    if let post = items[row].post, !post.author.isCurrentUser { added += 1 }
                }
                newItemsBelow += added
            }
        }

        let target: PositionTarget = scrollTarget(for: snapshot) ?? (wasPinned ? .bottom : .anchor(anchor))
        settle(target)
        finishScrollRequest(for: snapshot)
        afterScrollPositionSettled()
    }

    /// Rebuilds the parallel row arrays, reusing heights of unchanged rows and cached
    /// exact layouts; everything else gets an estimate (separators are exact).
    private func rebuildRows(_ newItems: [TimelineItem], previous: [TimelineItem], previousHeights: [CGFloat],
                             previousTokens: [LayoutToken?], previousIndex: [TimelineItemID: Int]) {
        var heights: [CGFloat] = []
        var tokens: [LayoutToken?] = []
        var index: [TimelineItemID: Int] = [:]
        heights.reserveCapacity(newItems.count)
        tokens.reserveCapacity(newItems.count)
        index.reserveCapacity(newItems.count)
        for (row, item) in newItems.enumerated() {
            index[item.id] = row
            if let old = previousIndex[item.id], previous[old].revision == item.revision, old < previousHeights.count {
                heights.append(previousHeights[old])
                tokens.append(previousTokens[old])
            } else if let cached = layouter.cachedLayout(for: item, bucket: currentToken.bucket) {
                heights.append(cached.height)
                tokens.append(currentToken)
            } else if layouter.isCheap(item) {
                heights.append(layouter.exactLayout(for: item, bucket: currentToken.bucket).height)
                tokens.append(currentToken)
            } else {
                heights.append(layouter.estimatedHeight(for: item, bucket: currentToken.bucket))
                tokens.append(nil)
            }
        }
        items = newItems
        rowHeights = heights
        rowTokens = tokens
        rowIndex = index
    }

    func withoutAnimation(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        body()
        NSAnimationContext.endGrouping()
    }

    // MARK: - Renderer configuration

    private func rendererDidChange(fontScaleChanged: Bool) {
        layouter.updateRenderer(fontScale: fontScale, currentUsername: currentUsername, emojiLookup: emojiLookup)
        if let context = layouter.context, !fontScaleChanged {
            // Same scale but different mention/emoji output: cached text is invalid.
            layoutCaches.purge(context: context)
        }
        guard isViewLoaded, snapshot != nil else {
            currentToken.scaleKey = layouter.fontScaleKey
            return
        }
        performUpdate {
            let target: PositionTarget = isPinnedToLiveEdge ? .bottom : .anchor(lastAnchor ?? captureAnchor())
            currentToken = LayoutToken(bucket: widthBucket(), scaleKey: layouter.fontScaleKey)
            for row in items.indices {
                rowTokens[row] = nil
                if fontScaleChanged || !layouter.isCheap(items[row]) {
                    rowHeights[row] = layouter.estimatedHeight(for: items[row], bucket: currentToken.bucket)
                }
            }
            withoutAnimation {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
            }
            reloadVisibleRows()
            settle(target)
            afterScrollPositionSettled()
        }
    }

    func reloadVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integer: 0))
    }

    func appearanceDidChange() {
        guard isViewLoaded else { return }
        let appearance = RenderAppearance(view.effectiveAppearance)
        guard appearance != layouter.appearance else { return }
        layouter.appearance = appearance
        guard snapshot != nil else { return }
        performUpdate {
            let anchor = captureAnchor()
            reloadVisibleRows()
            if isPinnedToLiveEdge { scrollToBottomNow() } else if let anchor { restore(anchor) }
            afterScrollPositionSettled()
        }
    }

    func backingPropertiesDidChange() {
        guard snapshot != nil else { return }
        performUpdate {
            position(isPinnedToLiveEdge ? .bottom : .anchor(lastAnchor))
            tableView.enumerateAvailableRowViews { rowView, _ in
                (rowView.view(atColumn: 0) as? MessageCellView)?.refreshImages()
            }
            afterScrollPositionSettled()
        }
    }

    func liveResizeDidEnd() {
        guard snapshot != nil else { return }
        performUpdate {
            settle(isPinnedToLiveEdge ? .bottom : .anchor(lastAnchor ?? captureAnchor()))
            afterScrollPositionSettled()
        }
    }

    // MARK: - Public actions

    /// Scrolls to the newest retained message and follows new messages. Requests newer
    /// pages when the retained window is not at the live edge.
    public func scrollToLiveEdge() {
        guard snapshot != nil else { return }
        performUpdate {
            newItemsBelow = 0
            explicitLiveEdgeJump = true
            settle(.bottom)
            afterScrollPositionSettled()
            if snapshot?.isAtLiveEdge == false {
                counters.newerRequests += 1
                delegate?.timelineRequestsNewer()
            }
        }
    }

    /// Whether the viewport shows the channel's newest known post.
    public var isShowingLiveEdge: Bool {
        guard let snapshot else { return false }
        return snapshot.isAtLiveEdge && distanceFromBottom() <= TimelineMetrics.liveEdgeTolerance
    }

    /// Delivers a newly available image to displayed rows that asked for it.
    public func imageDidBecomeAvailable(_ request: TimelineImageRequest) {
        guard isViewLoaded, imageDemand[request] != nil else { return }
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? MessageCellView)?.imageDidBecomeAvailable(request)
        }
    }

    public func reloadDisplayedImages() {
        guard isViewLoaded else { return }
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? MessageCellView)?.refreshImages()
        }
    }

    public func clearDisplayedImages() {
        guard isViewLoaded else { return }
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? MessageCellView)?.releaseImageDemand()
        }
    }

    /// Removes all content (sign-out or session teardown) and drops this account's
    /// cached layouts. The next snapshot starts fresh.
    public func removeAllContent() {
        guard isViewLoaded else { return }
        performUpdate {
            if let scope = snapshot?.scope { layoutCaches.purge(scope: scope) }
            snapshot = nil
            layouter.context = nil
            items = []
            rowHeights = []
            rowTokens = []
            rowIndex = [:]
            newItemsBelow = 0
            lastAnchor = nil
            endFlash()
            hoverBar.reset()
            hoverHighlightedID = nil
            hoverTimestampID = nil
            tableView.reloadData()
            updateNewMessagesButton()
        }
        for (request, _) in imageDemand { delegate?.timelineNoLongerNeedsImage(request) }
        imageDemand.removeAll()
    }

    @objc func newMessagesButtonPressed(_ sender: Any?) {
        scrollToLiveEdge()
    }
}

/// Root view: forwards appearance, backing-scale, window, and live-resize changes.
final class TimelineContainerView: NSView {
    weak var controller: TimelineViewController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp,
                                                              .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        controller?.hoverMouseMoved(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        controller?.hoverMouseMoved(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.hoverMouseExited()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.appearanceDidChange()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.backingPropertiesDidChange()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller?.liveResizeDidEnd()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.windowDidChange(window)
    }
}
