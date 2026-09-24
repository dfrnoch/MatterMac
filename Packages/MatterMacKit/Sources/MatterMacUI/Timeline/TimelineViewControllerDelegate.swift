public import AppKit
public import MatterMacModels
public import MatterMacCore

/// A user action raised by the timeline. The timeline never performs network work,
/// opens URLs, or mutates state itself; the delegate (a coordinator) decides.
nonisolated public enum TimelineAction: Hashable, Sendable {
    case reply(PostID)
    case addReaction(PostID)
    case toggleReaction(PostID, emojiName: String)
    case edit(PostID)
    case delete(PostID)
    /// Delivered after the timeline has written the message's plain text
    /// (`MessageDocument.plainText`) to the general pasteboard. The delegate may
    /// overwrite the pasteboard (for example with the original markup) or ignore it.
    case copyText(PostID)
    /// Delivered after the timeline has written the URL to the general pasteboard.
    case copyLink(URL)
    case openThread(root: PostID)
    case retrySend(PendingPostID)
    case discardSend(PendingPostID)
    /// The user explicitly activated a link that passed the safe-link policy. The
    /// delegate opens it (for example through the platform's external-navigation
    /// adapter); the timeline never opens links itself.
    case openLink(SafeLink)
    case openFile(FileInfo)
    /// Expand a collapsed long message.
    case expand(PostID)
    /// A `@username` mention was clicked (username without "@").
    case mentionTapped(String)
    /// A `~channel` mention was clicked (channel name without "~").
    case channelMentionTapped(String)
    /// Retry after a failed history page load.
    case retryGap(GapPresentation.Direction)
}

/// An image the timeline wants to display. The delegate's image pipeline downsamples to
/// `TimelineMetrics.avatarSize` / `TimelineMetrics.maximumThumbnailSize` × backing scale.
nonisolated public enum TimelineImageRequest: Hashable, Sendable {
    /// `revision` is the author's `avatarRevision` (server `last_picture_update`).
    case avatar(UserID, revision: Int64)
    case thumbnail(FileID)
}

/// Public layout constants other modules need (image downsampling targets).
nonisolated public enum TimelineMetrics {
    /// Avatar edge length in points.
    public static let avatarSize: CGFloat = 32
    /// Largest thumbnail box in points; images are scaled to fit preserving aspect ratio.
    public static let maximumThumbnailSize = CGSize(width: 360, height: 240)
    /// Distance from the bottom (points) within which the user counts as "at the live edge".
    public static let liveEdgeTolerance: CGFloat = 8
    /// Row-height cache width bucket (points).
    public static let widthBucket: CGFloat = 8
}

/// Delegate of `TimelineViewController`. Lifetime: held weakly by the controller.
///
/// Callbacks can arrive while the controller is applying a snapshot or handling a scroll
/// event. Calling `apply(_:)` from inside a callback is allowed: the snapshot is queued
/// (latest wins) and applied as soon as the current update finishes.
@MainActor
public protocol TimelineViewControllerDelegate: AnyObject {
    /// The older-history gap row came within 1.5 screens of the viewport (fired once per
    /// gap state), or the user pressed "Load older messages".
    func timelineRequestsOlder()
    /// The newer-history gap row came near the bottom, or the user jumped to the latest
    /// messages while the window is not at the live edge.
    func timelineRequestsNewer()
    /// Visible post range changed (coalesced to at most 4 Hz; only while the window is
    /// visible). The delegate applies the read-state policy (app active, conversation
    /// visible) and decides whether to mark anything read.
    func timelineVisibleRangeDidChange(first: PostID?, last: PostID?, isAtLiveEdge: Bool)
    func timeline(perform action: TimelineAction)
    /// Synchronous in-memory cache lookup; must not block or decode on the main actor.
    func timelineImage(for request: TimelineImageRequest) -> NSImage?
    /// The image is needed by a displayed row and was not cached. When it becomes
    /// available, call `TimelineViewController.imageDidBecomeAvailable(_:)`.
    func timelineNeedsImage(_ request: TimelineImageRequest)
    /// No displayed row needs the image any more (rows scrolled away or were reused);
    /// the pipeline may cancel or deprioritize the work. Default: no-op.
    func timelineNoLongerNeedsImage(_ request: TimelineImageRequest)
}

extension TimelineViewControllerDelegate {
    public func timelineNoLongerNeedsImage(_ request: TimelineImageRequest) {}
}
