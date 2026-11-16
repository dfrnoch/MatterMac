import AppKit
import MatterMacModels
import MatterMacCore

/// Suggested replies for a conversation pane: when the newest message is someone
/// else's and the composer is empty, the chosen assistant drafts a reply that shows as
/// ghost text. Nothing is sent or saved until the user accepts it with Tab.
extension ConversationController {
    /// The newest message a suggestion was requested for, per pane.
    struct SuggestionKey: Hashable {
        let target: TimelineTarget
        let post: PostID
    }

    /// Wait for the timeline to settle (channel switches, bursts of messages).
    static let suggestionDelay: Duration = .milliseconds(1_200)
    /// Older conversations get no automatic suggestion.
    static let suggestionMaximumAge: TimeInterval = 72 * 3_600

    /// Re-evaluates whether a suggestion should be requested, shown or removed.
    func refreshSuggestion() {
        guard let key = suggestionCandidate() else {
            suggestionTask?.cancel()
            suggestionTask = nil
            suggestionKey = nil
            composer.suggestion = nil
            return
        }
        guard key != suggestionKey else { return }
        suggestionTask?.cancel()
        suggestionKey = key
        composer.suggestion = nil
        if let cached = environment.suggestions.value(for: key, scope: scope) {
            composer.suggestion = cached
            return
        }
        guard let provider = environment.assistant, let conversation = suggestionConversation(),
              let reader = assistantReader() else { return }
        let scope = scope
        suggestionTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.suggestionDelay) } catch { return }
            // Still the newest message, still nothing typed.
            guard let self, suggestionKey == key, suggestionCandidate() == key else { return }
            let result: Result<String, AssistantError>
            do throws(AssistantError) {
                result = .success(try await AssistantSummarizer.suggestReply(
                    in: conversation, reader: reader, styleProfile: model?.styleProfile?.text,
                    styleSamples: styleSamples(), provider: provider))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, suggestionKey == key else { return }
            suggestionTask = nil
            switch result {
            case .success(let text):
                environment.suggestions.store(text, for: key, scope: scope)
                if suggestionCandidate() == key { composer.suggestion = text }
            case .failure(let error):
                reportAssistantProblemOnce(error)
            }
        }
    }

    /// The newest message, when a reply to it may be suggested right now.
    private func suggestionCandidate() -> SuggestionKey? {
        let settings = environment.settings
        guard settings.assistantSuggestsReplies, settings.assistant != .off || environment.assistantOverride != nil,
              let model, !model.isDetached, !model.requiresAuthentication, !editingStateDiscarded,
              editingPost == nil, selectedFiles.isEmpty, composer.text.isEmpty, composer.textView.isEditable,
              model.header?.canPost != false, environment.isAppActive,
              let snapshot = currentSnapshot, snapshot.target == target, snapshot.isAtLiveEdge,
              let post = snapshot.items.last(where: { $0.post != nil })?.post,
              let id = post.postID, post.sendState == nil, !post.author.isCurrentUser, !post.author.isBot,
              case .document = post.body,
              Date().timeIntervalSince(post.createdAt.date) < Self.suggestionMaximumAge,
              id != consumedSuggestion else { return nil }
        return SuggestionKey(target: target, post: id)
    }

    /// The user's own recent messages in this conversation, newest first: how they
    /// talk here, next to the learned profile of how they write in general.
    private func styleSamples() -> [String] {
        let own = (currentSnapshot?.items ?? []).reversed().compactMap { item -> String? in
            guard let post = item.post, post.postID != nil, post.author.isCurrentUser, case .document = post.body else {
                return nil
            }
            return TimelineStrings.plainText(of: post.body)
        }
        return Array(own.prefix(12))
    }

    private func suggestionConversation() -> AssistantConversation? {
        guard let snapshot = currentSnapshot else { return nil }
        let posts = snapshot.items.compactMap(\.post).filter { $0.postID != nil }
            .suffix(AssistantSummarizer.replyContextMessages)
        let conversation = Self.assistantConversation(title: assistantTitle(), posts: Array(posts))
        return conversation.messages.isEmpty ? nil : conversation
    }

    /// "#channel", "Direct message with Name" or "Thread in #channel".
    func assistantTitle() -> String {
        let name: String
        if let header = model?.header, header.channelID == target.channelID, !header.displayName.isEmpty {
            switch header.type {
            case .direct: name = String(localized: "Direct message with \(header.displayName)")
            case .group: name = String(localized: "Group message with \(header.displayName)")
            default: name = "#" + header.displayName
            }
        } else {
            name = String(localized: "a conversation")
        }
        if case .thread = target { return String(localized: "Thread in \(name)") }
        return name
    }

    func assistantReader() -> AssistantReader? {
        guard let user = model?.slot.user else { return nil }
        return AssistantReader(name: user.firstName.isEmpty ? user.username : user.firstName, username: user.username)
    }

    /// Displayed posts as the assistant's plain-text conversation (system and deleted
    /// posts are left out; a post with only files says so).
    static func assistantConversation(title: String, posts: [PostPresentation]) -> AssistantConversation {
        let messages = posts.compactMap { post -> AssistantMessage? in
            guard case .document = post.body else { return nil }
            var text = TimelineStrings.plainText(of: post.body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !post.files.isEmpty {
                let files = TimelineStrings.replyContextAttachments(post.files.count)
                text = text.isEmpty ? "[\(files)]" : text + " [\(files)]"
            }
            guard !text.isEmpty else { return nil }
            return AssistantMessage(author: post.author.displayName, isCurrentUser: post.author.isCurrentUser,
                                    date: post.createdAt.date, text: text)
        }
        return AssistantConversation(title: title, messages: messages)
    }

    func composerDidAcceptSuggestion() {
        consumedSuggestion = suggestionKey?.post
    }

    func composerDidDismissSuggestion() {
        consumedSuggestion = suggestionKey?.post
    }

    /// A provider that cannot work (no key, no script, model unavailable) is reported
    /// once per run; transient failures only mean no suggestion this time.
    func reportAssistantProblemOnce(_ error: AssistantError) {
        switch error {
        case .notConfigured, .invalidCredentials, .unavailable:
            guard !environment.assistantProblemReported else { return }
            environment.assistantProblemReported = true
            model?.inlineError = AssistantStrings.describe(error) + " " + String(localized: "Check Settings › Assistant.")
        default:
            break
        }
    }
}

