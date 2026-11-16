import Foundation

/// Runs the assistant's tasks against a provider. Conversations that don't fit one
/// request are trimmed from the oldest side (and the omission reported), and a day too
/// large for one request is condensed per conversation first, then combined.
public enum AssistantSummarizer {
    /// Messages of context for a reply suggestion.
    public static let replyContextMessages = 20
    /// The user's own recent messages shown to the model as a style reference.
    public static let maximumStyleSamples = 20
    /// Longest own message used as a style sample (longer ones are rarely typical chat).
    public static let maximumStyleSampleCharacters = 240
    /// Input characters for a reply suggestion, whatever the provider allows.
    public static let replyContextCharacters = 6_000
    /// Longest suggestion offered as ghost text.
    public static let maximumReplyCharacters = 1_000
    /// Conversations in one day summary; the busiest and most direct come first.
    public static let maximumDayConversations = 15

    /// Messages read when learning the user's style, and the most input used for it.
    public static let styleLearningMessages = 300
    public static let styleLearningCharacters = 60_000
    /// Fewer messages than this say too little about how someone writes.
    public static let minimumStyleMessages = 10

    /// Writes the user's style profile from their own messages (newest first). Returns
    /// the notes and how many messages fitted into the request.
    public static func learnStyle(from messages: [String], reader: AssistantReader,
                                  provider: any AssistantProvider) async throws(AssistantError) -> (text: String, used: Int) {
        let budget = min(provider.maximumInputCharacters, styleLearningCharacters)
        var seen = Set<String>()
        var lines: [String] = []
        var used = 0
        for message in messages {
            var text = message.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
                .trimmingCharacters(in: .whitespaces)
            if text.count > 400 { text = String(text.prefix(400)) + "…" }
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            guard used + text.count + 3 <= budget else { break }
            used += text.count + 3
            lines.append("- " + text)
        }
        guard lines.count >= minimumStyleMessages else { throw .failed(code: 0) }
        let answer = try await provider.respond(to: AssistantRequest(
            task: .style, instructions: AssistantPrompts.style(reader: reader), input: lines.joined(separator: "\n")))
        let text = String(clean(answer).prefix(StyleProfile.maximumCharacters))
        guard !text.isEmpty else { throw .failed(code: 0) }
        return (text, lines.count)
    }

    /// `styleProfile` is the learned description of how the user writes; `styleSamples`
    /// are their own recent messages in this conversation, newest first.
    public static func suggestReply(in conversation: AssistantConversation, reader: AssistantReader,
                                    styleProfile: String? = nil, styleSamples: [String] = [],
                                    provider: any AssistantProvider) async throws(AssistantError) -> String {
        var recent = conversation
        recent.messages = Array(conversation.messages.suffix(replyContextMessages))
        guard let last = recent.messages.last, !last.isCurrentUser else { throw .failed(code: 0) }
        let budget = min(provider.maximumInputCharacters, replyContextCharacters)
        // Style notes and samples may take up to half; the conversation gets the rest.
        var style = ""
        if let profile = styleProfile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty {
            style = "How \(reader.name) writes (notes learned from their messages):\n"
                + String(profile.prefix(budget / 3)) + "\n\n"
        }
        style += styleSection(styleSamples, reader: reader, budget: budget / 6)
        let rendered = AssistantTranscript.render(recent, reader: reader, budget: budget - style.count)
        guard rendered.covered > 0 else { throw .inputTooLong }
        let answer = try await provider.respond(to: AssistantRequest(
            task: .reply, instructions: AssistantPrompts.reply(reader: reader),
            input: style + rendered.text + "\n\nWrite \(reader.name)'s next message, in their voice."))
        let reply = cleanReply(answer)
        guard !reply.isEmpty else { throw .failed(code: 0) }
        return reply
    }

    public static func summarize(thread conversation: AssistantConversation, reader: AssistantReader,
                                 provider: any AssistantProvider) async throws(AssistantError) -> AssistantSummary {
        guard !conversation.messages.isEmpty else { throw .failed(code: 0) }
        let (text, rendered) = try await respond(to: conversation, reader: reader, provider: provider,
                                                 instructions: AssistantPrompts.thread(reader: reader))
        return AssistantSummary(text: text, coveredMessages: rendered.covered, omittedMessages: rendered.omitted)
    }

