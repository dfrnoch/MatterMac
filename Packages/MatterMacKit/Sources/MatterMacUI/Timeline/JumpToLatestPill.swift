import AppKit

/// The floating "Jump to latest" / "N new messages" capsule at the bottom of the
/// timeline. One instance per timeline, overlaid above the scroll view.
///
/// Appearance: Liquid Glass (`NSGlassEffectView`) on macOS 26 and later, otherwise a
/// capsule `NSVisualEffectView` in the menu material. New messages lead with an
/// accent-colored arrow badge. The content is an ordinary borderless `NSButton`, so it reaches
/// VoiceOver and Full Keyboard Access.
final class JumpToLatestPill: NSView {
    static let height: CGFloat = 30
    static let horizontalPadding: CGFloat = 13

    let button = NSButton(title: "", target: nil, action: nil)
    private let background: NSView
    private let content = NSView()

    /// The visible (and accessibility) title.
    var title: String = "" {
        didSet {
            guard oldValue != title else { return }
            updateContent()
            button.setAccessibilityLabel(title)
        }
    }

    /// Leads with the accent badge, for new messages below.
    var isProminent = false {
        didSet { if oldValue != isProminent { updateContent() } }
    }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.height / 2
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.height / 2
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            background = effect
        }
        super.init(frame: frameRect)
        button.isBordered = false
        button.imagePosition = .noImage
        button.focusRingType = .default
        content.addSubview(button)
        if #available(macOS 26, *), let glass = background as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        addSubview(background)
        wantsLayer = true
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
            return shadow
        }()
        updateContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width and height that fit the current title.
    var fittingPillSize: NSSize {
        let width = ceil(button.intrinsicContentSize.width) + Self.horizontalPadding * 2
        return NSSize(width: max(width, Self.height * 2), height: Self.height)
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        content.frame = background.bounds
        let size = button.intrinsicContentSize
        button.frame = NSRect(x: floor((bounds.width - size.width) / 2), y: floor((bounds.height - size.height) / 2),
                              width: ceil(size.width), height: ceil(size.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateContent()
    }

    private func updateContent() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        // New messages: a white arrow on an accent disc; otherwise a plain arrow. The
        // surface itself is never tinted, so the title keeps label contrast with any
        // accent color (including Graphite) in both appearances.
        let symbolConfiguration: NSImage.SymbolConfiguration = isProminent
            ? .init(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [.white, .controlAccentColor]))
            : .init(pointSize: 12, weight: .bold).applying(.init(paletteColors: [.labelColor]))
        let symbol = NSImage(systemSymbolName: isProminent ? "arrow.down.circle.fill" : "arrow.down",
                             accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfiguration)
        // The symbol is an attachment so it keeps a fixed gap from the title.
        let label = NSMutableAttributedString()
        if let symbol {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = NSRect(x: 0, y: floor((font.capHeight - symbol.size.height) / 2),
                                       width: symbol.size.width, height: symbol.size.height)
            label.append(NSAttributedString(attachment: attachment))
            label.append(NSAttributedString(string: "\u{2002}", attributes: [.font: font]))
        }
        label.append(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        button.attributedTitle = label
        if let effect = background as? NSVisualEffectView {
            effect.effectiveAppearance.performAsCurrentDrawingAppearance {
                effect.layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }
        needsLayout = true
    }
}
