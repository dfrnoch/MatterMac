import AppKit

/// Drives autocomplete for one composer: detects the query before the caret,
/// debounces provider calls (~80 ms), keeps only the latest request (superseded
/// tasks are cancelled and their late results ignored by generation), and shows at
/// most eight items.
///
/// Bounds: at most one provider task in flight per composer; items are truncated
/// to `CompletionPopup.maximumItems` as soon as they arrive. Task lifetime: owned
/// here, cancelled on dismissal, provider change, and every new query; the task
/// holds this controller weakly.
final class ComposerCompletionController {
    weak var textView: ComposerTextView? {
        didSet { popup.announcementElement = textView }
    }

    var provider: (any ComposerCompletionProvider)? {
        didSet { dismiss() }
    }

    var debounceInterval: Duration = .milliseconds(80)

    let popup = CompletionPopup()

    /// Query currently requested or displayed.
    private(set) var context: CompletionContext?
    /// A query the user dismissed with Escape; not reopened until it changes.
    private var suppressedContext: CompletionContext?
    private var fetchTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    /// Number of provider calls started (test and diagnostics counter).
    private(set) var providerCallCount = 0

    var isVisible: Bool { popup.isVisible }

    /// The in-flight fetch, if any (tests await it instead of sleeping).
    var pendingFetch: Task<Void, Never>? { fetchTask }

    init() {
        popup.onClickAccept = { [weak self] in _ = self?.acceptSelected() }
    }

    /// Re-evaluates the query after a text or selection change.
    func update() {
        guard let textView else { return }
        // During composition the marked text is provisional; keep the current
        // state and re-evaluate after the commit.
        if textView.hasMarkedText() { return }
        guard provider != nil, let storage = textView.textStorage,
              let detected = CompletionQueryDetector.detect(in: storage.mutableString,
                                                            selection: textView.selectedRange())
        else {
            dismiss()
            return
        }
        if detected == context { return }
        if detected == suppressedContext { return }
        suppressedContext = nil
        context = detected
        schedule(detected)
    }

    func moveSelection(by delta: Int) {
        popup.moveSelection(by: delta)
    }

    /// Replaces trigger and query with the highlighted item plus a space, as one
    /// undoable edit. Returns `false` when nothing was inserted.
    func acceptSelected() -> Bool {
        guard popup.isVisible, let item = popup.selectedItem, let textView,
              !textView.hasMarkedText(), let storage = textView.textStorage else {
            return false
        }
        // Always replace the query as it is *now* (the list may lag one keystroke).
        guard let current = CompletionQueryDetector.detect(in: storage.mutableString,
                                                           selection: textView.selectedRange())
        else {
            dismiss()
            return false
        }
        dismiss()
        return textView.replaceAsUserEdit(current.replacementRange, with: item.insertionText + " ")
    }

    /// Closes the list and cancels any pending request. With
    /// `suppressingCurrentQuery`, the same query does not reopen it (Escape).
    func dismiss(suppressingCurrentQuery: Bool = false) {
        suppressedContext = suppressingCurrentQuery ? context : nil
        fetchTask?.cancel()
        fetchTask = nil
        generation &+= 1
        context = nil
        popup.dismiss()
    }

    private func schedule(_ query: CompletionContext) {
        fetchTask?.cancel()
        generation &+= 1
        let expected = generation
        let interval = debounceInterval
        guard let provider else { return }
        fetchTask = Task { [weak self] in
            if interval > .zero {
                do { try await Task.sleep(for: interval) } catch { return }
            }
            guard !Task.isCancelled, self?.generation == expected else { return }
            self?.providerCallCount += 1
            // Not holding `self` across the provider call: a closed composer is
            // not kept alive by a slow lookup.
            let items = await provider.completions(for: query.trigger, query: query.query)
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            self.present(Array(items.prefix(CompletionPopup.maximumItems)), for: query)
        }
    }

    private func present(_ items: [CompletionItem], for query: CompletionContext) {
        fetchTask = nil
        guard !items.isEmpty, let textView, let window = textView.window else {
            popup.dismiss()
            return
        }
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: query.triggerLocation, length: 1),
                                        actualRange: nil)
        popup.show(items: items, anchor: anchor, parent: window)
    }
}
