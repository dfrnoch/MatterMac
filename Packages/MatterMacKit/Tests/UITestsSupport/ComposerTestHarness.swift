import AppKit
import MatterMacCore
import MatterMacModels
@testable import MatterMacUI

/// Records every composer delegate callback. Remaining draft bytes come from
/// `draftBudgetBytes` minus the composer's current size, exactly as a host backed
/// by `DraftStore.remainingBytes(for:)` would compute them.
@MainActor
final class ComposerDelegateSpy: ComposerViewControllerDelegate {
    weak var composer: ComposerViewController?
    var draftBudgetBytes: Int?

    private(set) var sentTexts: [String] = []
    private(set) var draftChanges = 0
    private(set) var refusals: [ComposerRefusal] = []
    private(set) var escapes = 0
    private(set) var cancelModeRequests = 0
    private(set) var editLastRequests = 0
    private(set) var images: [(data: Data, type: String)] = []
    private(set) var fileBatches: [[URL]] = []
    private(set) var typingEvents = 0
    private(set) var removedAttachments: [String] = []

    func composerDidRequestSend(text: String) { sentTexts.append(text) }
    func composerDraftDidChange() { draftChanges += 1 }
    func composerRemainingDraftBytes() -> Int {
        guard let draftBudgetBytes, let composer else { return .max }
        return draftBudgetBytes - composer.draftByteCount
    }
    func composerDidRefuseInput(_ refusal: ComposerRefusal) { refusals.append(refusal) }
    func composerDidPressEscape() { escapes += 1 }
    func composerDidRequestCancelMode() { cancelModeRequests += 1 }
    func composerRequestsEditLastMessage() { editLastRequests += 1 }
    func composerDidPasteImage(data: Data, typeIdentifier: String) -> Bool { images.append((data, typeIdentifier)); return true }
    func composerRequestsFileSelection() {}
    func composerDidReceiveFiles(_ urls: [URL]) { fileBatches.append(urls) }
    func composerUserDidType() { typingEvents += 1 }
    func composerDidRemoveAttachment(id: String) { removedAttachments.append(id) }
}

/// Deterministic completion source. Optionally suspends the first call until
/// released, to test that superseded results are discarded.
@MainActor
final class ComposerProviderDouble: ComposerCompletionProvider {
    var itemsByQuery: [String: [CompletionItem]] = [:]
    var defaultItems: [CompletionItem] = []
    private(set) var queries: [(CompletionTrigger, String)] = []
    private(set) var cancelledQueries: [String] = []
    var holdQueries: Set<String> = []
    private var held: [String: CheckedContinuation<Void, Never>] = [:]

    func completions(for trigger: CompletionTrigger, query: String) async -> [CompletionItem] {
        queries.append((trigger, query))
        if holdQueries.contains(query) {
            await withCheckedContinuation { held[query] = $0 }
        }
        if Task.isCancelled { cancelledQueries.append(query) }
        return itemsByQuery[query] ?? defaultItems
    }

    func release(_ query: String) {
        held.removeValue(forKey: query)?.resume()
    }

    var heldCount: Int { held.count }

    static func users(_ names: [String]) -> [CompletionItem] {
        names.map { CompletionItem(id: $0, title: $0, subtitle: "@\($0)", insertionText: "@\($0)") }
    }
}

/// A composer in an offscreen, never-ordered-in window with the text view as
/// first responder. Input-method behavior is simulated by calling the
/// `NSTextInputClient` methods an input method would call; no real input method
/// is involved.
@MainActor
final class ComposerHarness {
    let window: NSWindow
    let controller: ComposerViewController
    let spy = ComposerDelegateSpy()
    let provider = ComposerProviderDouble()

    var textView: ComposerTextView { controller.textView }
    var text: String { textView.string }
    var undoManager: UndoManager { textView.undoManager! }

    init(budget: ResourceBudget = .standard, width: CGFloat = 520) {
        window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        controller = ComposerViewController(budget: budget)
        controller.delegate = spy
        spy.composer = controller
        controller.completion.debounceInterval = .zero
        controller.draftChangeInterval = .milliseconds(20)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        window.contentView = container
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        container.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(textView)
    }

    func close() {
        controller.dismissTransientUI()
        window.close()
    }

    /// What an input method (or plain keyboard) calls for committed text.
    func type(_ string: String) {
        textView.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func setMarked(_ string: String) {
        textView.setMarkedText(string, selectedRange: NSRange(location: (string as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func command(_ selector: Selector) {
        textView.doCommand(by: selector)
    }

    func pressReturn() { command(#selector(NSResponder.insertNewline(_:))) }
    func pressEscape() { command(#selector(NSResponder.cancelOperation(_:))) }

    func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76

    /// Lets the run loop finish the current "event" so the undo manager closes
    /// its event group (as it does between real key presses).
    func endEvent() async {
        var turns = 0
        repeat {
            await Task.yield()
            turns += 1
        } while undoManager.groupingLevel > 0 && turns < 100
        textView.breakUndoCoalescing()
    }

    func enableCompletions(_ items: [CompletionItem]) {
        provider.defaultItems = items
        controller.completionProvider = provider
    }

    /// Waits for the in-flight completion request (no sleeping).
    func settleCompletions() async {
        while let task = controller.completion.pendingFetch {
            await task.value
            if controller.completion.pendingFetch == task { break }
        }
    }

    func undoCount() -> Int {
        var count = 0
        while undoManager.canUndo, count < 10_000 {
            undoManager.undo()
            count += 1
        }
        return count
    }

    /// A private pasteboard, never the user's general pasteboard.
    static func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.mattermac.tests.composer.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// Full recount, for checking the incremental metrics.
    var recountedMetrics: ComposerTextMetrics { ComposerTextMetrics(textView.string) }
}

extension String {
    var utf8Bytes: [UInt8] { Array(utf8) }
    var scalarValues: [UInt32] { unicodeScalars.map(\.value) }
}
