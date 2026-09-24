public import MatterMacModels

/// A bounded snapshot of one unconfirmed send. Upload sources share their existing
/// leases; a recovery view never takes ownership of the send's text reservation.
public struct PendingRecoveryItem: Identifiable, Sendable {
    public let id: PendingPostID
    public let scope: AccountScope
    public let channelID: ChannelID
    public let rootID: PostID?
    public let message: String
    public let attachments: [PendingSend.Attachment]
    public let state: PendingSend.State
    public let canDiscard: Bool
    fileprivate let revision: UInt64
    fileprivate let reservation: UnsentWorkLedger.Reservation

    fileprivate init(_ send: PendingSend, scope: AccountScope) {
        id = send.pendingID
        self.scope = scope
        channelID = send.channelID
        rootID = send.rootID
        message = send.message
        attachments = send.attachments
        state = send.state
        canDiscard = !send.isInFlight
        revision = send.revision
        reservation = send.reservation
    }
}

extension ServerSession {
    /// Includes inaccessible channels and ended authentication sessions, whose
    /// received history has been purged but whose unsent work is still retained.
    public func recoverySends() -> [PendingRecoveryItem] {
        pending.items.map { PendingRecoveryItem($0, scope: scope) }
    }

    /// Explicit user discard only. Rejects stale rows and in-flight operations;
    /// callers refresh their list instead of deleting newly changed work.
    @discardableResult
    public func discardRecoverySend(_ item: PendingRecoveryItem) -> Bool {
        guard item.scope == scope, item.canDiscard,
              let current = pending.item(item.id), !current.isInFlight,
              current.revision == item.revision, current.reservation == item.reservation else { return false }
        return discardSend(item.id) != nil
    }
}
