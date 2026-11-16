import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("Scheduled messages", .serialized)
struct ScheduledPostSessionTests {
    func later(_ h: SessionHarness, minutes: Int64 = 60) -> MattermostTimestamp {
        MattermostTimestamp(milliseconds: MattermostTimestamp(date: h.wallClock.now()).milliseconds + minutes * 60_000)
    }

    @Test func schedulesListsReschedulesAndDeletes() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let post = try await h.session.scheduleMessage("ship it", channel: h.channel.id, rootID: nil, at: later(h))
        #expect(await h.session.schedulingAvailable == true)
        #expect(try await h.session.scheduledMessages().map(\.id) == [post.id])
        let moved = try await h.session.reschedule(post, at: later(h, minutes: 120))
        #expect(moved.scheduledAt == later(h, minutes: 120))
        try await h.session.deleteScheduled(post.id)
        #expect(try await h.session.scheduledMessages().isEmpty)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func pastTimesAndUnknownChannelsAreRefusedLocally() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        await #expect(throws: UserFacingError.self) {
            try await h.session.scheduleMessage("x", channel: h.channel.id, rootID: nil, at: later(h, minutes: -5))
        }
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.scheduleMessage("x", channel: CoreFixtures.channel(9).id, rootID: nil, at: later(h))
        }
        #expect(!h.service.calls.contains("createScheduledPost"))
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func unlicensedServerIsReportedOnceAsUnsupported() async throws {
        let h = await SessionHarness { state in
            state.scheduledPostsError = .badRequest(ServerErrorInfo(id: "api.scheduled_posts.license_error", statusCode: 400,
                                                                    requestID: nil))
        }
        await h.openChannel()
        await #expect(throws: ServerSession.schedulingUnsupported) { try await h.session.scheduledMessages() }
        #expect(await h.session.schedulingAvailable == false)
        let calls = h.service.calls.filter { $0 == "scheduledPosts" }.count
        await #expect(throws: ServerSession.schedulingUnsupported) {
            try await h.session.scheduleMessage("x", channel: h.channel.id, rootID: nil, at: later(h))
        }
        #expect(h.service.calls.filter { $0 == "scheduledPosts" || $0 == "createScheduledPost" }.count == calls,
                "no further requests once the server said no")
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
