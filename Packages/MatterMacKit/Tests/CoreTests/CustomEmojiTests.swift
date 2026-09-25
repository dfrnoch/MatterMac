import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

extension ServerSession {
    func enableCustomEmojiForTest() { capabilities.customEmojiEnabled = true }
}

@Suite("Custom emoji and command completion", .serialized)
struct CustomEmojiTests {
    static let emoji = CustomEmoji(id: CoreFixtures.id("emoji", 1), name: "party_parrot")

    @Test func boundedNamesMissesQueueAndExpiry() {
        var budget = ResourceBudget.standard
        budget.customEmojiNames = 2
        budget.customEmojiMisses = 2
        var store = CustomEmojiStore(budget: budget)
        let now = Date(timeIntervalSince1970: 1_000)
        for index in 0..<10 {
            store.insert(CustomEmoji(id: CoreFixtures.id("emoji", index), name: "custom_\(index)"))
            store.record(requested: ["miss_\(index)"], found: [], now: now)
        }
        #expect(store.knownCount <= 2)
        #expect(store.missCount <= 2)
        #expect(store.peekResolution("miss_9", now: now) == .missing)
        #expect(store.peekResolution("miss_9", now: now.addingTimeInterval(601)) == .unknown)
        store.insert(Self.emoji)
        #expect(store.peek("party_parrot") == Self.emoji)
        for index in 0..<1_000 { store.want("unknown_\(index)", now: now) }
        #expect(store.wanted.count == CustomEmojiStore.maximumWanted)
        let batch = store.takeWanted(limit: 200)
        #expect(batch.count == 200)
        #expect(store.wanted.count == 200)
        store.removeAll()
        #expect(store.knownCount == 0 && store.missCount == 0 && store.wanted.isEmpty)
    }

    @Test func metadataResolvesWithoutLookupAcrossRichMarkup() throws {
        let document = MarkupParser.parse("- :party_parrot:\n\n| emoji |\n| --- |\n| :custom_table: |")
        #expect(document.customEmojiCandidates() == ["party_parrot", "custom_table"])
        var post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        post.customEmojis = [Self.emoji]
        let output = TimelineBuilderInteractionTests().build([post])
        var presentation = try #require(output.items.compactMap(\.post).first)
        presentation.reactions = [ReactionGroup(emojiName: "party_parrot", count: 1, includesCurrentUser: false)]
        var missing: [String] = []
        var seen = Set<String>()
        TimelineBuilder.resolveCustomEmoji(in: &presentation, post: post, candidates: ["party_parrot", "custom_table"],
                                          store: CustomEmojiStore(budget: .standard), now: Date(),
                                          missing: &missing, missingSet: &seen)
        #expect(presentation.customEmoji["party_parrot"] == Self.emoji.id)
        #expect(presentation.reactions.first?.customEmojiID == Self.emoji.id)
        #expect(missing == ["custom_table"])
    }

    @Test func capabilityGatedCompletionAndLookup() async {
        let h = await SessionHarness()
        h.service.withEmojiCommands { $0.emoji = [Self.emoji] }
        #expect(await h.session.completions(trigger: ":", query: "party_parrot", channel: h.channel.id).isEmpty)
        #expect(h.service.withEmojiCommands { $0.autocompleteQueries.isEmpty })
        await h.session.enableCustomEmojiForTest()
        let items = await h.session.completions(trigger: ":", query: "party_parrot", channel: h.channel.id)
        #expect(items.first?.customEmojiID == Self.emoji.id)
        #expect(items.first?.insertion == ":party_parrot:")
        await h.session.wantCustomEmoji(["missing", "party_parrot"])
        await h.session.scheduleEmojiFetch()
        #expect(await eventually { await h.session.customEmoji.peekResolution("missing", now: h.wallClock.now()) == .missing })
        #expect(h.service.withEmojiCommands { $0.nameLookups } == [["missing"]])
        _ = await h.session.shutdown(revokeServerSession: false)
        #expect(await h.session.customEmoji.knownCount == 0)
    }

    @Test func commandsPreserveArgumentsAndThreadScopeAndFallback() async {
        let h = await SessionHarness()
        await h.openChannel()
        h.service.withEmojiCommands {
            $0.commands = [CommandSuggestion(complete: "away", suggestion: "away", description: "Set away")]
            $0.argumentSuggestions = ["status ": [CommandSuggestion(complete: "status away", suggestion: "away")]]
        }
        let root = CoreFixtures.post(1, channel: h.channel.id).id
        let commands = await h.session.completions(trigger: "/", query: "aw", channel: h.channel.id, rootID: root)
        #expect(commands.first?.insertion == "/away")
        let arguments = await h.session.completions(trigger: "/", query: "status a", channel: h.channel.id, rootID: root)
        #expect(arguments.first?.insertion == "/status away")
        #expect(h.service.withEmojiCommands { $0.suggestionRoots } == [root, root])
        h.service.withEmojiCommands { $0.suggestionsError = .notFound(ServerErrorInfo(id: "missing", statusCode: 404, requestID: nil)) }
        #expect(await h.session.completions(trigger: "/", query: "aw", channel: h.channel.id).first?.insertion == "/away")
        #expect(h.service.withEmojiCommands { $0.legacyCommandRequests } == 1)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
