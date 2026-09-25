public import AppKit

// Drawing-only TextKit 1 customizations used by message bodies. None of them changes
// layout: every width, padding and cell size is fixed when the attributed string is
// built, so `TextMeasurer` (which uses the same classes) produces exactly the height
// the body text view draws.

extension NSAttributedString.Key {
    /// Marks a mention of the signed-in user or @channel/@here/@all (row highlight).
    nonisolated public static let matterMacSelfMention = NSAttributedString.Key("MatterMacSelfMention")
    /// Marks inline code, whose background is drawn as a rounded rectangle.
    nonisolated public static let matterMacInlineCode = NSAttributedString.Key("MatterMacInlineCode")

}

/// A text block with a custom, rounded background. Padding, border and margin widths
/// are set with the standard `setWidth` API (they affect layout); only the drawing is
/// replaced.
nonisolated final class TimelineTextBlock: NSTextBlock {
    enum Decoration: Equatable {
        /// Rounded fill with a hairline border (fenced code).
        case code
        /// A rounded bar in the leading padding (block quote).
        case quote
        /// Rounded hairline outline plus a leading accent bar (message attachment).
        case attachment(NSColor)
        /// A horizontal hairline through the vertical middle (thematic break).
        case rule
        /// Nothing drawn: used for layout-only grouping (attachment field rows).
        case none
    }

    static let cornerRadius: CGFloat = 6
    static let barWidth: CGFloat = 3
    static let attachmentBarWidth: CGFloat = 4

    var decoration: Decoration = .none

    convenience init(decoration: Decoration) {
        self.init()
        self.decoration = decoration
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        (copy as? TimelineTextBlock)?.decoration = decoration
        return copy
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        // `frameRect` is the block's bounds rectangle: padding and border, no margins.
        let rect = frameRect
        switch decoration {
        case .code:
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius,
                                    yRadius: Self.cornerRadius)
            TimelinePalette.codeBackground.setFill()
            path.fill()
            TimelinePalette.codeBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .quote:
            let bar = NSRect(x: rect.minX, y: rect.minY, width: Self.barWidth, height: rect.height)
            TimelinePalette.quoteBar.setFill()
            NSBezierPath(roundedRect: bar, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
        case .attachment(let accent):
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius,
                                       yRadius: Self.cornerRadius)
            TimelinePalette.attachmentBackground.setFill()
            outline.fill()
            TimelinePalette.attachmentBorder.setStroke()
            outline.lineWidth = 1
            outline.stroke()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            accent.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: Self.attachmentBarWidth, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .rule:
            TimelinePalette.rule.setFill()
            NSRect(x: rect.minX, y: floor(rect.midY), width: rect.width, height: 1).fill()
        case .none:
            break
        }
    }
}

/// Layout manager for message bodies and their measurement. Layout is inherited
/// unchanged; only text backgrounds of inline code and highlighted mentions are drawn
/// as rounded rectangles (slightly wider than the glyphs, like a chip).
nonisolated final class TimelineLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length, rectCount > 0,
              let background = storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor,
              background == color,
              storage.attribute(.matterMacInlineCode, at: charRange.location, effectiveRange: nil) != nil
                || storage.attribute(.matterMacSelfMention, at: charRange.location, effectiveRange: nil) != nil
        else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        color.setFill()
        for index in 0..<rectCount {
            let rect = rectArray[index].insetBy(dx: -2, dy: 0)
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }
}

/// Localized rendering strings (kept apart from `TimelineStrings`).
enum RenderingStrings {
    static let interactiveUnsupported = String(localized: "Interactive buttons in this message are not supported in MatterMac.")
    static let attachmentImage = String(localized: "View image")

    static func tableRowsNotShown(_ count: Int) -> String {
        count == 1 ? String(localized: "1 more row not shown. Use Copy Text for the full table.")
                   : String(localized: "\(count) more rows not shown. Use Copy Text for the full table.")
    }

    static func tableColumnsNotShown(_ count: Int) -> String {
        count == 1 ? String(localized: "1 more column not shown.")
                   : String(localized: "\(count) more columns not shown.")
    }

}
