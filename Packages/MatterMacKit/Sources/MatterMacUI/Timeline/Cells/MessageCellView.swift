import AppKit
import MatterMacModels
import MatterMacCore

/// A post row: avatar, header, TextKit 1 body, attachments, reactions, reply count,
/// and pending-send accessory. Frames come from a precomputed `MessageRowLayout` (the
/// same one that produced the row height), so there is no Auto Layout pass per row.
///
/// Reuse: `prepareForReuse()` resets all visible state and releases image demand; the
/// optional subviews are created lazily and pooled per cell (bounded by
/// `maximumDisplayedFiles` / `maximumDisplayedReactions`).
final class MessageCellView: NSTableCellView, NSTextViewDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MatterMacMessageCell")

    /// Total instances ever created (debug counter for bounded-instantiation tests).
    static var instancesCreated = 0

    weak var host: (any TimelineCellHost)?
    private(set) var itemID: TimelineItemID?
    private var post: PostPresentation?
    private var rowLayout = MessageRowLayout()
    private var mentionsCurrentUser = false

    override func draw(_ dirtyRect: NSRect) {
        if mentionsCurrentUser {
            TimelinePalette.mentionRowHighlight.setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
    }
    private var avatarRequest: TimelineImageRequest?
    private var thumbnailRequests: [TimelineImageRequest: Int] = [:]
    /// Requests registered with the host that have not been satisfied yet.
    private var outstandingRequests: Set<TimelineImageRequest> = []

    let avatarView = AvatarView(frame: .zero)
    let nameLabel = TimelineLabel(frame: .zero)
    let metaLabel = TimelineLabel(frame: .zero)
    let bodyTextView: MessageBodyTextView
    private var threadContextLabel: TimelineLabel?
    private var showMoreButton: TimelineTextButton?
    private var repliesButton: TimelineTextButton?
    private var thumbnailViews: [ImageThumbnailView] = []
    private var fileChipViews: [FileChipView] = []
    private var attachmentOverflowLabel: TimelineLabel?
    private var reactionViews: [ReactionChipView] = []
    private var reactionOverflowLabel: TimelineLabel?
    private var linkPreviewView: LinkPreviewCardView?
    private var linkPreviewRequest: TimelineImageRequest?
    /// Time shown in the avatar gutter of a continuation row while hovered/selected.
    private var hoverTimeLabel: TimelineLabel?
    private(set) var isHoverHighlighted = false
    private var pendingSpinner: NSProgressIndicator?
    private var pendingLabel: TimelineLabel?
    private var retryButton: TimelineTextButton?
    private var discardButton: TimelineTextButton?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        bodyTextView = MessageBodyTextView(usingTextLayoutManager: false)
        super.init(frame: frameRect)
        Self.instancesCreated += 1
        identifier = Self.reuseIdentifier
        bodyTextView.configureForTimeline()
        bodyTextView.delegate = self
        nameLabel.isSingleLine = true
        metaLabel.isSingleLine = true
        addSubview(avatarView)
        addSubview(nameLabel)
        addSubview(metaLabel)
        addSubview(bodyTextView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let showProfile: () -> Void = { [weak self] in
            guard let self, let user = self.post?.author.userID else { return }
            self.host?.perform(.showProfile(user))
        }
        avatarView.onPress = showProfile
        nameLabel.onPress = showProfile
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Configuration

    func configure(item: TimelineItem, post: PostPresentation, layout: MessageRowLayout, body: NSAttributedString,
                   host: any TimelineCellHost) {
        if itemID != nil { resetContent() }
        self.host = host
        self.itemID = item.id
        self.post = post
        self.rowLayout = layout
        mentionsCurrentUser = false
        body.enumerateAttribute(.matterMacSelfMention, in: NSRange(location: 0, length: body.length)) { value, _, stop in
            if value != nil { mentionsCurrentUser = true; stop.pointee = true }
        }
        needsDisplay = true
        bodyTextView.host = host
        let fonts = host.rowMetrics.fonts

        // Avatar and header
        let showsHeader = layout.header != nil
        avatarView.isHidden = layout.avatar == nil
        nameLabel.isHidden = !showsHeader
        metaLabel.isHidden = !showsHeader
        if layout.avatar != nil {
            avatarView.initials = AvatarView.initials(for: post.author.displayName)
            avatarView.tint = TimelinePalette.avatarTint(for: post.author.userID.rawValue)
            avatarView.setAccessibilityLabel(TimelineStrings.avatarAccessibility(name: post.author.displayName))
            let request = TimelineImageRequest.avatar(post.author.userID, revision: post.author.avatarRevision)
            avatarRequest = request
            avatarView.image = resolveImage(request)
        }
        if showsHeader {
            nameLabel.attributedText = NSAttributedString(string: post.author.displayName, attributes: [
                .font: fonts.authorName, .foregroundColor: NSColor.labelColor,
            ])
            metaLabel.attributedText = headerMeta(post: post, fonts: fonts)
            metaLabel.toolTip = Self.timeToolTip(post)
        }

        if let frame = layout.threadContext {
            let label = threadContextLabel ?? makeLabel(\.threadContextLabel)
            label.isHidden = false
            label.frame = frame
            label.attributedText = NSAttributedString(string: "↳ " + TimelineStrings.repliedToThread, attributes: [
                .font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }

        bodyTextView.setText(body, width: layout.body.width)
        bodyTextView.onMentionClick = { [weak self] key, value in
            guard let host = self?.host else { return }
            host.perform(key == .matterMacChannelMention ? .channelMentionTapped(value) : .mentionTapped(value))
        }

        if layout.showMore != nil {
            let button = showMoreButton ?? makeButton(\.showMoreButton, style: .link)
            button.isHidden = false
            button.configure(title: TimelineStrings.showMore, font: fonts.meta)
            button.onPress = { [weak self] in
                guard let self, let id = self.post?.postID else { return }
                self.host?.perform(.expand(id))
            }
        }

        configureLinkPreview(post: post, host: host)
        configureAttachments(post: post, fonts: fonts)
        configureReactions(post: post, fonts: fonts)

        if layout.replies != nil {
            let button = repliesButton ?? makeButton(\.repliesButton, style: .link)
            button.isHidden = false
            button.configure(title: TimelineStrings.replies(post.replyCount), font: fonts.metaBold)
            button.onPress = { [weak self] in
                guard let self, let post = self.post, let root = post.rootID ?? post.postID else { return }
                self.host?.perform(.openThread(root: root))
            }
        }

        configurePending(post: post, fonts: fonts)
        setAccessibilityLabel(TimelineStrings.accessibilityLabel(for: post))
        setAccessibilityCustomActions(TimelinePostActions.accessibilityEntries(for: post).map { entry in
            NSAccessibilityCustomAction(name: entry.title) { [weak self] in
                guard let host = self?.host else { return false }
                host.performPrepared(entry.action)
                return true
            }
        })
        needsLayout = true
    }

    static func timeToolTip(_ post: PostPresentation) -> String {
        var text = TimelineStrings.longDateTime(post.createdAt)
        if let edited = post.editedAt { text += "\n" + TimelineStrings.editedAt(edited) }
        return text
    }

    /// Hover/selection state: continuation rows show their time in the avatar gutter.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHoverHighlighted else { return }
        isHoverHighlighted = hovered
        guard let post, post.postID != nil, rowLayout.header == nil, let host else {
            hoverTimeLabel?.isHidden = true
            return
        }
        let label = hoverTimeLabel ?? makeLabel(\.hoverTimeLabel)
        label.isHidden = !hovered
        guard hovered else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let font = NSFont.systemFont(ofSize: max(9, host.rowMetrics.fonts.meta.pointSize - 2))
        label.attributedText = NSAttributedString(string: TimelineStrings.time(post.createdAt), attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
        label.toolTip = Self.timeToolTip(post)
        needsLayout = true
    }

    private func configureLinkPreview(post: PostPresentation, host: any TimelineCellHost) {
        guard let preview = post.linkPreview, let layout = rowLayout.linkPreview else { return }
        let view = linkPreviewView ?? {
            let view = LinkPreviewCardView(frame: .zero)
            addSubview(view)
            linkPreviewView = view
            return view
        }()
        var image: NSImage?
        if let url = preview.image?.url {
            let request = TimelineImageRequest.linkPreview(url: url)
            linkPreviewRequest = request
            image = resolveImage(request)
        }
        view.configure(preview, layout: layout, metrics: host.rowMetrics, image: image)
        view.host = host
        view.frame = layout.frame
        view.isHidden = false
        let link = preview.link
        view.onPress = { [weak self] in self?.host?.perform(.openLink(link)) }
    }

    private func headerMeta(post: PostPresentation, fonts: TimelineFonts) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let meta: [NSAttributedString.Key: Any] = [.font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor]
        if post.author.isBot {
            text.append(NSAttributedString(string: " " + TimelineStrings.bot + " ", attributes: [
                .font: fonts.metaBold, .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: TimelinePalette.placeholderFill,
            ]))
            text.append(NSAttributedString(string: "  ", attributes: meta))
        }
        text.append(NSAttributedString(string: TimelineStrings.time(post.createdAt), attributes: meta))
        // "(edited)" follows the message text (so continuation rows show it too).
        if post.isPinned { text.append(NSAttributedString(string: "  📌 " + TimelineStrings.pinned, attributes: meta)) }
        if post.isSaved { text.append(NSAttributedString(string: "  🔖 " + TimelineStrings.saved, attributes: meta)) }
        return text
    }

    private func configureAttachments(post: PostPresentation, fonts: TimelineFonts) {
        var thumbnailIndex = 0
        var chipIndex = 0
        for (index, file) in post.files.prefix(TimelineRowMetrics.maximumDisplayedFiles).enumerated()
            where index < rowLayout.attachments.count {
            let frame = rowLayout.attachments[index]
            let open: () -> Void = { [weak self] in self?.host?.perform(.openFile(file)) }
            if TimelineRowMetrics.showsThumbnail(file) {
                if thumbnailIndex == thumbnailViews.count {
                    let view = ImageThumbnailView(frame: .zero)
                    thumbnailViews.append(view)
                    addSubview(view)
                }
                let view = thumbnailViews[thumbnailIndex]
                thumbnailIndex += 1
                let request = TimelineImageRequest.attachment(file)
                thumbnailRequests[request] = thumbnailIndex - 1
                view.configure(file: file, image: resolveImage(request))
                // Primary action previews; saving stays in the context menu and actions.
                view.onPress = { [weak self] in self?.host?.perform(.previewImage(file)) }
                view.onSave = open
                view.host = host
                view.frame = frame
                view.isHidden = false
            } else {
                if chipIndex == fileChipViews.count {
                    let view = FileChipView(frame: .zero)
                    fileChipViews.append(view)
                    addSubview(view)
                }
                let view = fileChipViews[chipIndex]
                chipIndex += 1
                view.configure(file: file, fonts: fonts)
                view.onPress = open
                view.frame = frame
                view.isHidden = false
            }
        }
        if let frame = rowLayout.attachmentOverflow {
            let label = attachmentOverflowLabel ?? makeLabel(\.attachmentOverflowLabel)
            label.isHidden = false
            label.frame = frame
            label.attributedText = NSAttributedString(
                string: TimelineStrings.moreFiles(post.files.count - TimelineRowMetrics.maximumDisplayedFiles),
                attributes: [.font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    private func configureReactions(post: PostPresentation, fonts: TimelineFonts) {
        guard let host else { return }
        for (index, reaction) in post.reactions.prefix(TimelineRowMetrics.maximumDisplayedReactions).enumerated()
            where index < rowLayout.reactions.count {
            if index == reactionViews.count {
                let view = ReactionChipView(frame: .zero)
                reactionViews.append(view)
                addSubview(view)
            }
            let view = reactionViews[index]
            let emoji = host.renderer.emojiText(for: reaction.emojiName)
            view.configure(emoji: emoji, count: reaction.count, includesCurrentUser: reaction.includesCurrentUser,
                           fonts: fonts)
            view.frame = rowLayout.reactions[index]
            view.isHidden = false
            let reactors = TimelineStrings.reactors(reaction)
            view.toolTip = reactors
            view.setAccessibilityLabel(TimelineStrings.reactionAccessibility(
                emoji: emoji, name: reaction.emojiName, count: reaction.count,
                includesYou: reaction.includesCurrentUser))
            view.setAccessibilityHelp(reactors)
            if let postID = post.postID, post.actions.canReact {
                let name = reaction.emojiName
                view.onPress = { [weak self] in self?.host?.perform(.toggleReaction(postID, emojiName: name)) }
            } else {
                view.onPress = nil
            }
        }
        if let frame = rowLayout.reactionOverflow {
            let label = reactionOverflowLabel ?? makeLabel(\.reactionOverflowLabel)
            label.isHidden = false
            label.frame = frame
            label.attributedText = NSAttributedString(
                string: TimelineStrings.moreReactions(post.reactions.count - TimelineRowMetrics.maximumDisplayedReactions),
                attributes: [.font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    private func configurePending(post: PostPresentation, fonts: TimelineFonts) {
        guard let state = post.sendState, let pending = rowLayout.pending, let host else { return }
        if pending.spinner != nil {
            let spinner = pendingSpinner ?? {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isDisplayedWhenStopped = false
                addSubview(spinner)
                pendingSpinner = spinner
                return spinner
            }()
            spinner.isHidden = false
            spinner.startAnimation(nil)
        }
        let label = pendingLabel ?? makeLabel(\.pendingLabel)
        label.isSingleLine = false
        label.isHidden = false
        label.attributedText = host.rowMetrics.statusText(for: state)
        if pending.retry != nil, let pendingID = post.pendingID {
            let button = retryButton ?? makeButton(\.retryButton, style: .bordered)
            button.isHidden = false
            button.configure(title: TimelineStrings.retry, font: fonts.meta)
            button.onPress = { [weak self] in self?.host?.perform(.retrySend(pendingID)) }
        }
        if pending.discard != nil {
            let button = discardButton ?? makeButton(\.discardButton, style: .bordered)
            button.isHidden = false
            button.configure(title: TimelineStrings.discard, font: fonts.meta)
            let pendingID = post.pendingID
            button.onPress = { [weak self] in
                guard let pendingID else { return }
                self?.host?.perform(.discardSend(pendingID))
            }
            button.isEnabled = pendingID != nil
        }
    }

    private func makeLabel(_ keyPath: ReferenceWritableKeyPath<MessageCellView, TimelineLabel?>) -> TimelineLabel {
        let label = TimelineLabel(frame: .zero)
        addSubview(label)
        self[keyPath: keyPath] = label
        return label
    }

    private func makeButton(_ keyPath: ReferenceWritableKeyPath<MessageCellView, TimelineTextButton?>,
                            style: TimelineTextButton.Style) -> TimelineTextButton {
        let button = TimelineTextButton(style: style)
        addSubview(button)
        self[keyPath: keyPath] = button
        return button
    }

    // MARK: - Images

    private func resolveImage(_ request: TimelineImageRequest) -> NSImage? {
        guard let host else { return nil }
        if outstandingRequests.insert(request).inserted { host.registerImageDemand(request) }
        return host.image(for: request)
    }

    /// Called by the controller for displayed rows only.
    func imageDidBecomeAvailable(_ request: TimelineImageRequest) {
        guard outstandingRequests.contains(request), let host, let image = host.image(for: request) else { return }
        if request == avatarRequest { avatarView.image = image }
        if request == linkPreviewRequest { linkPreviewView?.setImage(image) }
        if let index = thumbnailRequests[request], index < thumbnailViews.count {
            thumbnailViews[index].setImage(image)
        }
    }

    /// Re-queries images (e.g. after a backing-scale change).
    func refreshImages() {
        guard host != nil else { return }
        if let request = avatarRequest { avatarView.image = resolveImage(request) }
        if let request = linkPreviewRequest { linkPreviewView?.setImage(resolveImage(request)) }
        for (request, index) in thumbnailRequests where index < thumbnailViews.count {
            thumbnailViews[index].setImage(resolveImage(request))
        }
    }

    var hasOutstandingImageRequests: Bool { !outstandingRequests.isEmpty }
    var displayedAvatarImage: NSImage? { avatarView.image }

    /// Releases per-cell image demand; called when the row leaves the table.
    func didEndDisplay() {
        releaseImageDemand()
        pendingSpinner?.stopAnimation(nil)
    }

    func releaseImageDemand() {
        avatarView.image = nil
        for view in thumbnailViews { view.setImage(nil) }
        linkPreviewView?.setImage(nil)
        if let host {
            for request in outstandingRequests { host.unregisterImageDemand(request) }
        }
        outstandingRequests.removeAll()
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        resetContent()
    }

    private func resetContent() {
        releaseImageDemand()
        itemID = nil
        post = nil
        avatarRequest = nil
        linkPreviewRequest = nil
        thumbnailRequests.removeAll()
        linkPreviewView?.reset()
        linkPreviewView?.isHidden = true
        hoverTimeLabel?.isHidden = true
        hoverTimeLabel?.attributedText = NSAttributedString()
        isHoverHighlighted = false
        metaLabel.toolTip = nil
        setAccessibilityCustomActions(nil)
        rowLayout = MessageRowLayout()
        mentionsCurrentUser = false
        needsDisplay = true
        avatarView.image = nil
        avatarView.initials = ""
        avatarView.setAccessibilityLabel(nil)
        nameLabel.attributedText = NSAttributedString()
        metaLabel.attributedText = NSAttributedString()
        bodyTextView.clear()
        threadContextLabel?.isHidden = true
        threadContextLabel?.attributedText = NSAttributedString()
        for button in [showMoreButton, repliesButton, retryButton, discardButton] {
            button?.reset()
            button?.isHidden = true
            button?.isEnabled = true
        }
        for view in thumbnailViews {
            view.reset()
            view.isHidden = true
        }
        for view in fileChipViews {
            view.reset()
            view.isHidden = true
        }
        for view in reactionViews {
            view.reset()
            view.isHidden = true
        }
        attachmentOverflowLabel?.isHidden = true
        reactionOverflowLabel?.isHidden = true
        pendingSpinner?.stopAnimation(nil)
        pendingSpinner?.isHidden = true
        pendingLabel?.isHidden = true
        pendingLabel?.attributedText = NSAttributedString()
        setAccessibilityLabel(nil)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let layout = rowLayout
        if let frame = layout.avatar { avatarView.frame = frame }
        if let header = layout.header, let fonts = host?.rowMetrics.fonts {
            let nameWidth = min(DrawnText.width(of: nameLabel.attributedText), max(40, header.width * 0.65))
            nameLabel.frame = CGRect(x: header.minX, y: header.minY, width: nameWidth, height: header.height)
            let baseline = max(0, ceil(fonts.authorName.ascender - fonts.meta.ascender))
            let metaX = nameLabel.frame.maxX + 8
            metaLabel.frame = CGRect(x: metaX, y: header.minY + baseline, width: max(0, header.maxX - metaX),
                                     height: fonts.metaLineHeight)
        }
        if let frame = layout.threadContext { threadContextLabel?.frame = frame }
        bodyTextView.frame = layout.body
        if let label = hoverTimeLabel, !label.isHidden, let fonts = host?.rowMetrics.fonts {
            let height = ceil(fonts.metaLineHeight)
            let baseline = max(0, floor((fonts.bodyLineHeight - height) / 2))
            label.frame = CGRect(x: 2, y: layout.body.minY + baseline + 1,
                                 width: TimelineRowMetrics.contentLeading - 8, height: height)
        }
        if let frame = layout.linkPreview?.frame { linkPreviewView?.frame = frame }
        if let frame = layout.showMore, let button = showMoreButton {
            button.frame = CGRect(x: frame.minX, y: frame.minY, width: min(frame.width, button.fittingWidth + 4),
                                  height: frame.height)
        }
        if let frame = layout.replies, let button = repliesButton {
            button.frame = CGRect(x: frame.minX, y: frame.minY, width: min(frame.width, button.fittingWidth + 4),
                                  height: frame.height)
        }
        if let pending = layout.pending {
            if let frame = pending.spinner { pendingSpinner?.frame = frame }
            pendingLabel?.frame = pending.status
            var x = pending.status.minX
            if pending.spinner != nil { x = (pending.spinner?.minX ?? x) }
            if let frame = pending.retry, let button = retryButton, !button.isHidden {
                let width = button.fittingWidth + 12
                button.frame = CGRect(x: x, y: frame.minY, width: width, height: frame.height)
                x += width + 8
            }
            if let frame = pending.discard, let button = discardButton, !button.isHidden {
                button.frame = CGRect(x: x, y: frame.minY, width: button.fittingWidth + 12, height: frame.height)
            }
        }
    }

    // MARK: - Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Re-validate: only SafeLink destinations are ever passed on, and never opened here.
        let raw: String? = (link as? URL)?.absoluteString ?? (link as? String)
        if let raw, let safe = SafeLink(raw) { host?.perform(.openLink(safe)) }
        return true
    }

    // MARK: - Accessibility

    override func accessibilityChildren() -> [Any]? {
        super.accessibilityChildren()?.filter { child in
            guard let view = child as? NSView else { return true }
            return !view.isHidden
        }
    }

    var accessibilitySummary: String? { accessibilityLabel() }
    var displayedBodyText: String { bodyTextView.string }
}
