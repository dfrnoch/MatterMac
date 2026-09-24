public import Foundation
public import MatterMacModels
public import MattermostAPI

/// A session-only draft: composer text plus selection, kept in RAM while the process
/// runs. Never written to disk, UserDefaults, or server draft endpoints.
public struct Draft: Hashable, Sendable {
    public var text: String
    /// UTF-16 selection range in `text`, so the composer restores the caret exactly.
    public var selectedRange: NSRange
    public var editingPost: PostID?
    public var attachments: [UploadSource]

    public init(text: String, selectedRange: NSRange? = nil, editingPost: PostID? = nil, attachments: [UploadSource] = []) {
        self.text = text
        self.selectedRange = selectedRange ?? NSRange(location: (text as NSString).length, length: 0)
        self.editingPost = editingPost
        self.attachments = attachments
    }

    public var isEmpty: Bool { text.isEmpty && editingPost == nil && attachments.isEmpty }
    public var byteCost: Int { text.utf8.count + (editingPost?.rawValue.utf8.count ?? 0) + attachmentByteCost }
    public var attachmentByteCost: Int { attachments.reduce(0) { $0 + $1.metadataBytes } }
}

/// An immutable view of one retained draft. Its revision prevents an old recovery
/// sheet from discarding a draft that was edited or replaced in the meantime.
public struct DraftRecoveryItem: Identifiable, Sendable {
    public let id: DraftKey
    public let draft: Draft
    public let canDiscard: Bool
    fileprivate let revision: UUID
}

/// Main-actor store of drafts keyed by server, account, channel, and optional thread.
///
/// Accounting goes through `UnsentWorkLedger`; drafts are never evicted. The composer
/// consults `remainingBytes(for:)` before accepting input that would grow a draft.
@MainActor
public final class DraftStore {
    private var drafts: [DraftKey: Draft] = [:]
    private var revisions: [DraftKey: UUID] = [:]
    private var submitting: [DraftKey: UnsentWorkLedger.Reservation] = [:]
    private let ledger: UnsentWorkLedger

    public init(ledger: UnsentWorkLedger) {
        self.ledger = ledger
    }

    public func draft(for key: DraftKey) -> Draft? { drafts[key] }
    public func isSubmitting(_ key: DraftKey) -> Bool { submitting[key] != nil }

    /// Saves (or clears, when empty) a draft. Throws if growing it would exceed the
    /// unsent-text budget; the previously stored draft is then left unchanged.
    public func save(_ draft: Draft, for key: DraftKey) throws(UnsentWorkLedger.Refusal) {
        guard !isSubmitting(key) else { throw .draftBeingSubmitted }
        if draft.isEmpty {
            clear(key)
            return
        }
        try ledger.updateDraft(key, bytes: draft.byteCost)
        if drafts[key] != draft { revisions[key] = UUID() }
        drafts[key] = draft
    }

    public func clear(_ key: DraftKey) {
        guard !isSubmitting(key) else { return }
        drafts[key] = nil
        revisions[key] = nil
        ledger.removeDraft(key)
    }

    /// Pins the draft during actor admission. Navigation may read it, but cannot
    /// overwrite it or count its bytes twice. Edits use the same bounded admission.
    public func takeForSending(_ key: DraftKey) throws(UnsentWorkLedger.Refusal) -> UnsentWorkLedger.Reservation {
        guard !isSubmitting(key) else { throw .draftBeingSubmitted }
        let reservation = try ledger.convertDraftToPending(key, bytes: drafts[key]?.byteCost ?? 0)
        submitting[key] = reservation
        return reservation
    }

    /// Accepted sends leave the reservation owned by Core; accepted edits release
    /// it at the call site. Rejections restore the draft without a budget gap.
    public func finishSending(_ key: DraftKey, reservation: UnsentWorkLedger.Reservation, accepted: Bool) {
        guard submitting[key] == reservation else {
            if !accepted { ledger.release(reservation) }
            return // Explicit sign-out already discarded this draft.
        }
        submitting[key] = nil
        if accepted { drafts[key] = nil; revisions[key] = nil }
        else { ledger.restoreDraft(key, from: reservation) }
    }

    public func remainingBytes(for key: DraftKey) -> Int { ledger.remainingBytes(forDraft: key) }

    /// Keys with non-empty drafts for a scope (used for the quit/sign-out warning).
    public func nonEmptyKeys(for scope: AccountScope) -> [DraftKey] {
        drafts.keys.filter { $0.scope == scope }
    }

    public var hasAnyDraft: Bool { !drafts.isEmpty }

    public var allNonEmptyKeys: [DraftKey] { Array(drafts.keys) }

    /// Bounded by the existing draft budget; attachment copies share their memory
    /// leases. The caller should retain only the latest recovery snapshot.
    public func recoveryDrafts(for scope: AccountScope) -> [DraftRecoveryItem] {
        drafts.compactMap { key, draft in
            guard key.scope == scope, let revision = revisions[key] else { return nil }
            return DraftRecoveryItem(id: key, draft: draft, canDiscard: !isSubmitting(key), revision: revision)
        }.sorted {
            ($0.id.channelID.rawValue, $0.id.rootID?.rawValue ?? "")
                < ($1.id.channelID.rawValue, $1.id.rootID?.rawValue ?? "")
        }
    }

    /// Call only after explicit user confirmation. Comparing the revision and
    /// clearing happen in one main-actor turn, with no admission/accounting gap.
    @discardableResult
    public func discardRecoveryDraft(_ item: DraftRecoveryItem) -> Bool {
        guard item.canDiscard, !isSubmitting(item.id), revisions[item.id] == item.revision else { return false }
        clear(item.id)
        return true
    }

    /// Discards all drafts for a scope. Callers must have obtained explicit user
    /// confirmation first (sign-out with unsent content).
    public func discardAll(for scope: AccountScope) {
        for key in drafts.keys where key.scope == scope {
            drafts[key] = nil
            revisions[key] = nil
            submitting[key] = nil
            ledger.removeDraft(key)
        }
    }
}
