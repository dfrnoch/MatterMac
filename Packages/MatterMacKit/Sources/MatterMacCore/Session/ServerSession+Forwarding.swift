public import Foundation
public import MatterMacModels

/// A bounded preview and canonical link, never a copy of the original attachments.
public struct MessageForwardContext: Sendable {
    public let postID: PostID
    public let channelID: ChannelID
    public let channelName: String
    public let preview: String
    public let permalink: URL
    public let isPrivate: Bool
    public let maximumPostCharacters: Int

    public func message(comment: String) -> String {
        comment.isEmpty ? permalink.absoluteString : comment + "\n" + permalink.absoluteString
    }
}

extension ServerSession {
    public func forwardingContext(_ id: PostID) throws(UserFacingError) -> MessageForwardContext {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let post = store.post(id), !post.isDeleted, !post.type.isSystem,
              directory.memberships[post.channelID] != nil,
              let channel = directory.channels[post.channelID], let team = teamName(for: channel) else {
            throw .notFoundOrInaccessible
        }
        return MessageForwardContext(postID: id, channelID: channel.id, channelName: displayName(of: channel),
            preview: LinkPreview.bounded(post.message, LinkPreview.maximumDescriptionBytes),
            permalink: endpoint.url(path: [team, "pl", id.rawValue]), isPrivate: channel.type != .open,
            maximumPostCharacters: capabilities.maximumPostCharacters ?? 16_383)
    }

    /// Rechecks access and private-source restrictions at admission, even if the
    /// sheet was opened before a membership change. The normal sender owns failures.
    @discardableResult
    public func enqueueForward(_ id: PostID, to channel: ChannelID, comment: String,
                               reservation: UnsentWorkLedger.Reservation) throws -> PendingPostID {
        guard !Task.isCancelled else { throw UserFacingError.cancelled }
        let context = try forwardingContext(id)
        guard !context.isPrivate || channel == context.channelID else { throw UserFacingError.permissionDenied }
        let text = context.message(comment: comment)
        guard text.utf8.count <= reservation.bytes else {
            throw SendRejection.budget(.textBudgetExceeded(limitBytes: deps.budget.unsentText.bytes))
        }
        return try enqueueSend(text: text, channel: channel, rootID: nil, attachments: [], reservation: reservation)
    }
}
