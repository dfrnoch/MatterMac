public import Foundation

/// What the assistant is asked for; providers may pick a faster model for `reply`.
public enum AssistantTask: String, Hashable, Sendable {
    /// A short reply suggestion shown as ghost text in the composer.
    case reply
    /// A summary of a thread, a channel's day, or the whole day.
    case summary
    /// Reading many of the user's own messages to describe how they write. Done
    /// rarely and on request, so providers use their most capable model.
    case style
}

/// One self-contained request: fixed instructions plus the conversation text. The
/// input is message content and is never logged or stored by MatterMac.
public struct AssistantRequest: Hashable, Sendable {
    public var task: AssistantTask
    public var instructions: String
    public var input: String

    public init(task: AssistantTask, instructions: String, input: String) {
        self.task = task
        self.instructions = instructions
        self.input = input
    }
}

/// Failures carry no message text and no provider error bodies.
public enum AssistantError: Error, Hashable, Sendable {
    /// No provider is chosen, or the chosen one lacks its key or script.
    case notConfigured
    /// The provider can't run on this Mac right now (model not downloaded, macOS too old…).
    case unavailable
    /// The provider declined to answer.
    case refused
    /// The conversation doesn't fit the provider even after trimming.
    case inputTooLong
    case rateLimited
    case invalidCredentials
    case network
    /// The provider answered but not usefully (HTTP status or exit code; 0 when unknown).
    case failed(code: Int)
    case timedOut
    case cancelled
}

/// A text-in, text-out model. Implementations live in the platform layer (on-device
/// model, Claude API, a user-installed script) and decide where the text goes.
public protocol AssistantProvider: Sendable {
    /// Characters of `input` one request may carry; longer conversations are split.
    var maximumInputCharacters: Int { get }
    func respond(to request: AssistantRequest) async throws(AssistantError) -> String
}

/// One message as the assistant sees it.
public struct AssistantMessage: Hashable, Sendable {
    public var author: String
    public var isCurrentUser: Bool
    public var date: Date
    public var text: String

    public init(author: String, isCurrentUser: Bool, date: Date, text: String) {
        self.author = author
        self.isCurrentUser = isCurrentUser
        self.date = date
        self.text = text
    }
}

/// A run of messages from one channel, direct message or thread, oldest first.
public struct AssistantConversation: Hashable, Sendable {
    /// "#town-square", "Direct message with Bob", "Thread in #dev".
    public var title: String
    public var messages: [AssistantMessage]

    public init(title: String, messages: [AssistantMessage]) {
        self.title = title
        self.messages = messages
    }
}

/// How the user writes, learned once from their own messages (Settings › Assistant ›
/// Learn from my writing) and given to the fast model with every reply suggestion.
public struct StyleProfile: Hashable, Sendable, Codable {
    /// Longest profile kept; it travels with every suggestion request.
    public static let maximumCharacters = 2_400

    public var text: String
    /// How many of the user's messages it was written from.
    public var messageCount: Int
    public var learnedAt: Date
    /// Display name of the provider that wrote it.
    public var provider: String

    public init(text: String, messageCount: Int, learnedAt: Date, provider: String) {
        self.text = String(text.prefix(Self.maximumCharacters))
        self.messageCount = messageCount
        self.learnedAt = learnedAt
        self.provider = provider
    }
}

/// Where learned style profiles are kept between launches (the app uses the
/// Keychain, one item per account, removed at Sign Out).
public protocol StyleProfileStore: Sendable {
    func profile(for account: CacheAccount) -> StyleProfile?
    func save(_ profile: StyleProfile, for account: CacheAccount)
    func removeProfile(for account: CacheAccount)
}

/// A finished summary and how much of the source it covers.
public struct AssistantSummary: Hashable, Sendable {
    public var text: String
    public var coveredMessages: Int
    /// Messages left out because they did not fit the provider (oldest ones first).
    public var omittedMessages: Int

    public init(text: String, coveredMessages: Int, omittedMessages: Int) {
        self.text = text
        self.coveredMessages = coveredMessages
        self.omittedMessages = omittedMessages
    }
}
