import AppKit
public import MatterMacModels
public import MatterMacCore

/// Identifies which conversation a cached rendering or measurement belongs to. Item
/// revisions are only meaningful within one (account, timeline target), so every cache
/// key carries this context; two accounts on the same server never share entries.
nonisolated struct TimelineContextKey: Hashable, Sendable {
    let scope: AccountScope
    let target: TimelineTarget
}

/// Render-cache key (SPEC §13): item id, revision, appearance, and font scale. Width
/// independent: attributed text does not depend on the layout width.
nonisolated struct RenderCacheKey: Hashable, Sendable {
    let context: TimelineContextKey
    let item: TimelineItemID
    let revision: UInt64
    let appearance: RenderAppearance
    let fontScaleKey: Int
}

/// Row-layout key: item id, revision, width bucket (`floor(width / 8)`), font scale.
/// Grouping context and attachment layout are part of the item's revision (Core bumps
/// the revision whenever anything affecting rendering or height changes).
nonisolated struct RowLayoutKey: Hashable, Sendable {
    let context: TimelineContextKey
    let item: TimelineItemID
    let revision: UInt64
    let widthBucket: Int
    let fontScaleKey: Int
}

/// The two bounded layout caches of the timeline, each taking half of
/// `ResourceBudget.layoutCache` (count and bytes). Deterministic cost-tracked LRUs
/// (`CostLRU`), not `NSCache`: after every insert the count and cost limits hold.
///
/// One instance may be shared by several timelines (main timeline and thread panel) so
/// the layout budget is global rather than per view. Lifetime: owned by whoever creates
/// the timelines; `purge(scope:)` on sign-out, `removeAll()` on memory pressure.
public final class TimelineLayoutCaches {
    /// Approximate retained bytes per UTF-16 unit of attributed text (string storage,
    /// attribute runs, fonts/paragraph styles shared).
    static let renderBytesPerUTF16Unit = 20
    /// Approximate fixed and per-frame cost of one cached row layout.
    static let rowLayoutBaseCost = 256
    static let rowLayoutFrameCost = 40

    private(set) var render: CostLRU<RenderCacheKey, NSAttributedString>
    private(set) var rows: CostLRU<RowLayoutKey, RowLayout>

    public init(budget: ResourceBudget = .standard) {
        let count = max(1, budget.layoutCache.count / 2)
        let bytes = max(1, budget.layoutCache.bytes / 2)
        render = CostLRU(countLimit: count, costLimit: bytes)
        rows = CostLRU(countLimit: count, costLimit: bytes)
    }

    public var renderCount: Int { render.count }
    public var renderCost: Int { render.totalCost }
    public var renderCountLimit: Int { render.countLimit }
    public var renderCostLimit: Int { render.costLimit }
    public var rowLayoutCount: Int { rows.count }
    public var rowLayoutCost: Int { rows.totalCost }
    public var rowLayoutCountLimit: Int { rows.countLimit }
    public var rowLayoutCostLimit: Int { rows.costLimit }

    func renderedText(for key: RenderCacheKey) -> NSAttributedString? { render.value(for: key) }

    func storeRenderedText(_ text: NSAttributedString, for key: RenderCacheKey) {
        render.set(text, for: key, cost: Self.renderCost(of: text))
    }

    func rowLayout(for key: RowLayoutKey) -> RowLayout? { rows.value(for: key) }
    func peekRowLayout(for key: RowLayoutKey) -> RowLayout? { rows.peek(key) }

    func storeRowLayout(_ layout: RowLayout, for key: RowLayoutKey) {
        rows.set(layout, for: key, cost: layout.estimatedCost)
    }

    static func renderCost(of text: NSAttributedString) -> Int {
        max(text.length, 1) * renderBytesPerUTF16Unit
    }

    /// Drops every entry for one account (sign-out, account switch).
    public func purge(scope: AccountScope) {
        render.removeAll { key, _ in key.context.scope == scope }
        rows.removeAll { key, _ in key.context.scope == scope }
    }

    /// Drops rendered text only (e.g. renderer configuration change); row layouts that
    /// depend on it must be dropped as well, so both are cleared for the context.
    func purge(context: TimelineContextKey) {
        render.removeAll { key, _ in key.context == context }
        rows.removeAll { key, _ in key.context == context }
    }

    public func removeAll() {
        render.removeAll()
        rows.removeAll()
    }
}

/// A reusable TextKit 1 measuring stack (NSTextStorage → NSLayoutManager →
/// NSTextContainer) configured exactly like the cells' body `NSTextView`
/// (line-fragment padding 0, no insets), so measured heights match display.
final class TextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.backgroundLayoutEnabled = false
        layoutManager.allowsNonContiguousLayout = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    /// Height of `text` laid out at `width`, rounded up to whole points.
    func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        container.size = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        // Release glyph storage; the stack is reused for the next row.
        storage.setAttributedString(NSAttributedString())
        return ceil(used.maxY)
    }
}

/// Text drawn with NSStringDrawing (labels that wrap); measured with the same options.
enum DrawnText {
    static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let rect = text.boundingRect(with: NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude),
                                     options: options)
        return ceil(rect.height)
    }

    static func width(of text: NSAttributedString) -> CGFloat {
        ceil(text.size().width)
    }
}
