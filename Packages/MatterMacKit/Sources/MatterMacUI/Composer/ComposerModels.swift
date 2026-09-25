public import Foundation
public import MatterMacModels

// Public value types and protocols of the native composer (SPEC §4, §11, §13).
// Everything here is session-only: nothing is persisted, and the composer never
// clears text on its own. The host (conversation coordinator) owns drafts, modes,
// attachments, and sending; the composer reports intent through
// `ComposerViewControllerDelegate`.

/// Which key chord sends a message. Configurable per running session only.
nonisolated public enum ComposerSendBehavior: Hashable, Sendable {
    /// Return sends; Shift-Return, Option-Return, and Control-Return insert a newline.
    case returnSends
    /// Return inserts a newline; Command-Return sends.
    case commandReturnSends
}

/// What the composer is currently doing. The host sets it; the composer shows a
/// banner with a Cancel button for everything except `.compose`.
nonisolated public enum ComposerMode: Hashable, Sendable {
    case compose
    /// Replying in a thread started by `authorName` (display text only).
    case reply(authorName: String)
    /// Editing an existing post. `original` is the post's current server text; the
    /// host decides what "no change" means.
    case edit(postID: PostID, original: String)
}

/// Why the composer refused user input or a send request. The text is never
/// changed by a refusal; the host shows an explanation.
nonisolated public enum ComposerRefusal: Hashable, Sendable {
    /// One paste or drop carried more text than allowed. `limit` is the per-paste
    /// UTF-8 byte ceiling (`ResourceBudget.maximumPasteBytes`).
    case pasteTooLarge(limit: Int)
    /// Accepting the edit would grow the draft past the session's unsent-text
    /// budget. `limit` is the number of additional UTF-8 bytes that were still
    /// available when the edit was refused (may be 0).
    case draftBudgetExceeded(limit: Int)
    /// One paste or drop carried more file URLs than the composer accepts at once.
    case tooManyFiles(limit: Int)
    /// A send was requested while the text exceeds the server's message length
    /// (`limit` is the server limit in Unicode scalars). The text is kept intact.
    case messageTooLong(limit: Int)
}

/// A pending attachment chip shown above the text. Host-provided and host-owned.
nonisolated public struct ComposerAttachment: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        /// Selected but not yet uploading (queued behind the transfer budget).
        case waiting
        /// `fractionCompleted` in 0...1.
        case uploading(fractionCompleted: Double)
        /// Uploaded and ready to attach to the next send.
        case ready
        /// Upload failed; the host explains why elsewhere and may offer retry.
        case failed
    }

    /// Host-assigned opaque identity, stable for the chip's lifetime. Never shown.
    public let id: String
    /// File name as shown to the user (untrusted; rendered as plain text only).
    public var name: String
    public var byteCount: Int64
    public var status: Status

    public init(id: String, name: String, byteCount: Int64, status: Status) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.status = status
    }
}

/// The character that opened an autocomplete query.
nonisolated public enum CompletionTrigger: Hashable, Sendable, CaseIterable {
    /// `@` — users.
    case user
    /// `~` — channels.
    case channel
    /// `:` — emoji (only after at least two query characters).
    case emoji
    case command

    public var character: Character {
        switch self {
        case .user: "@"
        case .channel: "~"
        case .emoji: ":"
        case .command: "/"
        }
    }

    /// Minimum number of query characters before the provider is asked.
    public var minimumQueryLength: Int {
        switch self {
        case .user, .channel, .command: 0
        case .emoji: 2
        }
    }
}

/// One autocomplete suggestion. All strings are untrusted display text.
nonisolated public struct CompletionItem: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// Replaces the trigger and query when accepted (a trailing space is added).
    public let insertionText: String
    /// Optional short leading text, e.g. the emoji glyph or a status symbol.
    public let leadingText: String?

    public init(id: String, title: String, subtitle: String? = nil, insertionText: String, leadingText: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.insertionText = insertionText
        self.leadingText = leadingText
    }
}

/// Supplies autocomplete items. Called at most once per debounce window with the
/// latest query; superseded calls are cancelled (the provider should honor task
/// cancellation). Implementations must do their lookup work off the main actor
/// (e.g. by awaiting a Core actor) and return promptly on cancellation. The
/// composer shows at most eight items and discards the rest immediately.
@MainActor
public protocol ComposerCompletionProvider: AnyObject {
    func completions(for trigger: CompletionTrigger, query: String) async -> [CompletionItem]
}

/// Host callbacks. All are delivered on the main actor. The composer never clears
/// or rewrites text by itself: after `composerDidRequestSend(text:)` the host
/// calls `clear()` only once it has accepted the send (queued it with a pending
/// identifier); a refused send leaves the text untouched.
@MainActor
public protocol ComposerViewControllerDelegate: AnyObject {
    /// The user asked to send. `text` is exact (no trimming or normalization).
    func composerDidRequestSend(text: String)
    /// Text or selection changed through user action. Coalesced to at most 4 Hz;
    /// read `currentDraft()` and save it. Never fired by `load(draft:)`/`clear()`.
    func composerDraftDidChange()
    /// How many more UTF-8 bytes the current composer text may grow by. Typically
    /// `draftStore.remainingBytes(for: key) - composer.draftByteCount`.
    func composerRemainingDraftBytes() -> Int
    func composerDidRefuseInput(_ refusal: ComposerRefusal)
    /// Escape with no completion popup open, in `.compose` mode (e.g. dismiss a
    /// transient panel). In reply/edit mode Escape calls
    /// `composerDidRequestCancelMode()` instead.
    func composerDidPressEscape()
    /// The Cancel button in the reply/edit banner, or Escape while that banner is
    /// shown. The host decides what cancelling means (e.g. restore the pre-edit
    /// draft) and then sets `mode = .compose`.
    func composerDidRequestCancelMode()
    /// Up Arrow in an empty composer.
    func composerRequestsEditLastMessage()
    /// Image data pasted or dropped. Not decoded by the composer; the host
    /// enforces the pasted-image budget and may refuse.
    func composerDidPasteImage(data: Data, typeIdentifier: String) -> Bool
    /// File URLs pasted or dropped (already bounded by the composer's per-input
    /// count limit). The host opens them through scoped handles.
    func composerDidReceiveFiles(_ urls: [URL])
    func composerRequestsFileSelection()
    /// A user edit happened (typing, paste, completion, composition update). Not
    /// throttled here; the caller throttles typing events to the server.
    func composerUserDidType()
    /// The user pressed the remove button on an attachment chip.
    func composerDidRemoveAttachment(id: String)
}
