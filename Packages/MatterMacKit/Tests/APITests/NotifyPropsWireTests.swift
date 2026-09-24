import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI
import TestSupport

@Suite("Notification property decoding and requests")
struct NotifyPropsWireTests {
    private func user(_ json: String) throws -> User {
        try WireJSON.decoder().decode(UserWire.self, from: Data(json.utf8)).user
    }

    @Test func decodesTheSignedInUsersCompleteMap() throws {
        // Shape observed on 11.11.1 (`GET /users/me`).
        let decoded = try user("""
            {"id":"qnoo9uxat3gubgs5iqfbo74zxe","username":"alice","notify_props":{"channel":"true",
             "channel_mention_auto_follow_threads":"true","comments":"never","desktop":"all","desktop_sound":"false",
             "desktop_threads":"all","email":"true","first_name":"true","mention_keys":"deploy,Release ","push":"mention"}}
            """)
        let props = try #require(decoded.notifyProps)
        #expect(props.isComplete)
        #expect(props.values.count == 10)
        #expect(props.desktop == .all)
        #expect(!props.desktopSound)
        #expect(props.firstNameMentions)
        #expect(props.channelWideMentions)
        #expect(props.mentionKeys == ["deploy", "Release"])
    }

    @Test func sanitizedOrOversizedMapsAreNotEditable() throws {
        #expect(try user(#"{"id":"qnoo9uxat3gubgs5iqfbo74zxe","username":"bob","notify_props":{}}"#).notifyProps == nil)
        #expect(try user(#"{"id":"qnoo9uxat3gubgs5iqfbo74zxe","username":"bob"}"#).notifyProps == nil)
        let long = String(repeating: "k", count: UserNotifyProps.maximumValueBytes + 10)
        let truncated = try #require(try user("""
            {"id":"qnoo9uxat3gubgs5iqfbo74zxe","username":"alice","notify_props":{"desktop":"mention","mention_keys":"\(long)"}}
            """).notifyProps)
        #expect(!truncated.isComplete)
        #expect(truncated.values["mention_keys"] == nil)
        #expect(truncated.desktop == .mention)
    }

    @Test func decodesChannelMemberDesktopAndIgnoreMentions() throws {
        let member = try WireJSON.decoder().decode(ChannelMemberWire.self, from: Data("""
            {"channel_id":"p9bx16xxxxxxxxxxxxxxxxxxxx","user_id":"qnoo9uxat3gubgs5iqfbo74zxe",
             "notify_props":{"desktop":"none","ignore_channel_mentions":"on","mark_unread":"mention","push":"default"}}
            """.utf8)).membership
        #expect(member.desktop == .nothing)
        #expect(member.ignoreChannelMentions == .on)
        #expect(member.markUnread == .mention)
        let defaults = try WireJSON.decoder().decode(ChannelMemberWire.self, from: Data("""
            {"channel_id":"p9bx16xxxxxxxxxxxxxxxxxxxx","user_id":"qnoo9uxat3gubgs5iqfbo74zxe","notify_props":{"desktop":"weird"}}
            """.utf8)).membership
        #expect(defaults.desktop == .default)
        #expect(defaults.ignoreChannelMentions == .default)
    }

    @Test func requestsSendOnlyChangedChannelKeysAndTheCompleteUserMap() async throws {
        let me = UserID(unchecked: "qnoo9uxat3gubgs5iqfbo74zxe")
        let channel = ChannelID(unchecked: "p9bx16xxxxxxxxxxxxxxxxxxxx")
        let server = try await LocalHTTPServer.start { request in
            if request.path.hasSuffix("/patch") {
                return .json(#"{"id":"qnoo9uxat3gubgs5iqfbo74zxe","username":"alice","notify_props":{"desktop":"all","channel":"true"}}"#)
            }
            return .json(#"{"status":"OK"}"#)
        }
        defer { server.stop() }
        let service = DefaultMattermostServiceFactory().service(
            for: server.endpoint(), credential: BearerCredential(token: "notify-test", kind: .session)!)
        try await service.updateChannelNotifyProps(channel, ChannelNotifyPropsChange(desktop: .all, ignoreChannelMentions: .on),
                                                   me: me)
        var props = UserNotifyProps(values: ["desktop": "mention", "channel": "true"])
        props.desktop = .all
        let updated = try await service.patchNotifyProps(props, me: me)
        #expect(updated.notifyProps?.desktop == .all)
        await #expect(throws: APIError.malformedResponse) {
            _ = try await service.patchNotifyProps(UserNotifyProps(values: ["desktop": "all"], isComplete: false), me: me)
        }
        await service.shutdown()

        let requests = server.requests
        #expect(requests.count == 2)
        let channelRequest = try #require(requests.first)
        #expect(channelRequest.method == "PUT")
        #expect(channelRequest.path == "/api/v4/channels/\(channel.rawValue)/members/\(me.rawValue)/notify_props")
        let channelBody = try JSONDecoder().decode([String: String].self, from: channelRequest.body)
        #expect(channelBody == ["channel_id": channel.rawValue, "user_id": me.rawValue, "desktop": "all",
                                "ignore_channel_mentions": "on"])
        let patch = try #require(requests.last)
        #expect(patch.method == "PUT")
        #expect(patch.path == "/api/v4/users/\(me.rawValue)/patch")
        let patchBody = try JSONDecoder().decode([String: [String: String]].self, from: patch.body)
        #expect(patchBody == ["notify_props": ["desktop": "all", "channel": "true"]])
    }
}
