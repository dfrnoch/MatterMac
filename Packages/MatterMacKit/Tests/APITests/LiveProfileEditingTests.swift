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
        var created: PostID?
        let term = "mattermacfiles" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(term + ".txt")
        defer { try? FileManager.default.removeItem(at: fixture) }
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
            guard let channel = try await api.channels(team: team.id).first(where: { $0.name == "interop" }) else { throw Failure.missingTeam }
            let payload = Data("MatterMac explicit file search test".utf8)
            try payload.write(to: fixture)
            let uploaded = try await api.upload(UploadSource(fileURL: fixture, fileName: term + ".txt", expectedSize: Int64(payload.count)),
                channel: channel.id, clientID: UUID().uuidString, progress: { _ in })
            let post = try await api.createPost(.init(channelID: channel.id, rootID: nil,
                message: "MatterMac file search check", fileIDs: [uploaded.id],
                pendingPostID: PendingPostID(rawValue: "\(original.id.rawValue):\(UUID().uuidString)")!))
            created = post.id
            var found: FileInfo?
            for _ in 0..<20 {
                let files = try await api.searchFiles(.init(team: team.id, terms: term + " in:interop", timeZoneOffsetSeconds: 0, perPage: 20))
                found = files.files.first { $0.id == uploaded.id }
                if found != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let result = try #require(found)
            #expect(result.id == uploaded.id)
            #expect(result.postID == post.id)
            #expect(result.channelID == channel.id)
            #expect(result.size == Int64(payload.count))
        } catch {
            if let created { try? await api.deletePost(created) }
            if original.lastPictureUpdate.milliseconds <= 0 { try? await api.removeProfileImage(me: original.id) }
            _ = try? await api.patchProfile(.init(nickname: original.nickname), me: original.id)
            try? await api.logout()
            await api.shutdown()
            throw error
        }
        if let created { try await api.deletePost(created) }
        try await api.logout()
        await api.shutdown()
    }
}
