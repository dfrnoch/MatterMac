import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import TestSupport

@Suite("Message forwarding", .serialized)
struct ForwardingTests {
    @Test func forwardsAPermalinkAndOptionalCommentWithoutCopyingContentOrFiles() async throws {
        let destination = CoreFixtures.channel(2)
        let h = await SessionHarness(configure: { state in
            state.channels[destination.id] = destination
            state.memberships[destination.id] = ChannelMembership(channelID: destination.id, userID: CoreFixtures.me.id)
        })
        await h.openChannel()
        let source = CoreFixtures.post(1, channel: h.channel.id)
        let context = try await h.session.forwardingContext(source.id)
        #expect(!context.isPrivate)
        #expect(context.permalink == CoreFixtures.endpoint.url(path: ["qa", "pl", source.id.rawValue]))
        for comment in ["", "Worth a look\nSecond line"] {
            let text = context.message(comment: comment)
            let reservation = try h.unsent.convertDraftToPending(nil, bytes: text.utf8.count)
            try await h.session.enqueueForward(source.id, to: destination.id, comment: comment, reservation: reservation)
            #expect(await eventually { await h.session.pending.isEmpty })
            let outgoing = try #require(h.service.withState { $0.createdPosts.last })
            #expect(outgoing.channelID == destination.id)
            #expect(outgoing.rootID == nil && outgoing.fileIDs.isEmpty)
            #expect(outgoing.message == (comment.isEmpty ? context.permalink.absoluteString : comment + "\n" + context.permalink.absoluteString))
            #expect(h.unsent.usage.totalBytes == 0)
        }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test(arguments: [ChannelType.private, .direct, .group])
    func privateMessagesStayInTheirOriginalConversation(type: ChannelType) async throws {
        let channelID = CoreFixtures.channel(1).id
        let h = await SessionHarness(configure: { state in
            state.channels[channelID]?.type = type
        })
        await h.openChannel()
        let source = CoreFixtures.post(1, channel: h.channel.id)
        let context = try await h.session.forwardingContext(source.id)
        #expect(context.isPrivate)
        let reservation = try h.unsent.convertDraftToPending(nil, bytes: context.message(comment: "").utf8.count)
        await #expect(throws: UserFacingError.permissionDenied) {
            try await h.session.enqueueForward(source.id, to: CoreFixtures.channel(2).id, comment: "", reservation: reservation)
        }
        #expect(h.service.withState { $0.createdPosts.isEmpty })
        try await h.session.enqueueForward(source.id, to: h.channel.id, comment: "", reservation: reservation)
        #expect(await eventually { await h.session.pending.isEmpty })
        #expect(h.service.withState { $0.createdPosts.count } == 1)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func admissionRechecksSourceMembershipAndDestinationArchiveState() async throws {
        let destination = CoreFixtures.channel(2)
        let h = await SessionHarness(configure: { state in
            var archived = destination
            archived.deleteAt = MattermostTimestamp(milliseconds: 1)
            state.channels[archived.id] = archived
            state.memberships[archived.id] = ChannelMembership(channelID: archived.id, userID: CoreFixtures.me.id)
        })
        await h.openChannel()
        let source = CoreFixtures.post(1, channel: h.channel.id)
        let context = try await h.session.forwardingContext(source.id)
        let reservation = try h.unsent.convertDraftToPending(nil, bytes: context.message(comment: "").utf8.count)
        await #expect(throws: ServerSession.SendRejection.channelArchived) {
            try await h.session.enqueueForward(source.id, to: destination.id, comment: "", reservation: reservation)
        }
        await h.session.purgeChannel(h.channel.id, reason: nil)
        await #expect(throws: UserFacingError.notFoundOrInaccessible) {
            try await h.session.enqueueForward(source.id, to: destination.id, comment: "", reservation: reservation)
        }
        #expect(h.service.withState { $0.createdPosts.isEmpty })
        h.unsent.release(reservation)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
