import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI
import TestSupport

@Suite("Emoji and command wire API")
struct EmojiCommandAPITests {
    @Test func requestsAreScopedAndBounded() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url.path.hasSuffix("autocomplete_suggestions") {
                return .json("""
                    [{"Complete":"away","Suggestion":"away","Hint":"","Description":"Set away"}]
                    """)
            }
            return .json("""
                [{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaa","name":"party_parrot"},{"id":"../bad","name":"invalid"}]
                """)
        }
        let factory = DefaultMattermostServiceFactory(budget: .standard, diagnostics: nil, retryPolicy: .never,
                                                      clock: ContinuousClock()) { _ in transport }
        let endpoint = ServerEndpoint(scheme: .https, host: "chat.example.test", port: nil, pathSegments: ["company", "chat"])
        let api = factory.makeClient(for: endpoint, credential: BearerCredential(token: "abcdefghijklmnopqrstuvwxyz", kind: .session)!)
        #expect(try await api.customEmojiList(page: 2, perPage: 60).map(\.name) == ["party_parrot"])
        #expect(transport.requests.last?.queryValue("sort") == "name")
        #expect(transport.requests.last?.queryValue("page") == "2")
        _ = try await api.customEmoji(names: (0..<201).map { "custom_\($0)" })
        let batches = transport.requests.filter { $0.request.method == .post }
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { ($0.bodyJSON as? [String])?.count ?? 201 <= 200 })
        let root = PostID(unchecked: "rrrrrrrrrrrrrrrrrrrrrrrrrr")
        let commands = try await api.commandSuggestions(userInput: "/a", team: TeamID(unchecked: "tttttttttttttttttttttttttt"),
                                                       channel: ChannelID(unchecked: "cccccccccccccccccccccccccc"), rootID: root)
        #expect(commands.first?.complete == "away")
        #expect(transport.requests.last?.queryValue("user_input") == "/a")
        #expect(transport.requests.last?.queryValue("root_id") == root.rawValue)
        #expect(transport.requests.last?.path.hasPrefix("/company/chat/api/v4/") == true)
        await api.shutdown()
    }
}
