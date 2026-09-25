import AppKit
import MatterMacModels
import MatterMacCore

/// The floating message action bar shown at the top-right of the hovered (or, without
/// a hovered row, the selected) message: three quick reactions, Add Reaction, Reply and
/// More (the context-menu items). One instance per timeline, overlaid above the scroll
/// view, so it never changes row heights or allocates per row.
///
/// Appearance: Liquid Glass (`NSGlassEffectView`) on macOS 26 and later, otherwise a
/// rounded `NSVisualEffectView` in the menu material. Buttons are `NSButton`s with a
/// capsule hover highlight (`CapsuleHoverButton`):
/// they reach VoiceOver and Full Keyboard Access; the same actions are also exposed as
/// accessibility custom actions on the row itself.
final class HoverActionBar: NSView {
    enum Button: Hashable {
        case quickReaction(String)
        case addReaction
        case reply
        case more
    }

    static let height: CGFloat = 30
    static let buttonWidth: CGFloat = 30
    static let inset: CGFloat = 3
    static let spacing: CGFloat = 1

    /// Invoked with the chosen action (quick reaction, Add Reaction, Reply).
    var onAction: ((TimelineAction) -> Void)?
    /// Invoked when More is pressed, with the button to anchor the menu to.
    var onMore: ((NSButton) -> Void)?

    private(set) var postID: PostID?
    private(set) var itemID: TimelineItemID?
    private var replyRoot: PostID?
    private(set) var buttons: [(kind: Button, view: NSButton)] = []
    private let background: NSView
    private let content = NSView()

    override var isFlipped: Bool { true }

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
            effect.layer?.cornerRadius = 8
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            background = effect
        }
        super.init(frame: frameRect)
        if #available(macOS 26, *), let glass = background as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        addSubview(background)
        wantsLayer = true
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return shadow
        }()
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(TimelineStrings.messageActions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rebuilds the buttons for `post`. Returns `false` (and hides) when the post offers
    /// no hover actions (pending, deleted, system).
    @discardableResult
    func configure(item: TimelineItemID, post: PostPresentation,
                   quickReactions: [String] = TimelinePostActions.quickReactions,
                   emojiText: (String) -> String) -> Bool {
        guard let id = post.postID, post.sendState == nil else { return false }
        switch post.body {
        case .deleted, .system: return false
        default: break
        }
        var kinds: [Button] = []
        if post.actions.canReact {
            kinds += quickReactions.map { Button.quickReaction($0) }
            kinds.append(.addReaction)
        }
        if post.actions.canReply { kinds.append(.reply) }
        kinds.append(.more)
        if buttons.map(\.kind) != kinds {
            rebuild(kinds, emojiText: emojiText)
        }
        postID = id
        itemID = item
        replyRoot = post.rootID ?? id
        for (kind, button) in buttons {
            if case .quickReaction(let name) = kind {
                let mine = post.reactions.contains { $0.emojiName == name && $0.includesCurrentUser }
                button.setAccessibilityValue(mine ? TimelineStrings.reactedByYou : nil)
            }
        }
        needsLayout = true
        return true
    }

    private func rebuild(_ kinds: [Button], emojiText: (String) -> String) {
        for (_, button) in buttons { button.removeFromSuperview() }
        buttons = kinds.map { kind in
            let button = CapsuleHoverButton(frame: .zero)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(buttonPressed(_:))
            button.focusRingType = .default
            switch kind {
            case .quickReaction(let name):
                let glyph = emojiText(name)
                button.imagePosition = .noImage
                button.attributedTitle = NSAttributedString(string: glyph, attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                ])
                button.toolTip = TimelineStrings.quickReaction(name)
                button.setAccessibilityLabel(TimelineStrings.quickReaction(name))
            case .addReaction:
                button.image = Self.symbol("face.smiling", TimelineStrings.actionAddReaction)
                button.toolTip = TimelineStrings.actionAddReaction
                button.setAccessibilityLabel(TimelineStrings.actionAddReaction)
            case .reply:
                button.image = Self.symbol("arrowshape.turn.up.left", TimelineStrings.actionReply)
                button.toolTip = TimelineStrings.actionReply
                button.setAccessibilityLabel(TimelineStrings.actionReply)
            case .more:
                button.image = Self.symbol("ellipsis", TimelineStrings.actionMore)
                button.toolTip = TimelineStrings.actionMore
                button.setAccessibilityLabel(TimelineStrings.actionMore)
            }
            content.addSubview(button)
            return (kind, button)
        }
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    /// Width for the current buttons.
    var preferredWidth: CGFloat {
        let count = CGFloat(buttons.count)
        return 2 * Self.inset + count * Self.buttonWidth + max(0, count - 1) * Self.spacing
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        content.frame = background.bounds
        var x = Self.inset
        let buttonHeight = Self.height - 2 * Self.inset
        for (_, button) in buttons {
            button.frame = NSRect(x: x, y: Self.inset, width: Self.buttonWidth, height: buttonHeight)
            x += Self.buttonWidth + Self.spacing
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let effect = background as? NSVisualEffectView {
            effect.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func button(_ kind: Button) -> NSButton? { buttons.first { $0.kind == kind }?.view }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let postID, let entry = buttons.first(where: { $0.view === sender }) else { return }
        switch entry.kind {
        case .quickReaction(let name): onAction?(.toggleReaction(postID, emojiName: name))
        case .addReaction: onAction?(.addReaction(postID))
        case .reply: onAction?(.reply(replyRoot ?? postID))
        case .more: onMore?(sender)
        }
    }

    func reset() {
        postID = nil
        itemID = nil
        replyRoot = nil
        isHidden = true
    }

    /// Clicks on the bar never fall through to the timeline underneath.
    override func mouseDown(with event: NSEvent) {}
}
