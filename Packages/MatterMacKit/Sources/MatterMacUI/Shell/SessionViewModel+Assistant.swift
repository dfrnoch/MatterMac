import Foundation
public import MatterMacModels
public import MatterMacCore

/// Why a summary could not be produced, as text for the user.
public struct AssistantFailure: Error, Hashable, Sendable {
    public let message: String
}

extension SessionViewModel {
    var assistantReader: AssistantReader {
        let user = slot.user
        return AssistantReader(name: user.firstName.isEmpty ? user.username : user.firstName, username: user.username)
    }

    /// Reads the user's recent messages (up to 300, from their conversations in the
    /// current team) and has the assistant describe how they write. The result is
    /// kept for this account and used for every reply suggestion until forgotten.
    public func learnStyle() {
        guard !isLearningStyle else { return }
        let provider: any AssistantProvider
        switch assistantProvider {
        case .success(let value): provider = value
        case .failure(let failure):
            styleLearningError = failure.message
            return
        }
        isLearningStyle = true
        styleLearningError = nil
        let providerName = app?.environment.settings.assistant.title ?? ""
        styleLearningTask = Task {
            defer { isLearningStyle = false }
            do {
                let messages = try await session.ownRecentMessages(limit: AssistantSummarizer.styleLearningMessages)
                guard messages.count >= AssistantSummarizer.minimumStyleMessages else {
                    styleLearningError = String(localized: "There are too few of your messages to learn from yet.")
                    return
                }
                let learned = try await AssistantSummarizer.learnStyle(from: messages, reader: assistantReader,
                                                                       provider: provider)
                guard !Task.isCancelled, !isDetached else { return }
                let profile = StyleProfile(text: learned.text, messageCount: learned.used, learnedAt: Date(),
                                           provider: providerName)
                styleProfile = profile
                app?.environment.styleProfiles?.save(profile, for: cacheAccount)
                // Earlier suggestions were written without it.
                app?.environment.suggestions.removeAll()
            } catch let error as AssistantError {
                if error != .cancelled { styleLearningError = AssistantStrings.describe(error) }
            } catch let error as UserFacingError {
                if error != .cancelled { styleLearningError = UserFacingErrorText.describe(error) }
            } catch {
                styleLearningError = String(localized: "Your writing style could not be learned.")
            }
        }
    }

    public func forgetStyle() {
        styleLearningTask?.cancel()
        styleProfile = nil
        styleLearningError = nil
        app?.environment.styleProfiles?.removeProfile(for: cacheAccount)
        app?.environment.suggestions.removeAll()
    }

    private var assistantProvider: Result<any AssistantProvider, AssistantFailure> {
        guard !isDetached, !requiresAuthentication else {
            return .failure(AssistantFailure(message: String(localized: "Sign in to use the assistant.")))
        }
        guard let provider = app?.environment.assistant else {
            return .failure(AssistantFailure(message: String(localized: "Choose who answers in Settings › Assistant first.")))
        }
        return .success(provider)
    }

    /// Summarizes a whole thread (up to the newest 200 posts), fetched for this purpose.
    public func summarizeThread(root: PostID) async -> Result<AssistantSummary, AssistantFailure> {
        let provider: any AssistantProvider
        switch assistantProvider {
        case .success(let value): provider = value
        case .failure(let failure): return .failure(failure)
        }
        do {
            let posts = try await session.plainThread(root: root)
            let channels = await session.plainChannels()
            let channel = channels.first { $0.id == posts.first?.channelID }
            let place = channel.map { $0.kind == "direct" || $0.kind == "group" ? $0.displayName : "#" + $0.displayName }
            let conversation = AssistantConversation(
                title: place.map { String(localized: "Thread in \($0)") } ?? String(localized: "Thread"),
                messages: posts.filter { !$0.isSystem }.compactMap { post in
                    var text = post.message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if post.fileCount > 0 { text += text.isEmpty ? "[attachment]" : " [attachment]" }
                    guard !text.isEmpty else { return nil }
                    return AssistantMessage(author: post.displayName, isCurrentUser: post.userID == slot.user.id,
                                            date: post.createdAt.date, text: text)
                })
            return .success(try await AssistantSummarizer.summarize(thread: conversation, reader: assistantReader,
                                                                    provider: provider))
        } catch let error as AssistantError {
            return .failure(AssistantFailure(message: AssistantStrings.describe(error)))
        } catch let error as UserFacingError {
            return .failure(AssistantFailure(message: UserFacingErrorText.describe(error)))
        } catch {
            return .failure(AssistantFailure(message: String(localized: "The summary could not be made.")))
        }
    }

    /// A briefing of today's messages across the busiest conversations.
    public func summarizeToday() async -> Result<AssistantSummary, AssistantFailure> {
        let provider: any AssistantProvider
        switch assistantProvider {
        case .success(let value): provider = value
        case .failure(let failure): return .failure(failure)
        }
        do {
            let conversations = try await session.todayConversations(
                maximumChannels: AssistantSummarizer.maximumDayConversations, perChannel: 60)
            guard !conversations.isEmpty else {
                return .success(AssistantSummary(text: String(localized: "No messages yet today."), coveredMessages: 0,
                                                 omittedMessages: 0))
            }
            return .success(try await AssistantSummarizer.summarize(day: conversations, reader: assistantReader,
                                                                    provider: provider))
        } catch let error as AssistantError {
            return .failure(AssistantFailure(message: AssistantStrings.describe(error)))
        } catch let error as UserFacingError {
            return .failure(AssistantFailure(message: UserFacingErrorText.describe(error)))
        } catch {
            return .failure(AssistantFailure(message: String(localized: "The summary could not be made.")))
        }
    }
}
