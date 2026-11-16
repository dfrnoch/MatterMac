import Foundation

public struct ScheduledPostID: MattermostIdentifier {
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A message the server sends later (`/posts/schedule`, licensed servers with
/// `ServiceSettings.ScheduledPosts`). Lives on the server; MatterMac keeps no copy
/// beyond the session's in-memory list.
public struct ScheduledPost: Hashable, Sendable, Identifiable {
    public let id: ScheduledPostID
    public var channelID: ChannelID
    public var rootID: PostID?
    public var message: String
    public var fileIDs: [FileID]
    public var scheduledAt: MattermostTimestamp
    /// Set once the server tried to send it; non-zero with `errorCode` means it failed.
    public var processedAt: MattermostTimestamp
    /// Server reason the send failed (e.g. `channel_archived`), bounded, never shown raw.
    public var errorCode: String?
    public var updateAt: MattermostTimestamp

    public init(id: ScheduledPostID, channelID: ChannelID, rootID: PostID?, message: String, fileIDs: [FileID] = [],
                scheduledAt: MattermostTimestamp, processedAt: MattermostTimestamp = .zero, errorCode: String? = nil,
                updateAt: MattermostTimestamp = .zero) {
        self.id = id
        self.channelID = channelID
        self.rootID = rootID
        self.message = message
        self.fileIDs = fileIDs
        self.scheduledAt = scheduledAt
        self.processedAt = processedAt
        self.errorCode = errorCode
        self.updateAt = updateAt
    }

    /// The server tried and could not send it.
    public var hasFailed: Bool { errorCode != nil }
}
