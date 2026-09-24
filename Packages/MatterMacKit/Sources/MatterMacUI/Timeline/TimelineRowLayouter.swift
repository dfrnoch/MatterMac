import AppKit
import MatterMacModels
import MatterMacCore

/// Produces rendered body text and row layouts for timeline items using the shared
/// bounded caches and one reusable TextKit 1 measuring stack. Main-actor only.
final class TimelineRowLayouter {
    struct Counters: Equatable {
        var renders = 0
        var renderCacheHits = 0
        var measurements = 0
        var layoutCacheHits = 0
        var estimates = 0
    }

    let caches: TimelineLayoutCaches
    let budget: ResourceBudget
    private let measurer = TextMeasurer()
    private(set) var renderer: MessageRenderer
    private(set) var metrics: TimelineRowMetrics
    var context: TimelineContextKey?
    var appearance: RenderAppearance = .light
    var counters = Counters()

    init(caches: TimelineLayoutCaches, budget: ResourceBudget) {
        self.caches = caches
        self.budget = budget
        let renderer = MessageRenderer()
        self.renderer = renderer
        self.metrics = TimelineRowMetrics(fonts: renderer.fonts)
    }

    var fontScaleKey: Int { metrics.fonts.scaleKey }

    func updateRenderer(fontScale: CGFloat, currentUsername: String?, emojiLookup: TimelineEmojiLookup?) {
        renderer = MessageRenderer(fontScale: fontScale, currentUsername: currentUsername, emojiLookup: emojiLookup)
        metrics = TimelineRowMetrics(fonts: renderer.fonts)
    }

    // MARK: - Body text

    func bodyText(for item: TimelineItem, post: PostPresentation) -> NSAttributedString {
        guard let context else {
            counters.renders += 1
            return renderer.render(post.body, budget: budget)
        }
        let key = RenderCacheKey(context: context, item: item.id, revision: item.revision, appearance: appearance,
                                 fontScaleKey: fontScaleKey)
        if let cached = caches.renderedText(for: key) {
            counters.renderCacheHits += 1
            return cached
        }
        counters.renders += 1
        let text = renderer.render(post.body, budget: budget)
        caches.storeRenderedText(text, for: key)
        return text
    }

    // MARK: - Layout

    static func layoutWidth(forBucket bucket: Int) -> CGFloat {
        CGFloat(max(bucket, 1)) * TimelineMetrics.widthBucket
    }

    private func key(for item: TimelineItem, bucket: Int) -> RowLayoutKey? {
        guard let context else { return nil }
        return RowLayoutKey(context: context, item: item.id, revision: item.revision, widthBucket: bucket,
                            fontScaleKey: fontScaleKey)
    }

    /// Cached exact layout, without measuring.
    func cachedLayout(for item: TimelineItem, bucket: Int) -> RowLayout? {
        guard let key = key(for: item, bucket: bucket) else { return nil }
        return caches.peekRowLayout(for: key)
    }

    /// Exact layout: from the cache, or rendered and measured with TextKit 1.
    func exactLayout(for item: TimelineItem, bucket: Int) -> RowLayout {
        let key = key(for: item, bucket: bucket)
        if let key, let cached = caches.rowLayout(for: key) {
            counters.layoutCacheHits += 1
            return cached
        }
        let width = Self.layoutWidth(forBucket: bucket)
        let layout: RowLayout
        switch item.content {
        case .post(let post):
            counters.measurements += 1
            let text = bodyText(for: item, post: post)
            let contentWidth = TimelineRowMetrics.contentWidth(forLayoutWidth: width)
            let bodyHeight = measurer.height(of: text, width: contentWidth)
            layout = .message(metrics.messageLayout(for: post, width: width, bodyHeight: bodyHeight, renderer: renderer))
        default:
            layout = .separator(separatorLayout(for: item, width: width))
        }
        if let key { caches.storeRowLayout(layout, for: key) }
        return layout
    }

    /// Whether an item's exact layout is cheap enough to compute without deferring
    /// (separator rows: no attributed body text).
    func isCheap(_ item: TimelineItem) -> Bool {
        if case .post = item.content { return false }
        return true
    }

    /// Estimated height for an unmeasured post row; exact for separators.
    func estimatedHeight(for item: TimelineItem, bucket: Int) -> CGFloat {
        let width = Self.layoutWidth(forBucket: bucket)
        switch item.content {
        case .post(let post):
            counters.estimates += 1
            let contentWidth = TimelineRowMetrics.contentWidth(forLayoutWidth: width)
            let bodyHeight = metrics.estimatedBodyHeight(post.body, contentWidth: contentWidth, budget: budget)
            return metrics.messageLayout(for: post, width: width, bodyHeight: bodyHeight, renderer: renderer).height
        default:
            return separatorLayout(for: item, width: width).height
        }
    }

    func separatorLayout(for item: TimelineItem, width: CGFloat) -> SeparatorRowLayout {
        switch item.content {
        case .post: SeparatorRowLayout(height: 0)
        case .dateSeparator: metrics.dateSeparatorLayout(width: width)
        case .unreadBoundary: metrics.unreadBoundaryLayout(width: width)
        case .gap(let gap): metrics.gapLayout(gap, width: width)
        case .historyStart(let name): metrics.historyStartLayout(channelName: name, width: width)
        }
    }
}
