import Foundation
import MatterMacModels
import MatterMacCore

/// User-visible timeline strings and formatting. Times are absolute ("14:05"); date
/// separators carry the full date, so no relative-time refresh timer is needed.
enum TimelineStrings {
    static let deletedMessage = String(localized: "(message deleted)")
    static let edited = String(localized: "(edited)")
    static let bot = String(localized: "BOT")
    static let showMore = String(localized: "Show more")
    static let repliedToThread = String(localized: "Replied to a thread")
    static let newMessagesSeparator = String(localized: "New messages")
    static let loadOlder = String(localized: "Load older messages")
    static let loadNewer = String(localized: "Load newer messages")
    static let loadingOlder = String(localized: "Loading older messages…")
    static let loadingNewer = String(localized: "Loading newer messages…")
    static let retry = String(localized: "Retry")
    static let discard = String(localized: "Discard")
    static let jumpToLatest = String(localized: "Jump to latest")
    static let outcomeUnknown = String(localized: "This message may have been sent. Retrying could create a duplicate.")
    static let sending = String(localized: "Sending…")
    static let queued = String(localized: "Waiting to send…")
    static let pinned = String(localized: "Pinned")
    static let saved = String(localized: "Saved")

    // Message actions (context menu, hover bar "More", accessibility custom actions)
    static let actionReplyInThread = String(localized: "Reply in Thread")
    static let actionReply = String(localized: "Reply")
    static let actionAddReaction = String(localized: "Add Reaction…")
    static let actionMarkUnread = String(localized: "Mark as Unread")
    static let actionSave = String(localized: "Save Message")
    static let actionUnsave = String(localized: "Remove from Saved")
    static let actionPin = String(localized: "Pin to Channel")
    static let actionUnpin = String(localized: "Unpin from Channel")
    static let actionCopyLink = String(localized: "Copy Link")
    static let actionCopyText = String(localized: "Copy Text")
    static let actionEdit = String(localized: "Edit Message")
    static let actionDelete = String(localized: "Delete Message…")
    static let actionMore = String(localized: "More Actions")
    static let actionOpenLink = String(localized: "Open Link")
    static let messageActions = String(localized: "Message actions")
    static let reactedByYou = String(localized: "You reacted")

    static func actionViewProfile(_ name: String) -> String { String(localized: "View Profile of \(name)") }

    static func quickReaction(_ name: String) -> String { String(localized: "React with :\(name):") }

    /// "alice, bob and 3 others reacted with :+1:" (at most the names the builder resolved).
    static func reactors(_ reaction: ReactionGroup) -> String {
        let emoji = ":" + reaction.emojiName + ":"
        var names = reaction.reactorNames
        if names.isEmpty, reaction.includesCurrentUser { names = [String(localized: "You")] }
        guard !names.isEmpty else {
            return reaction.count == 1 ? String(localized: "1 person reacted with \(emoji)")
                                       : String(localized: "\(reaction.count) people reacted with \(emoji)")
        }
        let others = max(0, reaction.count - names.count)
        if others == 0 {
            if names.count == 1 { return String(localized: "\(names[0]) reacted with \(emoji)") }
            let head = names.dropLast().joined(separator: ", ")
            return String(localized: "\(head) and \(names[names.count - 1]) reacted with \(emoji)")
        }
        let head = names.joined(separator: ", ")
        return others == 1 ? String(localized: "\(head) and 1 other reacted with \(emoji)")
                           : String(localized: "\(head) and \(others) others reacted with \(emoji)")
    }

    static func linkPreviewAccessibility(_ preview: LinkPreview) -> String {
        let site = preview.siteName.isEmpty ? preview.host : preview.siteName
        let title = preview.title.isEmpty ? preview.link.url.absoluteString : preview.title
        return String(localized: "Link preview: \(title), \(site)")
    }

    static func editedAt(_ timestamp: MattermostTimestamp) -> String {
        String(localized: "Edited \(fullDateTime(timestamp))")
    }

