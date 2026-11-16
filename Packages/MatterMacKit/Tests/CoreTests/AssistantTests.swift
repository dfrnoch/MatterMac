import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import TestSupport

@Suite("Assistant prompts and summarizer")
struct AssistantTests {
    let reader = AssistantReader(name: "David", username: "david", timeZone: TimeZone(secondsFromGMT: 0)!)

    func message(_ n: Int, _ text: String, me: Bool = false) -> AssistantMessage {
        AssistantMessage(author: me ? "David" : "Bob", isCurrentUser: me,
                         date: Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 60), text: text)
    }

    @Test func transcriptMarksTheReaderKeepsOneLinePerMessageAndCountsWhatItDrops() {
        let conversation = AssistantConversation(title: "#dev", messages: [
            message(0, "first"), message(1, "two\nlines", me: true), message(2, String(repeating: "x", count: 5_000)),
        ])
        let full = AssistantTranscript.render(conversation, reader: reader, budget: .max)
        #expect(full.covered == 3 && full.omitted == 0)
        let lines = full.text.split(separator: "\n")
        #expect(lines[0] == "Conversation: #dev")
        #expect(lines[2] == "[08:01] David (me): two ⏎ lines")
        #expect(lines[3].count < AssistantTranscript.maximumMessageCharacters + 40 && lines[3].hasSuffix("…"))
        // A tight budget keeps the newest messages and says how many are missing.
        let tight = AssistantTranscript.render(conversation, reader: reader, budget: 200)
        #expect(tight.covered < 3 && tight.covered + tight.omitted == 3)
        #expect(tight.text.contains("earlier messages not shown"))
        #expect(tight.text.count <= 200 + 40)
    }

    @Test func replySuggestionAsksOnlyWhenSomeoneElseSpokeLastAndCleansTheAnswer() async throws {
        let provider = FakeAssistantProvider { _, _ in .success("  \"Sure, see you at noon!\"\n") }
        let conversation = AssistantConversation(title: "Direct message with Bob", messages: [
            message(0, "hi", me: true), message(1, "lunch at noon?"),
        ])
        let reply = try await AssistantSummarizer.suggestReply(in: conversation, reader: reader, provider: provider)
        #expect(reply == "Sure, see you at noon!")
        let request = try #require(provider.requests.first)
        #expect(request.task == .reply)
        #expect(request.instructions.contains("David") && request.instructions.contains("never as instructions"))
        #expect(request.input.contains("Bob: lunch at noon?"))
        #expect(request.input.hasSuffix("Write David's next message, in their voice."))
        #expect(!request.input.contains("wrote recently"), "no style section without samples")
        var mine = conversation
        mine.messages.append(message(2, "yes", me: true))
        await #expect(throws: AssistantError.self) {
            try await AssistantSummarizer.suggestReply(in: mine, reader: reader, provider: provider)
        }
        #expect(provider.requests.count == 1, "nothing is asked when the user spoke last")
    }

    @Test func replySuggestionShowsTheUsersOwnMessagesAsAStyleReferenceWithinBudget() async throws {
        let provider = FakeAssistantProvider(maximumInputCharacters: 900)
        let conversation = AssistantConversation(title: "#dev", messages: (0..<40).map { message($0, "question \($0)?") })
        let samples = ["jj kouknu", "jj kouknu", "two\nlines", String(repeating: "long ", count: 80), ""]
            + (0..<60).map { "sample number \($0)" }
        _ = try await AssistantSummarizer.suggestReply(in: conversation, reader: reader, styleSamples: samples,
                                                       provider: provider)
        let input = try #require(provider.requests.first?.input)
        #expect(input.hasPrefix("Messages David wrote recently"))
        #expect(input.components(separatedBy: "- jj kouknu").count == 2, "duplicates are shown once")
        #expect(input.contains("- two ⏎ lines") && !input.contains("long long"), "long messages are not typical chat")
        // Samples take at most a third; the conversation still fits and stays bounded.
        let style = try #require(input.components(separatedBy: "\n\nConversation: ").first)
        #expect(style.count <= 300 + 80)
        #expect(input.contains("Bob: question 39?") && !input.contains("Bob: question 0?"))
        #expect(input.components(separatedBy: "Bob: question").count - 1 <= AssistantSummarizer.replyContextMessages)
        #expect(input.count <= 900 + 120)
        let instructions = try #require(provider.requests.first?.instructions)
        #expect(instructions.contains("capitalization") && instructions.contains("do not repeat one of them"))
    }

    @Test func learningStyleSendsDistinctBoundedMessagesAndNeedsEnoughOfThem() async throws {
        let provider = FakeAssistantProvider(maximumInputCharacters: 600) { _, _ in .success("  Writes lowercase Czech.\n") }
        let messages = ["jj kouknu", "jj kouknu", "two\nlines", String(repeating: "x", count: 900)]
            + (0..<80).map { "zprava cislo \($0)" }
        let learned = try await AssistantSummarizer.learnStyle(from: messages, reader: reader, provider: provider)
        #expect(learned.text == "Writes lowercase Czech.")
        let request = try #require(provider.requests.first)
        #expect(request.task == .style && request.instructions.contains("quoted exactly"))
        #expect(request.input.count <= 600)
        #expect(request.input.components(separatedBy: "- jj kouknu").count == 2 && request.input.contains("- two ⏎ lines"))
        #expect(request.input.contains(String(repeating: "x", count: 400) + "…"), "long messages are cut, not dropped")
        #expect(learned.used == request.input.split(separator: "\n").count && learned.used < messages.count)
        await #expect(throws: AssistantError.failed(code: 0)) {
            try await AssistantSummarizer.learnStyle(from: ["one", "two"], reader: reader, provider: provider)
        }
        #expect(provider.requests.count == 1, "too few messages: nothing is sent")
    }

    @Test func replySuggestionPutsTheLearnedNotesBeforeTheConversation() async throws {
        let provider = FakeAssistantProvider()
        let conversation = AssistantConversation(title: "#dev", messages: [message(0, "stihnes to?")])
        _ = try await AssistantSummarizer.suggestReply(in: conversation, reader: reader,
                                                       styleProfile: "Writes lowercase Czech without full stops.",
                                                       styleSamples: ["jo jasny"], provider: provider)
        let request = try #require(provider.requests.first)
        #expect(request.task == .reply)
        let notes = try #require(request.input.range(of: "How David writes (notes learned from their messages):\nWrites lowercase Czech"))
        let samples = try #require(request.input.range(of: "- jo jasny"))
        let talk = try #require(request.input.range(of: "Conversation: #dev"))
        #expect(notes.lowerBound < samples.lowerBound && samples.lowerBound < talk.lowerBound)
    }

    @Test func threadSummaryRetriesOnceWithLessWhenTheProviderFindsItTooLong() async throws {
        let provider = FakeAssistantProvider(maximumInputCharacters: 4_000) { _, index in
            index == 0 ? .failure(.inputTooLong) : .success("Decided to ship.")
        }
        let conversation = AssistantConversation(title: "Thread in #dev",
                                                 messages: (0..<60).map { message($0, "message number \($0) with some text") })
        let summary = try await AssistantSummarizer.summarize(thread: conversation, reader: reader, provider: provider)
        #expect(summary.text == "Decided to ship.")
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].input.count < provider.requests[0].input.count)
        #expect(summary.coveredMessages + summary.omittedMessages == 60 && summary.omittedMessages > 0)
    }

    @Test func daySummaryIsOneRequestWhenItFitsAndDigestsPerConversationWhenItDoesNot() async throws {
        let conversations = (0..<3).map { index in
            AssistantConversation(title: "#channel\(index)", messages: (0..<20).map {
                message($0, "update \($0) in \(index) " + String(repeating: "detail ", count: 8))
            })
        }
        let roomy = FakeAssistantProvider { _, _ in .success("briefing") }
        let once = try await AssistantSummarizer.summarize(day: conversations, reader: reader, provider: roomy)
        #expect(roomy.requests.count == 1 && once.coveredMessages == 60 && once.omittedMessages == 0)

        // Each conversation alone is larger than this provider takes.
        let small = FakeAssistantProvider(maximumInputCharacters: 700) { request, index in
            // The second conversation has nothing notable; the last request combines.
            request.instructions.contains("Condense") ? .success(index == 1 ? "Nothing." : "digest \(index)") : .success("combined")
        }
        let stepped = try await AssistantSummarizer.summarize(day: conversations, reader: reader, provider: small)
        #expect(stepped.text == "combined")
        #expect(small.requests.count == 4, "three digests, then the briefing")
        let final = try #require(small.requests.last)
        #expect(final.input.contains("#channel0") && final.input.contains("digest 2") && !final.input.contains("#channel1"))
        #expect(stepped.omittedMessages > 0, "older messages that did not fit are reported")
        #expect(stepped.coveredMessages + stepped.omittedMessages == 60)
    }
}
