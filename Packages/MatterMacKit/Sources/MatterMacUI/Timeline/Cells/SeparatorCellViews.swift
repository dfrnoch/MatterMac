import AppKit
import MatterMacModels
import MatterMacCore

/// Row view that draws the transient "flash" highlight for a scrolled-to post.
final class TimelineRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MatterMacTimelineRow")

    var isFlashing = false {
        didSet { if oldValue != isFlashing { needsDisplay = true } }
    }

    /// The pointer is over this message (subtle background, like the official client).
    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isFlashing {
            TimelinePalette.flashHighlight.setFill()
            bounds.fill()
        } else if isHovered, !isSelected {
            TimelinePalette.hoverHighlight.setFill()
            bounds.fill()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isFlashing = false
        isHovered = false
    }
}

/// Centered date with hairlines on both sides.
final class DateSeparatorCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MatterMacDateSeparator")
    private let label = TimelineLabel(frame: .zero)
    private var textWidth: CGFloat = 0
    private var layoutFrame = CGRect.zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(date: Date, layout: SeparatorRowLayout, fonts: TimelineFonts) {
        let text = NSAttributedString(string: TimelineStrings.date(date), attributes: [
            .font: fonts.metaBold, .foregroundColor: NSColor.labelColor,
        ])
        label.attributedText = text
        textWidth = DrawnText.width(of: text)
        layoutFrame = layout.label
        setAccessibilityLabel(text.string)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = min(textWidth, layoutFrame.width)
        label.frame = CGRect(x: layoutFrame.midX - width / 2, y: layoutFrame.minY, width: width,
                             height: layoutFrame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = floor(layoutFrame.midY) + 0.5
        NSColor.separatorColor.setStroke()
        let gap: CGFloat = 12
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: layoutFrame.minX, y: y))
        path.line(to: NSPoint(x: max(layoutFrame.minX, label.frame.minX - gap), y: y))
        path.move(to: NSPoint(x: min(layoutFrame.maxX, label.frame.maxX + gap), y: y))
        path.line(to: NSPoint(x: layoutFrame.maxX, y: y))
        path.stroke()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.attributedText = NSAttributedString()
        setAccessibilityLabel(nil)
    }
}

/// "New messages" line marking the unread boundary.
final class UnreadBoundaryCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MatterMacUnreadBoundary")
    private let label = TimelineLabel(frame: .zero)
    private var textWidth: CGFloat = 0
    private var layoutFrame = CGRect.zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(count: Int, layout: SeparatorRowLayout, fonts: TimelineFonts) {
        let text = NSAttributedString(string: TimelineStrings.newMessagesSeparator, attributes: [
            .font: fonts.metaBold, .foregroundColor: NSColor.systemRed,
        ])
        label.attributedText = text
        textWidth = DrawnText.width(of: text)
        layoutFrame = layout.label
        setAccessibilityLabel(TimelineStrings.unreadBoundaryAccessibility(count))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = min(textWidth, layoutFrame.width)
        label.frame = CGRect(x: layoutFrame.maxX - width, y: layoutFrame.minY, width: width, height: layoutFrame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = floor(layoutFrame.midY) + 0.5
        NSColor.systemRed.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: layoutFrame.minX, y: y))
        path.line(to: NSPoint(x: max(layoutFrame.minX, label.frame.minX - 8), y: y))
        path.stroke()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.attributedText = NSAttributedString()
        setAccessibilityLabel(nil)
    }
}

/// Older/newer history gap: load button, loading spinner with text, or failure with
/// explanation and Retry. Never a bare spinner.
final class GapCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MatterMacGap")
    private let label = TimelineLabel(frame: .zero)
    private let button = TimelineTextButton(style: .bordered)
    private let spinner = NSProgressIndicator()
    private var rowLayout = SeparatorRowLayout(height: 0)
    private var labelTextWidth: CGFloat = 0
    weak var host: (any TimelineCellHost)?
    private(set) var gap: GapPresentation?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        label.isSingleLine = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(label)
        addSubview(button)
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(gap: GapPresentation, layout: SeparatorRowLayout, metrics: TimelineRowMetrics,
                   host: any TimelineCellHost) {
        self.gap = gap
        self.host = host
        rowLayout = layout
        let text = metrics.gapText(gap)
        label.attributedText = text ?? NSAttributedString()
        label.isHidden = text == nil
        labelTextWidth = text.map { DrawnText.width(of: $0) } ?? 0
        switch gap.state {
        case .idle:
            button.isHidden = false
            button.configure(title: gap.direction == .older ? TimelineStrings.loadOlder : TimelineStrings.loadNewer,
                             font: metrics.fonts.meta)
            button.onPress = { [weak self] in
                guard let self, let gap = self.gap else { return }
                if gap.direction == .older { self.host?.requestOlderFromGapButton() }
                else { self.host?.requestNewerFromGapButton() }
            }
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        case .loading:
            button.isHidden = true
            button.onPress = nil
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .failed:
            button.isHidden = false
            button.configure(title: TimelineStrings.retry, font: metrics.fonts.meta)
            button.onPress = { [weak self] in
                guard let self, let gap = self.gap else { return }
                self.host?.perform(.retryGap(gap.direction))
            }
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        setAccessibilityElement(false)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let frame = rowLayout.button {
            let width = min(frame.width, button.fittingWidth + 16)
            button.frame = CGRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height)
        }
        if rowLayout.spinner != nil {
            // Spinner + text centered as a group.
            let textWidth = min(labelTextWidth, rowLayout.label.width - TimelineRowMetrics.spinnerSize - 6)
            let groupWidth = TimelineRowMetrics.spinnerSize + 6 + textWidth
            let x = rowLayout.label.midX - groupWidth / 2
            spinner.frame = CGRect(x: x, y: rowLayout.label.minY, width: TimelineRowMetrics.spinnerSize,
                                   height: TimelineRowMetrics.spinnerSize)
            label.frame = CGRect(x: x + TimelineRowMetrics.spinnerSize + 6, y: rowLayout.label.minY,
                                 width: max(0, textWidth), height: rowLayout.label.height)
        } else {
            label.frame = rowLayout.label
        }
    }

    func didEndDisplay() { spinner.stopAnimation(nil) }

    override func prepareForReuse() {
        super.prepareForReuse()
        gap = nil
        button.reset()
        spinner.stopAnimation(nil)
        label.attributedText = NSAttributedString()
    }
}

/// "This is the beginning of …" at the start of retained history.
final class HistoryStartCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MatterMacHistoryStart")
    private let label = TimelineLabel(frame: .zero)
    private var labelFrame = CGRect.zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        label.isSingleLine = false
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(channelName: String, layout: SeparatorRowLayout, metrics: TimelineRowMetrics) {
        let text = metrics.historyStartText(channelName)
        label.attributedText = text
        labelFrame = layout.label
        setAccessibilityLabel(text.string)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = labelFrame
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.attributedText = NSAttributedString()
        setAccessibilityLabel(nil)
    }
}
