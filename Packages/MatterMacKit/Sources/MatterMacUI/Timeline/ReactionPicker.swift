import AppKit
import MatterMacModels
import MatterMacCore

/// Native system-emoji picker for "Add Reaction": a search field, a static
/// "Frequently Used" row (usage is never recorded), and the catalog grid by
/// category. The search field keeps focus: arrow keys move the grid selection,
/// Return picks the selected emoji (the first one by default), Escape cancels.
/// Custom emoji are loaded by page while browsing, or by the server autocomplete.
final class ReactionPickerViewController: NSViewController, NSSearchFieldDelegate, NSCollectionViewDataSource,
                                          NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    struct Entry: Equatable {
        let name: String
        let glyph: String
        let customID: String?
        init(_ emoji: SystemEmoji) { name = emoji.name; glyph = emoji.glyph; customID = nil }
        init(_ emoji: CustomEmoji) { name = emoji.name; glyph = ":"; customID = emoji.id }
    }
    struct Section: Equatable {
        let title: String
        let emoji: [Entry]
    }
    var customPage: ((Int, String) async -> [CustomEmoji])?
    var customImage: ((String) async -> ImagePipeline.Decoded?)?
    var customLimit = ResourceBudget.standard.customEmojiPickerEntries
    private var customEntries: [Entry] = []
    private var customTask: Task<Void, Never>?
    private var customGeneration = 0
    private var nextPage = 0
    private var hasMore = true
    private var currentQuery = ""


    static let itemSize = NSSize(width: 32, height: 32)
    static let columns = 9
    static let spacing: CGFloat = 2
    static let inset: CGFloat = 8
    static let headerHeight: CGFloat = 22
    /// Search results shown at most (the catalog bounds the work as well).
    static let maximumResults = 90
    static var preferredSize: NSSize {
        NSSize(width: inset * 2 + CGFloat(columns) * itemSize.width + CGFloat(columns - 1) * spacing, height: 360)
    }

    /// Called with the chosen emoji's short name (as sent to the server).
    var onPick: ((String) -> Void)?
    var onCancel: (() -> Void)?

    let catalog: EmojiCatalog
    let searchField = NSSearchField()
    let collectionView = NSCollectionView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No matching emoji"))
    private(set) var sections: [Section] = []
    private(set) var selection: IndexPath?
    /// Last VoiceOver announcement (the selected emoji's name), for tests.
    private(set) var lastAnnouncement: String?
    private let browseSections: [Section]

    init(catalog: EmojiCatalog = .system) {
        self.catalog = catalog
        let frequent = EmojiCatalog.defaultQuickReactions.compactMap(catalog.emoji(named:))
        browseSections = [Section(title: String(localized: "Frequently Used"), emoji: frequent.map(Entry.init))]
            + EmojiCategory.allCases.filter(\.isShownInPicker).map {
                Section(title: $0.displayName, emoji: catalog.pickerEmoji(in: $0).map(Entry.init))
            }
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var selectedEmoji: Entry? {
        guard let selection, sections.indices.contains(selection.section),
              sections[selection.section].emoji.indices.contains(selection.item) else { return nil }
        return sections[selection.section].emoji[selection.item]
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.preferredSize))
        searchField.placeholderString = String(localized: "Search emoji")
        searchField.setAccessibilityLabel(String(localized: "Search emoji"))
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = NSEdgeInsets(top: 0, left: Self.inset, bottom: 6, right: Self.inset)
        layout.headerReferenceSize = NSSize(width: Self.preferredSize.width, height: Self.headerHeight)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(EmojiPickerItem.self, forItemWithIdentifier: EmojiPickerItem.identifier)
        collectionView.register(EmojiPickerHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: EmojiPickerHeader.identifier)
        collectionView.setAccessibilityLabel(String(localized: "Emoji"))

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.preferredSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.preferredSize.height),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        view = root
        preferredContentSize = Self.preferredSize
        apply(query: "")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Query and selection

    /// Shows the browse grid for an empty query, otherwise bounded search results.
    func apply(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sections = browseSections
        } else {
            // The server refuses reaction names over 64 characters (a few skin-tone
            // combinations are longer), so those are not offered.
            let results = catalog.search(trimmed, limit: Self.maximumResults).map(\.emoji)
                .filter { Reaction.isValidEmojiName($0.name) }
            sections = results.isEmpty ? [] : [Section(title: String(localized: "Search Results"), emoji: results.map(Entry.init))]
        }
        currentQuery = trimmed
        customGeneration += 1
        customTask?.cancel()
        customTask = nil
        customEntries = []
        nextPage = 0
        hasMore = true
        loadCustomPage()
        emptyLabel.isHidden = !sections.isEmpty
        collectionView.reloadData()
        select(sections.firstIndex { !$0.emoji.isEmpty }.map { IndexPath(item: 0, section: $0) }, announce: false)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        customGeneration += 1
        customTask?.cancel()
        customTask = nil
        for case let item as EmojiPickerItem in collectionView.visibleItems() { item.cancelImage() }
    }

    func loadCustomPage() {
        guard customTask == nil, hasMore, let customPage else { return }
        let generation = customGeneration, page = nextPage, query = currentQuery
        customTask = Task { [weak self] in
            let result = await customPage(page, query)
            guard !Task.isCancelled, let self, customGeneration == generation else { return }
            customTask = nil
            let known = Set(customEntries.map(\.name))
            customEntries += result.filter { !known.contains($0.name) }.map(Entry.init)
            customEntries = Array(customEntries.prefix(max(0, customLimit)))
            nextPage += 1
            hasMore = query.isEmpty && result.count == 60 && customEntries.count < customLimit
            sections.removeAll { $0.title == String(localized: "Custom") }
            if !customEntries.isEmpty { sections.append(Section(title: String(localized: "Custom"), emoji: customEntries)) }
            emptyLabel.isHidden = !sections.isEmpty
            collectionView.reloadData()
            if selection == nil { select(sections.firstIndex { !$0.emoji.isEmpty }.map { IndexPath(item: 0, section: $0) }, announce: false) }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        if sections[indexPath.section].title == String(localized: "Custom"),
           indexPath.item >= customEntries.count - 18 { loadCustomPage() }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? EmojiPickerItem)?.cancelImage()
    }

    private func select(_ path: IndexPath?, announce: Bool = true) {
        selection = path
        // The highlight is drawn by the items; the collection view's own selection
        // stays empty so that every click (even on the highlighted item) reports.
        for case let item as EmojiPickerItem in collectionView.visibleItems() {
            item.isCurrent = collectionView.indexPath(for: item) == path
        }
        guard let path else { return }
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        if announce, let emoji = selectedEmoji {
            let text = Self.spokenName(emoji)
            lastAnnouncement = text
            NSAccessibility.post(element: searchField, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Moves by `delta` items in reading order across sections (Left/Right).
    func moveSelection(by delta: Int) {
        let flat = sections.indices.flatMap { section in sections[section].emoji.indices.map { IndexPath(item: $0, section: section) } }
        guard !flat.isEmpty else { return }
        let current = selection.flatMap(flat.firstIndex(of:)) ?? 0
        select(flat[min(max(0, current + delta), flat.count - 1)])
    }

    /// Moves one grid row up or down (Up/Down), across section boundaries.
    func moveSelectionRow(down: Bool) {
        guard let selection else { moveSelection(by: 0); return }
        let rowLength = columnCount
        let section = sections[selection.section].emoji.count
        let column = selection.item % rowLength
        if down {
            if selection.item + rowLength < section {
                select(IndexPath(item: selection.item + rowLength, section: selection.section))
            } else if selection.item / rowLength < (section - 1) / rowLength {
                select(IndexPath(item: section - 1, section: selection.section)) // shorter last row
            } else if let next = sections.indices.first(where: { $0 > selection.section && !sections[$0].emoji.isEmpty }) {
                select(IndexPath(item: min(column, sections[next].emoji.count - 1), section: next))
            }
        } else {
            if selection.item >= rowLength {
                select(IndexPath(item: selection.item - rowLength, section: selection.section))
            } else if let previous = sections.indices.last(where: { $0 < selection.section && !sections[$0].emoji.isEmpty }) {
                let count = sections[previous].emoji.count
                let lastRowStart = (count - 1) / rowLength * rowLength
                select(IndexPath(item: min(lastRowStart + column, count - 1), section: previous))
            }
        }
    }

    /// Items per grid row as laid out (a legacy scroller may take one column).
    var columnCount: Int {
        let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : Self.preferredSize.width
        let fitting = (width - Self.inset * 2 + Self.spacing) / (Self.itemSize.width + Self.spacing)
        return max(1, Int(fitting.rounded(.down)))
    }

    func pickSelection() {
        guard let emoji = selectedEmoji else { NSSound.beep(); return }
        onPick?(emoji.name)
    }

    static func spokenName(_ emoji: Entry) -> String {
        emoji.name.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        apply(query: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveLeft(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveRight(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelectionRow(down: false)
        case #selector(NSResponder.moveDown(_:)): moveSelectionRow(down: true)
        case #selector(NSResponder.insertNewline(_:)): pickSelection()
        case #selector(NSResponder.cancelOperation(_:)): onCancel?()
        default: return false
        }
        return true
    }

    // MARK: - NSCollectionViewDataSource / Delegate

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].emoji.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: EmojiPickerItem.identifier, for: indexPath)
        if let item = item as? EmojiPickerItem {
            item.configure(sections[indexPath.section].emoji[indexPath.item], imageLoader: customImage)
            item.isCurrent = indexPath == selection
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: EmojiPickerHeader.identifier, for: indexPath)
        (view as? EmojiPickerHeader)?.label.stringValue = sections[indexPath.section].title
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        // Only user clicks reach this delegate method.
        collectionView.deselectItems(at: indexPaths)
        guard let path = indexPaths.first else { return }
        selection = path
        pickSelection()
    }
}

/// One emoji cell: the glyph as a large label; VoiceOver reads the short name.
final class EmojiPickerItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("EmojiPickerItem")
    private let glyphLabel = NSTextField(labelWithString: "")
    private let customImageView = NSImageView()
    private var imageTask: Task<Void, Never>?
    private var decodedImage: ImagePipeline.Decoded?
    private var imageID: String?


    override func loadView() {
        let cell = EmojiCellView(frame: NSRect(origin: .zero, size: ReactionPickerViewController.itemSize))
        glyphLabel.font = .systemFont(ofSize: 22)
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        glyphLabel.setAccessibilityElement(false)
        customImageView.frame = NSRect(x: 5, y: 5, width: 22, height: 22)
        customImageView.imageScaling = .scaleProportionallyUpOrDown
        customImageView.setAccessibilityElement(false)
        cell.addSubview(customImageView)
        cell.addSubview(glyphLabel)
        NSLayoutConstraint.activate([
            glyphLabel.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            glyphLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.button)
        view = cell
    }

    func cancelImage() {
        imageTask?.cancel()
        imageTask = nil
        imageID = nil
        customImageView.image = nil
        decodedImage = nil
    }

    override func prepareForReuse() { super.prepareForReuse(); cancelImage() }

    func configure(_ emoji: ReactionPickerViewController.Entry,
                   imageLoader: ((String) async -> ImagePipeline.Decoded?)?) {
        _ = view
        cancelImage()
        glyphLabel.isHidden = false
        glyphLabel.stringValue = emoji.glyph
        if let id = emoji.customID, let imageLoader {
            imageID = id
            imageTask = Task { [weak self] in
                let decoded = await imageLoader(id)
                guard !Task.isCancelled, let self, imageID == id, let decoded else { return }
                decodedImage = decoded
                customImageView.image = NSImage(cgImage: decoded.image, size: .zero)
                glyphLabel.isHidden = true
                imageTask = nil
            }
        }
        view.toolTip = ":" + emoji.name + ":"
        view.setAccessibilityLabel(ReactionPickerViewController.spokenName(emoji))
        view.setAccessibilityHelp(":" + emoji.name + ":")
    }

    /// The keyboard selection (drawn here; see `ReactionPickerViewController.select`).
    var isCurrent = false {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        (view as? EmojiCellView)?.isHighlighted = isCurrent
        view.setAccessibilitySelected(isCurrent)
    }
}

/// Layer-backed cell background; `updateLayer` resolves the dynamic color for the
/// current appearance.
final class EmojiCellView: NSView {
    var isHighlighted = false {
        didSet { if oldValue != isHighlighted { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = isHighlighted ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil
    }
}

final class EmojiPickerHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("EmojiPickerHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ReactionPickerViewController.inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

extension EmojiCategory {
    var displayName: String {
        switch self {
        case .smileysEmotion: String(localized: "Smileys & Emotion")
        case .peopleBody: String(localized: "People & Body")
        case .animalsNature: String(localized: "Animals & Nature")
        case .foodDrink: String(localized: "Food & Drink")
        case .activities: String(localized: "Activities")
        case .travelPlaces: String(localized: "Travel & Places")
        case .objects: String(localized: "Objects")
        case .symbols: String(localized: "Symbols")
        case .flags: String(localized: "Flags")
        case .component: String(localized: "Components")
        }
    }
}

// MARK: - Presentation

/// Shows the picker in a transient popover anchored to the message row (or the
/// timeline when the row is not on screen) and hands the chosen name back.
enum ReactionPickerPresenter {
    @discardableResult
    static func present(for post: PostID, in timeline: TimelineViewController,
                        model: SessionViewModel? = nil, channel: ChannelID? = nil,
                        pick: @escaping (String) -> Void) -> NSPopover {
        let picker = ReactionPickerViewController()
        if let model, let channel {
            picker.customLimit = model.app?.environment.budget.customEmojiPickerEntries ?? ResourceBudget.standard.customEmojiPickerEntries
            picker.customPage = { [weak model] page, query in
                guard let model, !model.isDetached else { return [] }
                return await model.session.customEmojiPage(page: page, query: query)
            }
            picker.customImage = { [weak model] id in
                guard let model, !model.isDetached, let pipeline = model.app?.images else { return nil }
                return await model.session.timelineImage(.customEmoji(id: id), channel: channel,
                                                         maxPixelSize: 64, pipeline: pipeline)
            }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.contentSize = ReactionPickerViewController.preferredSize
        picker.onPick = { [weak popover] name in
            popover?.performClose(nil)
            pick(name)
        }
        picker.onCancel = { [weak popover] in popover?.performClose(nil) }
        let bounds = timeline.view.bounds
        let anchor = timeline.anchorRect(for: post)
            ?? NSRect(x: bounds.midX, y: bounds.minY + 8, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: timeline.view, preferredEdge: .maxY)
        return popover
    }
}

extension TimelineViewController {
    /// The visible part of a post's row in `view` coordinates, or `nil` when the
    /// row is not in the timeline or scrolled out of view.
    func anchorRect(for post: PostID) -> NSRect? {
        guard isViewLoaded, let row = rowIndex[TimelineItemID(.post(post))], row < tableView.numberOfRows else { return nil }
        let visible = tableView.rect(ofRow: row).intersection(tableView.visibleRect)
        guard !visible.isEmpty else { return nil }
        return view.convert(visible, from: tableView)
    }
}