    // Menu titles
    static let menuReply = String(localized: "Reply")
    static let menuAddReaction = String(localized: "Add Reaction…")
    static let menuCopyText = String(localized: "Copy Text")
    static let menuCopyLink = String(localized: "Copy Link")
    static let menuEdit = String(localized: "Edit Message")
    static let menuDelete = String(localized: "Delete Message…")
    static let menuRetrySend = String(localized: "Retry Sending")
    static let menuDiscardSend = String(localized: "Discard Message")
    static let menuOpenLink = String(localized: "Open Link")
    static let menuCopyLinkAddress = String(localized: "Copy Link Address")
    static let menuCopySelection = String(localized: "Copy")
    static let menuOpenThread = String(localized: "Open Thread")

    static func uploading(completed: Int, total: Int) -> String {
        String(localized: "Uploading files (\(completed) of \(total))…")
    }

    static func notSent(_ error: UserFacingError) -> String {
        String(localized: "Not sent. \(describe(error))")
    }

    static func replies(_ count: Int) -> String {
        count == 1 ? String(localized: "1 reply") : String(localized: "\(count) replies")
    }

    static func reactions(_ count: Int) -> String {
        count == 1 ? String(localized: "1 reaction") : String(localized: "\(count) reactions")
    }

    static func newMessagesButton(_ count: Int) -> String {
        count == 1 ? String(localized: "1 new message") : String(localized: "\(count) new messages")
    }

    static func moreReactions(_ count: Int) -> String { String(localized: "+\(count) more") }
    static func moreFiles(_ count: Int) -> String { String(localized: "+\(count) more files") }

    static func historyStart(_ name: String) -> String {
        String(localized: "This is the beginning of \(name).")
    }

    static func loadFailed(_ direction: GapPresentation.Direction, _ error: UserFacingError) -> String {
        switch direction {
        case .older: String(localized: "Couldn’t load older messages. \(describe(error))")
        case .newer: String(localized: "Couldn’t load newer messages. \(describe(error))")
        }
    }

    static func unreadBoundaryAccessibility(_ count: Int) -> String {
        count > 0 ? String(localized: "New messages: \(count) unread") : newMessagesSeparator
    }

    static func reactionAccessibility(emoji: String, name: String, count: Int, includesYou: Bool) -> String {
        includesYou
            ? String(localized: "\(name) reaction, \(count), including you")
            : String(localized: "\(name) reaction, \(count)")
    }

    static func fileAccessibility(name: String, size: String) -> String {
        String(localized: "File \(name), \(size)")
    }

    static func imageAccessibility(name: String) -> String {
        String(localized: "Image \(name)")
    }

    static let openImage = String(localized: "Open Image")
    static let saveAttachment = String(localized: "Save Attachment…")

    static func avatarAccessibility(name: String) -> String {
        String(localized: "Profile picture of \(name)")
    }

    static func sendStateDescription(_ state: SendState) -> String {
        switch state {
        case .queued: queued
        case .uploading(let completed, let total): uploading(completed: completed, total: total)
        case .sending: sending
        case .failed(let error): notSent(error)
        case .outcomeUnknown: outcomeUnknown
        }
    }

