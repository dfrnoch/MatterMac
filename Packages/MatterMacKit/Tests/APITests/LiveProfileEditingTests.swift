import Foundation
import Testing
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("Live own-profile patch and file search", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MM_LIVE_TESTS"] == "1"))
struct LiveProfileEditingTests {
    enum Failure: Error { case missingCredentials, missingTeam }

    @Test(arguments: ["http://localhost:8065", "http://localhost:8066/company/chat", "http://localhost:8067"])
    func roundTrip(base: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["MM_TEST_BOB_PASSWORD"] else { throw Failure.missingCredentials }
        let endpoint = try ServerURLNormalizer.normalize(base, allowInsecureLoopback: true)
        let factory = DefaultMattermostServiceFactory()
        let discovery = factory.discovery(for: endpoint)
        let login: LoginResult
        do { login = try await discovery.login(.init(loginID: "bob", password: password)) }
        catch { await discovery.shutdown(); throw error }
        await discovery.shutdown()
        let api = factory.service(for: endpoint, credential: login.credential)
        let original = login.user
        do {
            let changed = try await api.patchProfile(.init(nickname: "MatterMac profile check"), me: original.id)
            #expect(changed.nickname == "MatterMac profile check")
            #expect(changed.firstName == original.firstName)
            #expect(changed.email == original.email)
            let restored = try await api.patchProfile(.init(nickname: original.nickname), me: original.id)
            #expect(restored.nickname == original.nickname)
            if original.lastPictureUpdate.milliseconds <= 0 {
                try await api.setProfileImage(png: CoreFixtures.png(width: 32, height: 32), me: original.id)
                #expect(try await api.currentUser().lastPictureUpdate.milliseconds > 0)
                try await api.removeProfileImage(me: original.id)
                #expect(try await api.currentUser().lastPictureUpdate.milliseconds < 0)
            }
            let detail = try await api.userStatus(original.id)
            #expect(detail.userID == original.id)
            guard let team = try await api.teams().first(where: { $0.name == "qa" }) else { throw Failure.missingTeam }
            let files = try await api.searchFiles(.init(team: team.id, terms: "in:interop", timeZoneOffsetSeconds: 0, perPage: 20))
            #expect(files.files.count <= 20)
        } catch {
            if original.lastPictureUpdate.milliseconds <= 0 { try? await api.removeProfileImage(me: original.id) }
            _ = try? await api.patchProfile(.init(nickname: original.nickname), me: original.id)
            try? await api.logout()
            await api.shutdown()
            throw error
        }
        try await api.logout()
        await api.shutdown()
    }
}
