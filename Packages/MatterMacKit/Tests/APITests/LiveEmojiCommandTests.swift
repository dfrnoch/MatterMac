import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI

@Suite("Live custom emoji and slash suggestions", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveEmojiCommandTests {
    enum Failure: Error { case credentials }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func endpoints(base: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_ADMIN_PASSWORD"] else { throw Failure.credentials }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let login: LoginResult
        do { login = try await discovery.login(LoginRequest(loginID: "mmadmin", password: password)) }
        catch { await discovery.shutdown(); throw error }
        await discovery.shutdown()
        let api = factory.makeClient(for: endpoint, credential: login.credential)
        var created: CustomEmoji?
        do {
            let team = try #require(try await api.teams().first)
            let channel = try await api.createDirectChannel(with: login.user.id, me: login.user.id)
            let suggestions = try await api.commandSuggestions(userInput: "/a", team: team.id, channel: channel.id, rootID: nil)
            #expect(suggestions.contains { $0.complete == "away" })
            #expect(!(try await api.autocompleteCommands(team: team.id)).isEmpty)
            let name = "mm_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
            let emoji = try await api.createCustomEmoji(name: name, png: png, creator: login.user.id)
            created = emoji
            #expect(try await api.customEmoji(named: name)?.id == emoji.id)
            #expect(try await api.customEmoji(names: [name, "mm_missing_emoji"]).map(\.id) == [emoji.id])
            #expect(try await api.autocompleteCustomEmoji(name: name).contains { $0.id == emoji.id })
            #expect(try await api.customEmojiList(page: 0, perPage: 60).contains { $0.id == emoji.id })
        } catch {
            if let created { try? await api.deleteCustomEmoji(id: created.id) }
            try? await api.logout()
            await api.shutdown()
            throw error
        }
        if let created { try await api.deleteCustomEmoji(id: created.id) }
        try await api.logout()
        await api.shutdown()
    }
}
