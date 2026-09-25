import Foundation
import ImageIO
import Testing
import MatterMacModels
import MattermostAPI
import TestSupport
@testable import MatterMacCore

@Suite("Own profile changes", .serialized)
struct ProfileEditingTests {
    @Test func updatesOnlyRequestedFieldsAndPreservesIdentity() async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        let user = try await h.session.updateProfile(.init(nickname: "New nickname"))
        #expect(user.nickname == "New nickname")
        #expect(user.username == CoreFixtures.me.username)
        #expect(await h.session.directory.peekUser(user.id)?.nickname == "New nickname")
        _ = try await h.session.updateProfile(.init())
        #expect(h.service.withProfile { $0.patches.count } == 1)
        await #expect(throws: UserFacingError.self) { try await h.session.setOwnStatus(.outOfOffice) }
        h.service.withProfile { $0.patchError = .unexpectedStatus(409) }
        await #expect(throws: UserFacingError.profileFieldLocked) { try await h.session.updateProfile(.init(firstName: "Managed")) }
        #expect(await h.session.directory.peekUser(user.id)?.firstName == user.firstName)
    }
    @Test func picturesRefreshDirectoryAndFailuresPreserveRevision() async throws {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        let user = try await h.session.updateProfilePicture(Data([137, 80, 78, 71]))
        #expect(user.lastPictureUpdate.milliseconds > 0)
        #expect(await h.session.directory.peekUser(user.id)?.lastPictureUpdate == user.lastPictureUpdate)
        let removed = try await h.session.updateProfilePicture(nil)
        #expect(removed.lastPictureUpdate.milliseconds < 0)
        h.service.withProfile { $0.imageError = .unexpectedStatus(409) }
        await #expect(throws: UserFacingError.profileFieldLocked) { try await h.session.updateProfilePicture(nil) }
        #expect(await h.session.directory.peekUser(user.id)?.lastPictureUpdate == removed.lastPictureUpdate)
    }

    @Test func fileSearchBoundsResultsAndClearsOnNewMode() async {
        var budget = ResourceBudget()
        budget.searchResults.count = 2
        let h = await SessionHarness(budget: budget)
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        h.service.withProfile { state in
            state.files = (0..<3).map { FileInfo(id: FileID(unchecked: CoreFixtures.id("file", $0)),
                channelID: h.channel.id, name: "report \($0)", miniPreview: Data(repeating: 1, count: 20)) }
        }
        await h.session.searchFiles("report")
        _ = await eventually { await h.session.searchState.state == .results }
        #expect(await h.session.searchState.files.count == 2)
        #expect(await h.session.searchState.isTruncated)
        #expect(await h.session.searchState.files.allSatisfy { $0.miniPreview == nil })
        await h.session.search("other")
        #expect(await h.session.searchState.files.isEmpty)
    }

    @Test func picturePreparationCropsAndRejectsOversizedSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try CoreFixtures.png(width: 128, height: 64).write(to: url)
        let png = try await ProfilePicture.prepare(url)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64)
        #expect(image.height == 64)
        var budget = ResourceBudget.standard
        budget.profilePictureSourceBytes = 1
        await #expect(throws: UserFacingError.fileUnavailable) { try await ProfilePicture.prepare(url, budget: budget) }
    }

    @Test func revokedChannelCannotReturnThroughLateFilePage() async {
        let h = await SessionHarness()
        _ = await eventually { await h.session.directory.channels[h.channel.id] != nil }
        let publicChannel = CoreFixtures.channel(2).id
        let files = (0..<20).map { FileInfo(id: FileID(unchecked: CoreFixtures.id("file", $0)),
            channelID: $0 == 0 ? h.channel.id : publicChannel, name: "report \($0)") }
        let started = Gate(), response = Gate(), finished = Gate()
        h.service.withProfile { state in
            state.fileSearchHandler = { query in
                if query.page == 0 { return FileSearchPage(files: files) }
                await started.open()
                await response.wait() // Deliberately ignores task cancellation.
                await finished.open()
                return FileSearchPage(files: [files[0]])
            }
        }
        await h.session.searchFiles("report")
        #expect(await eventually { await h.session.searchState.files.count == 20 })
        await h.session.loadMoreSearchResults()
        await started.wait()
        await h.session.purgeChannel(h.channel.id, reason: nil)
        await response.open()
        await finished.wait()
        #expect(await eventually { await !h.session.isRunning(.search) })
        #expect(await h.session.searchState.files.map(\.id) == files.dropFirst().map(\.id))
        #expect(await h.session.searchState.state == .results)
        #expect(await h.session.searchState.canLoadMore == false)
        // Public results need not belong to a joined channel. A fresh authorized
        // search still accepts them; no blanket membership filter is introduced.
        await h.session.searchFiles("report")
        #expect(await eventually { await h.session.searchState.files.count == 20 })
    }

}