    /// Content-free explanation of a typed error. Never includes server-provided text.
    static func describe(_ error: UserFacingError) -> String {
        switch error {
        case .offline: String(localized: "You appear to be offline.")
        case .timedOut: String(localized: "The server took too long to respond.")
        case .serverUnreachable: String(localized: "The server can’t be reached.")
        case .tlsFailure: String(localized: "A secure connection couldn’t be established.")
        case .authenticationRequired: String(localized: "Please sign in again.")
        case .invalidCredentials: String(localized: "The credentials were rejected.")
        case .mfaRequired: String(localized: "A multi-factor authentication code is required.")
        case .invalidMFACode: String(localized: "The authentication code was rejected.")
        case .accountLocked: String(localized: "The account is locked.")
        case .loginMethodDisabled: String(localized: "This sign-in method is disabled on the server.")
        case .permissionDenied: String(localized: "You don’t have permission to do that.")
        case .notFoundOrInaccessible: String(localized: "It no longer exists or you can’t access it.")
        case .rateLimited(let seconds):
            if let seconds { String(localized: "The server is rate limiting requests. Try again in \(seconds) s.") }
            else { String(localized: "The server is rate limiting requests.") }
        case .payloadTooLarge: String(localized: "It is larger than the server allows.")
        case .messageTooLong(let limit): String(localized: "The message is longer than \(limit) characters.")
        case .unsupportedCapability: String(localized: "The server doesn’t support this.")
        case .malformedServerData: String(localized: "The server sent data MatterMac couldn’t read.")
        case .serverError(let status): String(localized: "The server reported an error (\(status)).")
        case .budgetExceeded: String(localized: "A memory limit for unsent content was reached.")
        case .cancelled: String(localized: "The operation was cancelled.")
        case .fileUnavailable: String(localized: "A file is no longer available.")
        case .commandNotFound: String(localized: "The server doesn’t recognize that command.")
        case .commandOutcomeUnknown: String(localized: "The command’s outcome is unknown.")
        case .profileFieldLocked: UserFacingErrorText.describe(error)
        case .unknown: String(localized: "An unknown error occurred.")
        }
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// The server's `use_military_time` preference of the visible account; `nil`
    /// follows the Mac's time format. Set through `TimelineViewController.uses24HourClock`.
    static var clockOverride: Bool?

    private static let twelveHourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("hmm")
        return formatter
    }()

    private static let twentyFourHourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter
    }()

    static func time(_ timestamp: MattermostTimestamp) -> String {
        let formatter = clockOverride.map { $0 ? twentyFourHourFormatter : twelveHourFormatter } ?? timeFormatter
        return formatter.string(from: timestamp.date)
    }

    private static let longFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter
    }()

    /// Full date and time with seconds, for the timestamp tooltip.
    static func longDateTime(_ timestamp: MattermostTimestamp) -> String { longFormatter.string(from: timestamp.date) }
    static func fullDateTime(_ timestamp: MattermostTimestamp) -> String { fullFormatter.string(from: timestamp.date) }
    static func date(_ date: Date) -> String { dateFormatter.string(from: date) }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    /// Plain text of a message body for copy and accessibility.
    static func plainText(of body: MessageBody) -> String {
        switch body {
        case .document(let document, _): document.plainText
        case .system(let text): text
        case .deleted: deletedMessage
        case .unsupported(let summary, let fallback): fallback.isEmpty ? summary : summary + "\n" + fallback
        }
    }

    /// Characters of message text included in a row's accessibility label; the full text
    /// stays reachable through the body text view.
    static let accessibilityTextLimit = 600

    /// "author, time, message text, N reactions, N replies, send state".
    static func accessibilityLabel(for post: PostPresentation) -> String {
        var parts: [String] = [post.author.displayName, fullDateTime(post.createdAt)]
        var text = plainText(of: post.body)
        if text.count > accessibilityTextLimit { text = String(text.prefix(accessibilityTextLimit)) + "…" }
        parts.append(text)
        if post.isEdited { parts.append(edited) }
        if post.isPinned { parts.append(pinned) }
        if post.isSaved { parts.append(saved) }
        if let preview = post.linkPreview { parts.append(linkPreviewAccessibility(preview)) }
        if !post.files.isEmpty {
            parts.append(post.files.count == 1 ? String(localized: "1 attachment")
                                               : String(localized: "\(post.files.count) attachments"))
        }
        let reactionTotal = post.reactions.reduce(0) { $0 + max($1.count, 0) }
        if reactionTotal > 0 { parts.append(reactions(reactionTotal)) }
        if post.replyCount > 0 { parts.append(replies(post.replyCount)) }
        if let state = post.sendState { parts.append(sendStateDescription(state)) }
        return parts.joined(separator: ", ")
    }
}