    public static func summarize(day conversations: [AssistantConversation], reader: AssistantReader,
                                 provider: any AssistantProvider) async throws(AssistantError) -> AssistantSummary {
        let kept = Array(conversations.filter { !$0.messages.isEmpty }.prefix(maximumDayConversations))
        guard !kept.isEmpty else { throw .failed(code: 0) }
        var omitted = conversations.dropFirst(kept.count).reduce(0) { $0 + $1.messages.count }
        let budget = provider.maximumInputCharacters
        let full = kept.map { AssistantTranscript.render($0, reader: reader, budget: .max) }
        let joined = full.map(\.text).joined(separator: "\n\n")
        if joined.count <= budget {
            let text = try await provider.respond(to: AssistantRequest(
                task: .summary, instructions: AssistantPrompts.day(reader: reader, sectionsAreDigests: false),
                input: joined))
            return AssistantSummary(text: clean(text), coveredMessages: full.reduce(0) { $0 + $1.covered },
                                    omittedMessages: omitted)
        }
        // Too much for one request: one digest per conversation, then the briefing.
        var digests: [String] = []
        var covered = 0
        var used = 0
        for conversation in kept {
            if Task.isCancelled { throw .cancelled }
            let (text, rendered) = try await respond(to: conversation, reader: reader, provider: provider,
                                                     instructions: AssistantPrompts.digest(reader: reader))
            omitted += rendered.omitted
            let digest = "Conversation: \(conversation.title)\n\(text)"
            guard text.lowercased().trimmingCharacters(in: .punctuationCharacters) != "nothing" else {
                covered += rendered.covered
                continue
            }
            guard used + digest.count + 2 <= budget else {
                omitted += rendered.covered
                continue
            }
            covered += rendered.covered
            used += digest.count + 2
            digests.append(digest)
        }
        guard !digests.isEmpty else {
            return AssistantSummary(text: String(localized: "Nothing notable happened today."),
                                    coveredMessages: covered, omittedMessages: omitted)
        }
        if Task.isCancelled { throw .cancelled }
        let text = try await provider.respond(to: AssistantRequest(
            task: .summary, instructions: AssistantPrompts.day(reader: reader, sectionsAreDigests: true),
            input: digests.joined(separator: "\n\n")))
        return AssistantSummary(text: clean(text), coveredMessages: covered, omittedMessages: omitted)
    }

    /// One conversation, one request. A provider that still finds the input too long
    /// (its real limit is in tokens) gets one retry with half as much.
    private static func respond(to conversation: AssistantConversation, reader: AssistantReader,
                                provider: any AssistantProvider, instructions: String)
        async throws(AssistantError) -> (String, AssistantTranscript.Rendered) {
        var budget = provider.maximumInputCharacters
        for attempt in 0..<2 {
            let rendered = AssistantTranscript.render(conversation, reader: reader, budget: budget)
            guard rendered.covered > 0 else { throw .inputTooLong }
            do {
                let text = try await provider.respond(to: AssistantRequest(task: .summary, instructions: instructions,
                                                                           input: rendered.text))
                return (clean(text), rendered)
            } catch {
                guard error == .inputTooLong, attempt == 0 else { throw error }
                budget /= 2
            }
        }
        throw .inputTooLong
    }

    /// "Messages NAME wrote recently" as a bulleted list within `budget` characters;
    /// empty when there are no usable samples.
    static func styleSection(_ samples: [String], reader: AssistantReader, budget: Int) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        var used = 0
        for sample in samples {
            let text = sample.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= maximumStyleSampleCharacters, seen.insert(text).inserted else { continue }
            guard lines.count < maximumStyleSamples, used + text.count + 3 <= budget else { break }
            used += text.count + 3
            lines.append("- " + text)
        }
        guard !lines.isEmpty else { return "" }
        return "Messages \(reader.name) wrote recently (style reference, not the reply):\n"
            + lines.joined(separator: "\n") + "\n\n"
    }

    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips wrapping quotes a model sometimes adds, and bounds the length.
    static func cleanReply(_ text: String) -> String {
        var reply = clean(text)
        for (open, close) in [("\"", "\""), ("“", "”"), ("„", "“")] where reply.count >= 2 {
            if reply.hasPrefix(open), reply.hasSuffix(close), !reply.dropFirst().dropLast().contains(open) {
                reply = clean(String(reply.dropFirst().dropLast()))
            }
        }
        if reply.count > maximumReplyCharacters { reply = String(reply.prefix(maximumReplyCharacters)) }
        return reply
    }
}
