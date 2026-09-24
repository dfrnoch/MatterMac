import Foundation
import MatterMacModels
import MattermostAPI
@testable import MattermostRealtime
import Testing
import TestSupport

private typealias F = RealtimeFixtures

private let alice = UserID(rawValue: F.aliceID)!
private let bob = UserID(rawValue: F.bobID)!
private let channel = ChannelID(rawValue: F.channelID)!
private let team = TeamID(rawValue: F.teamID)!
private let post = PostID(rawValue: F.postID)!

private struct DecodeFailure: Error {}

@Suite("Frame classification and event decoding")
struct FrameDecodingTests {
    let decoder = RealtimeFrameDecoder(currentUserID: alice, maximumFrameBytes: 2 * 1_048_576)

    private func event(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws
        -> (RealtimeEvent, Int64?) {
        guard case .event(let event, let seq) = decoder.decode(.text(text)) else {
            Issue.record("expected an event, got \(decoder.decode(.text(text)))", sourceLocation: sourceLocation)
            throw DecodeFailure()
        }
        return (event, seq)
    }

    private func malformed(_ text: String) -> (seq: Int64?, durable: Bool)? {
        guard case .malformedEvent(let seq, let durable) = decoder.decode(.text(text)) else { return nil }
        return (seq, durable)
    }

    // MARK: Classification

    @Test func helloIsClassifiedWithConnectionIdentity() {
        guard case .hello(let hello, let seq) = decoder.decode(.text(F.hello())) else {
            Issue.record("expected hello")
            return
        }
        #expect(seq == 0)
        #expect(hello.connectionID == F.connectionID)
        #expect(hello.userID == alice)
        #expect(hello.serverVersion == F.serverVersion)
    }

    @Test func actionResponsesAreClassifiedByStatus() {
        guard case .response(let ok) = decoder.decode(.text(F.pingReply(seq: 7))) else {
            Issue.record("expected response")
            return
        }
        #expect(ok == ActionResponse(seqReply: 7, isOK: true, statusCode: nil))
        guard case .response(let fail) = decoder.decode(.text(F.failReply(seq: 9, statusCode: 401))) else {
            Issue.record("expected response")
            return
        }
        #expect(fail == ActionResponse(seqReply: 9, isOK: false, statusCode: 401))
        // A response whose seq_reply was omitted (seq <= 0 rejection) is still a response.
        guard case .response(let bare) = decoder.decode(.text("{\"status\":\"FAIL\",\"error\":{\"status_code\":400}}"))
        else {
            Issue.record("expected response")
            return
        }
        #expect(bare.seqReply == nil && bare.statusCode == 400)
    }

    @Test func eventKeyWinsOverStatusKey() throws {
        let text = "{\"event\":\"typing\",\"status\":\"OK\",\"data\":{\"parent_id\":\"\",\"user_id\":\"\(F.bobID)\"},"
            + "\"broadcast\":{\"channel_id\":\"\(F.channelID)\"},\"seq\":4}"
        let (decoded, seq) = try event(text)
        #expect(seq == 4)
        guard case .typing = decoded else {
            Issue.record("expected typing")
            return
        }
    }

    @Test func spacingVariantsDecodeIdentically() throws {
        let precomputed = F.envelope(event: "status_change", data: "{\"status\":\"away\",\"user_id\":\"\(F.aliceID)\"}",
                                     broadcast: .init(userID: F.aliceID), seq: 3, spacing: .precomputed)
        let compact = F.envelope(event: "status_change", data: "{\"status\":\"away\",\"user_id\":\"\(F.aliceID)\"}",
                                 broadcast: .init(userID: F.aliceID), seq: 3, spacing: .compact)
        let pretty = "{\n  \"seq\" : 3,\n  \"event\" : \"status_change\",\n  \"data\" : {\"user_id\" : \"\(F.aliceID)\","
            + " \"status\" : \"away\"}\n}\n"
        for text in [precomputed, compact, pretty] {
            let (decoded, seq) = try event(text)
            #expect(seq == 3)
            guard case .statusChanged(let user, let status) = decoded else {
                Issue.record("expected status change")
                continue
            }
            #expect(user == alice && status == .away)
        }
    }

    @Test func unreadableFrames() {
        for text in ["not json", "[1,2,3]", "{\"seq\":3}", "{\"event\":5,\"seq\":1}", ""] {
            guard case .unreadable = decoder.decode(.text(text)) else {
                Issue.record("expected unreadable for \(text)")
                continue
            }
        }
    }

    @Test func binaryAndOversizedFrames() {
        guard case .binary = decoder.decode(.binary(Data([1, 2, 3]))) else {
            Issue.record("expected binary")
            return
        }
        let small = RealtimeFrameDecoder(currentUserID: alice, maximumFrameBytes: 64)
        guard case .oversized = small.decode(.text(F.posted(seq: 1))) else {
            Issue.record("expected oversized")
            return
        }
    }

    @Test func unknownEventsAreBoundedAndSanitized() throws {
        let (sidebar, seq) = try event(F.sidebarCategoryUpdated(seq: 12))
        #expect(seq == 12)
        guard case .unhandled(let name) = sidebar else {
            Issue.record("expected unhandled")
            return
        }
        #expect(name == "sidebar_category_updated")

        let long = "custom_" + String(repeating: "é", count: 80) + "<script>"
        let (unknown, _) = try event(F.unknown(long, seq: 13))
        guard case .unhandled(let bounded) = unknown else {
            Issue.record("expected unhandled")
            return
        }
        #expect(bounded.utf8.count <= RealtimeFrameDecoder.maximumEventNameBytes)
        #expect(bounded.hasPrefix("custom_"))
        #expect(bounded.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.:-".contains($0)) })
        // v10's dead `channel_viewed` constant is not handled.
        let (viewed, _) = try event(F.unknown("channel_viewed", seq: 14))
        guard case .unhandled = viewed else {
            Issue.record("expected unhandled")
            return
        }
    }

    // MARK: Posts

    @Test func postedDecodesTheNestedPostAndMentions() throws {
        let pending = "\(F.bobID):1790268735216"
        let json = F.postJSON(message: "[fixture] hello @alice", pendingPostID: pending)
        let (decoded, seq) = try event(F.posted(post: json, mentions: [F.aliceID], seq: 2))
        #expect(seq == 2)
        guard case .posted(let posted) = decoded else {
            Issue.record("expected posted")
            return
        }
        #expect(posted.post.id == post)
        #expect(posted.post.channelID == channel)
        #expect(posted.post.userID == bob)
        #expect(posted.post.message == "[fixture] hello @alice")
        #expect(posted.post.pendingPostID?.rawValue == pending)
        #expect(posted.channelType == .open)
        #expect(posted.teamID == team)
        #expect(posted.mentionsCurrentUser)
        #expect(posted.setOnline)
    }

    @Test func postedInDirectChannelWithoutMention() throws {
        let (decoded, _) = try event(F.posted(teamID: "", channelType: "D", mentions: nil, setOnline: false, seq: 5))
        guard case .posted(let posted) = decoded else {
            Issue.record("expected posted")
            return
        }
        #expect(posted.teamID == nil)
        #expect(posted.channelType == .direct)
        #expect(!posted.mentionsCurrentUser)
        #expect(!posted.setOnline)
        // Mentions of someone else do not count.
        let (other, _) = try event(F.posted(mentions: [F.bobID], seq: 6))
        guard case .posted(let otherPosted) = other else { return }
        #expect(!otherPosted.mentionsCurrentUser)
    }

    @Test func editedDeletedAndEphemeralPosts() throws {
        let (edited, _) = try event(F.postEdited(seq: 3))
        guard case .postEdited(let editedPost) = edited else {
            Issue.record("expected edit")
            return
        }
        #expect(editedPost.isEdited)

        // The deletion snapshot has delete_at 0: the event itself is the deletion.
        let (deleted, seq) = try event(F.postDeleted(seq: 19))
        #expect(seq == 19)
        guard case .postDeleted(let deletedPost) = deleted else {
            Issue.record("expected delete")
            return
        }
        #expect(deletedPost.id == post)
        #expect(deletedPost.deleteAt.isZero)

        let (ephemeral, _) = try event(F.ephemeralMessage(seq: 4))
        guard case .ephemeralMessage(let ephemeralPost) = ephemeral else {
            Issue.record("expected ephemeral")
            return
        }
        #expect(ephemeralPost.type == .ephemeral)
    }

    @Test func postUnreadTakesChannelAndTeamFromBroadcast() throws {
        let (decoded, _) = try event(F.postUnread(seq: 9))
        guard case .postUnread(let unread) = decoded else {
            Issue.record("expected post_unread")
            return
        }
        #expect(unread.channelID == channel)
        #expect(unread.teamID == team)
        #expect(unread.postID == post)
        #expect(unread.messageCount == 2 && unread.mentionCount == 1)
        #expect(unread.lastViewedAt.milliseconds == 1_790_268_735_232)
    }

    @Test func reactions() throws {
        let (added, _) = try event(F.reactionAdded(seq: 4))
        guard case .reactionAdded(let reaction) = added else {
            Issue.record("expected reaction_added")
            return
        }
        #expect(reaction.userID == bob && reaction.postID == post && reaction.emojiName == "+1")
        let (removed, _) = try event(F.reactionRemoved(seq: 5))
        guard case .reactionRemoved(let gone) = removed else {
            Issue.record("expected reaction_removed")
            return
        }
        #expect(gone.emojiName == "+1")
    }

    // MARK: Ephemeral signals

    @Test func typingAndStatus() throws {
        let (root, _) = try event(F.typing(seq: 6))
        guard case .typing(let user, let typingChannel, let parent) = root else {
            Issue.record("expected typing")
            return
        }
        #expect(user == bob && typingChannel == channel && parent == nil)
        let (reply, _) = try event(F.typing(parentID: F.postID, seq: 7))
        guard case .typing(_, _, let replyParent) = reply else { return }
        #expect(replyParent == post)

        let (status, _) = try event(F.statusChange(status: "dnd", seq: 8))
        guard case .statusChanged(let statusUser, let presence) = status else {
            Issue.record("expected status")
            return
        }
        #expect(statusUser == alice && presence == .doNotDisturb)
    }

    @Test func channelsViewed() throws {
        let other = F.id("chan", 2)
        let (decoded, _) = try event(F.channelsViewed([F.channelID: 1_790_268_735_644, other: 5], seq: 7))
        guard case .channelsViewed(let times) = decoded else {
            Issue.record("expected viewed")
            return
        }
        #expect(times.count == 2)
        #expect(times[channel]?.milliseconds == 1_790_268_735_644)
        #expect(times[ChannelID(rawValue: other)!]?.milliseconds == 5)
    }

    // MARK: Channels and membership

    @Test func channelLifecycleEvents() throws {
        let (created, _) = try event(F.channelCreated(seq: 1))
        guard case .channelCreated(let createdID, let createdTeam) = created else {
            Issue.record("expected channel_created")
            return
        }
        #expect(createdID == channel && createdTeam == team)

        let (updated, _) = try event(F.channelUpdated(channel: F.channelJSON(header: "new header"), seq: 2))
        guard case .channelUpdated(let updatedChannel) = updated else {
            Issue.record("expected channel_updated")
            return
        }
        #expect(updatedChannel.id == channel && updatedChannel.header == "new header" && updatedChannel.type == .open)

        let (changed, _) = try event(F.channelUpdatedIDOnly(seq: 3))
        guard case .channelChanged(let changedID) = changed else {
            Issue.record("expected shared-channel variant")
            return
        }
        #expect(changedID == channel)

        let (deleted, _) = try event(F.channelDeleted(seq: 4))
        guard case .channelDeleted(let deletedID, let deleteAt) = deleted else {
            Issue.record("expected channel_deleted")
            return
        }
        #expect(deletedID == channel && deleteAt.milliseconds == 1_790_268_800_000)

        let (restored, _) = try event(F.channelRestored(seq: 5))
        guard case .channelRestored(channel) = restored else {
            Issue.record("expected channel_restored")
            return
        }
        let (converted, _) = try event(F.channelConverted(seq: 6))
        guard case .channelConverted(channel) = converted else {
            Issue.record("expected channel_converted")
            return
        }
    }

    @Test func membershipEvents() throws {
        let (member, _) = try event(F.channelMemberUpdated(member: F.channelMemberJSON(markUnread: "mention"), seq: 18))
        guard case .channelMemberUpdated(let membership) = member else {
            Issue.record("expected channel_member_updated")
            return
        }
        #expect(membership.channelID == channel && membership.userID == alice && membership.markUnread == .mention)

        let (direct, _) = try event(F.directAdded(seq: 2))
        guard case .directAdded(channel) = direct else {
            Issue.record("expected direct_added")
            return
        }
        let (group, _) = try event(F.groupAdded(seq: 3))
        guard case .groupAdded(channel) = group else {
            Issue.record("expected group_added")
            return
        }

        let (added, _) = try event(F.userAdded(seq: 4))
        guard case .userAdded(let addedUser, let addedChannel, let addedTeam) = added else {
            Issue.record("expected user_added")
            return
        }
        #expect(addedUser == bob && addedChannel == channel && addedTeam == team)

        let (removedOther, _) = try event(F.userRemovedFromChannel(seq: 5))
        guard case .userRemoved(let removedUser, let removedChannel, let remover) = removedOther else {
            Issue.record("expected user_removed")
            return
        }
        #expect(removedUser == bob && removedChannel == channel && remover == alice)

        let (removedSelf, _) = try event(F.userRemovedSelf(seq: 6))
        guard case .userRemoved(let selfUser, let selfChannel, let selfRemover) = removedSelf else {
            Issue.record("expected user_removed (self)")
            return
        }
        #expect(selfUser == alice && selfChannel == channel && selfRemover == bob)
    }

    // MARK: Teams, users, preferences, threads

    @Test func teamEvents() throws {
        let (joined, _) = try event(F.addedToTeam(seq: 1))
        guard case .addedToTeam(team, alice) = joined else {
            Issue.record("expected added_to_team")
            return
        }
        let (left, _) = try event(F.leaveTeam(seq: 2))
        guard case .leftTeam(team, bob) = left else {
            Issue.record("expected leave_team")
            return
        }
        for name in ["update_team", "restore_team", "update_team_scheme"] {
            let (updated, _) = try event(F.teamEvent(name, team: F.teamJSON(displayName: "QA Renamed"), seq: 3))
            guard case .teamUpdated(let updatedTeam) = updated else {
                Issue.record("expected teamUpdated for \(name)")
                continue
            }
            #expect(updatedTeam.id == team && updatedTeam.displayName == "QA Renamed")
        }
        let (deleted, _) = try event(F.teamEvent("delete_team", seq: 4))
        guard case .teamDeleted(team) = deleted else {
            Issue.record("expected delete_team")
            return
        }
    }

    @Test func userEvents() throws {
        let (updated, _) = try event(F.userUpdated(user: F.userObject(position: "QA"), seq: 16))
        guard case .userUpdated(let user) = updated else {
            Issue.record("expected user_updated")
            return
        }
        #expect(user.id == alice && user.username == "alice" && user.position == "QA")
        let (role, _) = try event(F.userRoleUpdated(seq: 17))
        guard case .userRoleUpdated(alice) = role else {
            Issue.record("expected user_role_updated")
            return
        }
    }

    @Test func preferenceEvents() throws {
        let preferences = [F.preferenceJSON(), F.preferenceJSON(category: "favorite_channel", name: F.channelID,
                                                                value: "true")]
        let (changed, _) = try event(F.preferences("preferences_changed", preferences: preferences, seq: 11))
        guard case .preferencesChanged(let list) = changed else {
            Issue.record("expected preferences_changed")
            return
        }
        #expect(list.count == 2 && list[1].category == "favorite_channel" && list[1].value == "true")
        let (deleted, _) = try event(F.preferences("preferences_deleted", seq: 13))
        guard case .preferencesDeleted(let removed) = deleted else {
            Issue.record("expected preferences_deleted")
            return
        }
        #expect(removed.count == 1)
        let (single, _) = try event(F.preferenceChanged(seq: 14))
        guard case .preferencesChanged(let one) = single else {
            Issue.record("expected preference_changed")
            return
        }
        #expect(one.count == 1 && one[0].name == "use_military_time")
    }

    @Test func threadEvents() throws {
        let (updated, _) = try event(F.threadUpdated(seq: 1))
        guard case .threadUpdated(let threadID, let threadChannel) = updated else {
            Issue.record("expected thread_updated")
            return
        }
        #expect(threadID == post && threadChannel == channel)

        let (readThread, _) = try event(F.threadReadChanged(seq: 2))
        guard case .threadReadChanged(let readID, let readChannel) = readThread else {
            Issue.record("expected thread_read_changed")
            return
        }
        #expect(readID == post && readChannel == channel)

        let (readChannelOnly, _) = try event(F.threadReadChangedChannel(seq: 3))
        guard case .threadReadChanged(nil, let broadcastChannel) = readChannelOnly else {
            Issue.record("expected channel variant")
            return
        }
        #expect(broadcastChannel == channel)

        let teamVariant = F.envelope(event: "thread_read_changed", data: "{}",
                                     broadcast: .init(userID: F.aliceID, teamID: F.teamID), seq: 4)
        let (readTeam, _) = try event(teamVariant)
        guard case .threadReadChanged(nil, nil) = readTeam else {
            Issue.record("expected team variant")
            return
        }

        let (follow, _) = try event(F.threadFollowChanged(following: false, seq: 5))
        guard case .threadFollowChanged(post, false) = follow else {
            Issue.record("expected thread_follow_changed")
            return
        }
    }

    @Test func signalEvents() throws {
        guard case (.emojiAdded, 1) = try event(F.emojiAdded(seq: 1)) else {
            Issue.record("expected emoji_added")
            return
        }
        guard case (.configChanged, 2) = try event(F.configChanged(seq: 2)) else {
            Issue.record("expected config_changed")
            return
        }
        guard case (.licenseChanged, 3) = try event(F.licenseChanged(seq: 3)) else {
            Issue.record("expected license_changed")
            return
        }
    }

    // MARK: Malformed payloads

    @Test func malformedDurableEventsAreFlaggedWithTheirSequence() {
        let badPostString = F.envelope(event: "posted", data: "{\"post\":{\"id\":\"object-not-string\"}}",
                                       broadcast: .init(channelID: F.channelID), seq: 21)
        let invalidPostID = F.posted(post: F.postJSON(id: "../../etc"), seq: 22)
        let missingPost = F.envelope(event: "post_edited", data: "{}", broadcast: .init(channelID: F.channelID), seq: 23)
        let badEmoji = F.reactionAdded(reaction: F.reactionJSON(emojiName: "bad emoji!"), seq: 24)
        let noChannel = F.envelope(event: "user_added", data: "{\"team_id\":\"\",\"user_id\":\"\(F.bobID)\"}",
                                   broadcast: .init(), seq: 25)
        let badMember = F.envelope(event: "channel_member_updated", data: "{\"channelMember\":\"{not json\"}",
                                   broadcast: .init(userID: F.aliceID), seq: 26)
        let badMentions = F.envelope(event: "posted",
                                     data: "{\"post\":\(F.quoted(F.postJSON())),\"mentions\":\"not-a-list\"}",
                                     broadcast: .init(channelID: F.channelID), seq: 27)
        let badTeamID = F.posted(teamID: "bad team id", seq: 28)
        let noData = F.envelope(event: "channel_deleted", data: "null", broadcast: .init(), seq: 29)
        for (text, seq) in [(badPostString, 21), (invalidPostID, 22), (missingPost, 23), (badEmoji, 24),
                            (noChannel, 25), (badMember, 26), (badMentions, 27), (badTeamID, 28), (noData, 29)] {
            let result = malformed(text)
            #expect(result?.seq == Int64(seq), "seq \(seq)")
            #expect(result?.durable == true, "seq \(seq)")
        }
    }

    @Test func malformedEphemeralEventsAreNotDurable() {
        let badTyping = F.envelope(event: "typing", data: "{\"user_id\":\"\"}", broadcast: .init(channelID: F.channelID),
                                   seq: 30)
        let badStatus = F.envelope(event: "status_change", data: "{\"user_id\":\"\(F.aliceID)\"}", broadcast: .init(),
                                   seq: 31)
        #expect(malformed(badTyping)?.durable == false)
        #expect(malformed(badStatus)?.durable == false)
    }
}

@Suite("Outbound action encoding")
struct OutboundActionTests {
    @Test func actionsMatchTheServerSchema() throws {
        let ping = try #require(OutboundAction.ping.encoded(seq: 1))
        let pingObject = try #require(try JSONSerialization.jsonObject(with: Data(ping.utf8)) as? [String: Any])
        #expect(pingObject["seq"] as? Int == 1 && pingObject["action"] as? String == "ping" && pingObject["data"] == nil)

        let typing = try #require(OutboundAction.typing(channel: channel, parent: nil).encoded(seq: 2))
        let typingObject = try #require(try JSONSerialization.jsonObject(with: Data(typing.utf8)) as? [String: Any])
        let typingData = try #require(typingObject["data"] as? [String: Any])
        #expect(typingObject["action"] as? String == "user_typing")
        #expect(typingData["channel_id"] as? String == F.channelID && typingData["parent_id"] as? String == "")

        let active = try #require(OutboundAction.activity(isActive: true).encoded(seq: 3))
        let activeObject = try #require(try JSONSerialization.jsonObject(with: Data(active.utf8)) as? [String: Any])
        let activeData = try #require(activeObject["data"] as? [String: Any])
        #expect(activeObject["action"] as? String == "user_update_active_status")
        #expect(activeData["user_is_active"] as? Bool == true && activeData["manual"] as? Bool == false)

        for text in [ping, typing, active] {
            #expect(text.utf8.count < OutboundAction.serverReadLimit)
        }
    }
}