/// Recent reply suggestions by pane and newest message, so returning to a
/// conversation does not ask again. Memory only; bounded.
@MainActor
final class SuggestionCache {
    private struct Key: Hashable {
        let scope: AccountScope
        let key: ConversationController.SuggestionKey
    }

    static let capacity = 48
    private var values: [Key: String] = [:]
    private var order: [Key] = []

    func value(for key: ConversationController.SuggestionKey, scope: AccountScope) -> String? {
        values[Key(scope: scope, key: key)]
    }

    func store(_ text: String, for key: ConversationController.SuggestionKey, scope: AccountScope) {
        let key = Key(scope: scope, key: key)
        if values.updateValue(text, forKey: key) == nil { order.append(key) }
        while order.count > Self.capacity { values[order.removeFirst()] = nil }
    }

    func removeAll() {
        values.removeAll()
        order.removeAll()
    }
}

/// User-facing text for assistant failures (never provider error bodies).
enum AssistantStrings {
    static func describe(_ error: AssistantError) -> String {
        switch error {
        case .notConfigured: String(localized: "The assistant isn’t set up yet.")
        case .unavailable: String(localized: "The on-device model isn’t available on this Mac right now.")
        case .refused: String(localized: "The assistant declined to answer this.")
        case .inputTooLong: String(localized: "This conversation is too long for the assistant.")
        case .rateLimited: String(localized: "The assistant is rate limited. Try again in a moment.")
        case .invalidCredentials: String(localized: "The assistant’s API key was rejected.")
        case .network: String(localized: "The assistant couldn’t be reached.")
        case .failed(let code): code == 0 ? String(localized: "The assistant didn’t return an answer.")
                                          : String(localized: "The assistant failed (\(code)).")
        case .timedOut: String(localized: "The assistant took too long to answer.")
        case .cancelled: String(localized: "Cancelled.")
        }
    }
}
