import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI
import TestSupport

/// Wire decoding and request formation for sidebar categories, browsing, channel
/// creation, group messages, membership and user search.
@Suite("Sidebar and directory endpoints")
struct SidebarAPITests {
    static let me = "qnoo9uxat3gubgs5iqfbo74zxe"
    static let team = "xzywwxr1b3ymdqdimz4kjyuhhw"
    static let channelA = "aaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let channelB = "bbbbbbbbbbbbbbbbbbbbbbbbbb"
    static let custom = "cccccccccccccccccccccccccc"

    static func categoryJSON(_ id: String, type: String, name: String, sorting: String = "", collapsed: Bool = false,
                             channels: [String]) -> String {
        let list = channels.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            {"id":"\(id)","user_id":"\(me)","team_id":"\(team)","sort_order":10,"sorting":"\(sorting)","type":"\(type)",
             "display_name":"\(name)","muted":false,"collapsed":\(collapsed),"channel_ids":[\(list)]}
            """
    }

    private func client(_ responder: @escaping FakeHTTPTransport.Responder) -> (MattermostHTTPClient, FakeHTTPTransport) {
        let transport = FakeHTTPTransport(responder: responder)
        let factory = DefaultMattermostServiceFactory(budget: .standard, diagnostics: nil, retryPolicy: .never,
                                                      clock: ContinuousClock()) { _ in transport }
        let endpoint = ServerEndpoint(scheme: .https, host: "chat.example.test", port: nil, pathSegments: ["company", "chat"])
        return (factory.makeClient(for: endpoint, credential: BearerCredential(token: "abcdefghijklmnopqrstuvwxyz", kind: .session)!),
                transport)
    }

    @Test func categoriesFollowServerOrderAndKeepUnknownValues() throws {
        let favorites = "favorites_\(Self.me)_\(Self.team)"
        let dms = "direct_messages_\(Self.me)_\(Self.team)"
        let json = """
            {"categories":[
              \(Self.categoryJSON(favorites, type: "favorites", name: "Favorites", channels: [])),
              \(Self.categoryJSON(dms, type: "direct_messages", name: "Direct Messages", sorting: "recent", channels: [Self.channelB])),
              \(Self.categoryJSON(Self.custom, type: "future_kind", name: "Work", sorting: "weird", collapsed: true,
                                  channels: [Self.channelA, Self.channelA, "../bad"])),
              {"id":"not valid!","user_id":"\(Self.me)","team_id":"\(Self.team)","type":"custom","channel_ids":[]}
            ],"order":["\(Self.custom)","\(dms)","missing"]}
            """
        let list = try WireJSON.decoder().decode(OrderedSidebarCategoriesWire.self, from: Data(json.utf8)).categories
        // `order` first, then categories missing from it; the invalid id is dropped.
        #expect(list.map(\.id.rawValue) == [Self.custom, dms, favorites])
        let work = list[0]
        #expect(work.kind == .unknown("future_kind"))
        #expect(work.kind.wireValue == "future_kind")
        #expect(work.sorting.wireValue == "weird")
        #expect(work.effectiveSorting == .manual)
        #expect(work.isCollapsed)
        #expect(work.channelIDs.map(\.rawValue) == [Self.channelA])
        #expect(work.droppedChannelIDs == 1)
        #expect(list[1].effectiveSorting == .recent)
        #expect(list[1].kind == .directMessages)
    }

    @Test func collapsingSendsTheWholeCategoryAndRefusesDroppedChannels() async throws {
        let id = "channels_\(Self.me)_\(Self.team)"
        let (api, transport) = client { request in
            if request.method == .put {
                return .json(String(decoding: request.body ?? Data(), as: UTF8.self))
            }
            return .json(Self.categoryJSON(id, type: "channels", name: "Channels", sorting: "alpha", channels: [Self.channelA]))
        }
        var category = try await api.sidebarCategory(SidebarCategoryID(unchecked: id), team: TeamID(unchecked: Self.team),
                                                     me: UserID(unchecked: Self.me))
        category.isCollapsed = true
        let saved = try await api.updateSidebarCategory(category)
        #expect(saved.isCollapsed)
        let put = try #require(transport.requests.last)
        #expect(put.request.method == .put)
        #expect(put.path == "/company/chat/api/v4/users/\(Self.me)/teams/\(Self.team)/channels/categories/\(id)")
        let body = try #require(put.bodyJSON as? [String: Any])
        #expect(body["collapsed"] as? Bool == true)
        #expect(body["sorting"] as? String == "alpha")
        #expect(body["type"] as? String == "channels")
        #expect(body["channel_ids"] as? [String] == [Self.channelA])
        #expect(body["user_id"] as? String == Self.me)

        category.droppedChannelIDs = 1
        let before = transport.requestCount
        await #expect(throws: APIError.self) { _ = try await api.updateSidebarCategory(category) }
        #expect(transport.requestCount == before)
        await api.shutdown()
    }

    @Test func browsingPathsAndEmptyArchivedList() async throws {
        let (api, transport) = client { request in
            let path = request.url.path(percentEncoded: true)
            if path.hasSuffix("/channels/deleted") {
                return .appError(404, id: "app.channel.get_deleted.missing.app_error")
            }
            if path.hasSuffix("/stats/member_count") {
                return .json(#"{"\#(Self.channelA)":12,"bad id":3}"#)
            }
            if path.hasSuffix("/teams/unread") {
                return .json(#"[{"team_id":"\#(Self.team)","msg_count":4,"mention_count":2,"msg_count_root":3,"mention_count_root":1}]"#)
            }
            return .json("[" + FrameJSON.channel(Self.channelA) + "]")
        }
        let team = TeamID(unchecked: Self.team)
        let channels = try await api.publicChannels(team: team, page: 2, perPage: 500)
        #expect(channels.map(\.id.rawValue) == [Self.channelA])
        let browse = try #require(transport.requests.last)
        #expect(browse.path == "/company/chat/api/v4/teams/\(Self.team)/channels")
        #expect(browse.queryValue("page") == "2")
        #expect(browse.queryValue("per_page") == "200")
        #expect(try await api.archivedChannels(team: team, page: 0, perPage: 50).isEmpty)
        let counts = try await api.channelMemberCounts([ChannelID(unchecked: Self.channelA)])
        #expect(counts == [ChannelID(unchecked: Self.channelA): 12])
        #expect(transport.requests.last?.bodyJSON as? [String] == [Self.channelA])
        let unread = try await api.teamUnreads(includeCollapsedThreads: true)
        #expect(unread == [TeamUnread(teamID: team, messageCount: 4, mentionCount: 2, messageCountRoot: 3, mentionCountRoot: 1)])
        #expect(transport.requests.last?.queryValue("include_collapsed_threads") == "true")
        await api.shutdown()
    }

    @Test func createGroupMembersAndSearchBodies() async throws {
        let (api, transport) = client { request in
            let path = request.url.path(percentEncoded: true)
            if path.hasSuffix("/users/search") {
                return .json(#"[{"id":"\#(Self.me)","username":"alice"}]"#)
            }
            if path.hasSuffix("/members") { return .json(#"{"channel_id":"\#(Self.channelA)","user_id":"\#(Self.me)"}"#, status: 201) }
            return .json(FrameJSON.channel(Self.channelB), status: 201)
        }
        let created = try await api.createChannel(NewChannelRequest(team: TeamID(unchecked: Self.team), name: "release-plan",
                                                                    displayName: "Release plan", purpose: "Ship it",
                                                                    isPrivate: true))
        #expect(created.id.rawValue == Self.channelB)
        let create = try #require(transport.requests.last)
        #expect(create.path == "/company/chat/api/v4/channels")
        #expect(create.bodyJSON as? [String: String] == ["team_id": Self.team, "name": "release-plan",
                                                         "display_name": "Release plan", "purpose": "Ship it", "type": "P"])
        // Invalid URL names never reach the server.
        let before = transport.requestCount
        await #expect(throws: APIError.self) {
            _ = try await api.createChannel(NewChannelRequest(team: TeamID(unchecked: Self.team), name: "Bad Name",
                                                              displayName: "x", isPrivate: false))
        }
        #expect(transport.requestCount == before)

        _ = try await api.createGroupChannel(with: [UserID(unchecked: Self.channelA), UserID(unchecked: Self.custom)])
        #expect(transport.requests.last?.path == "/company/chat/api/v4/channels/group")
        #expect(transport.requests.last?.bodyJSON as? [String] == [Self.channelA, Self.custom])

        try await api.addChannelMembers(ChannelID(unchecked: Self.channelA), users: [UserID(unchecked: Self.me)])
        #expect(transport.requests.last?.bodyJSON as? [String: String] == ["user_id": Self.me])
        try await api.addChannelMembers(ChannelID(unchecked: Self.channelA),
                                        users: [UserID(unchecked: Self.me), UserID(unchecked: Self.custom)])
        #expect(transport.requests.last?.bodyJSON as? [String: [String]] == ["user_ids": [Self.me, Self.custom]])

        let users = try await api.searchUsers(UserSearchQuery(term: "  ali ", team: TeamID(unchecked: Self.team),
                                                              notInChannel: ChannelID(unchecked: Self.channelA), limit: 500))
        #expect(users.map(\.username) == ["alice"])
        let search = try #require(transport.requests.last?.bodyJSON as? [String: Any])
        #expect(search["term"] as? String == "ali")
        #expect(search["limit"] as? Int == 100)
        #expect(search["not_in_channel_id"] as? String == Self.channelA)
        #expect(search["allow_inactive"] as? Bool == false)
        let count = transport.requestCount
        #expect(try await api.searchUsers(UserSearchQuery(term: "   ", team: TeamID(unchecked: Self.team))).isEmpty)
        #expect(transport.requestCount == count)
        await api.shutdown()
    }

    @Test func teamIconUsesTheRevisionAsCacheBuster() throws {
        let (segments, query) = try MattermostHTTPClient.imagePath(.teamIcon(TeamID(unchecked: Self.team), revision: 1_234))
        #expect(segments == ["teams", Self.team, "image"])
        #expect(query == [URLQueryItem(name: "_", value: "1234")])
        let team = try WireJSON.decoder().decode(TeamWire.self, from: Data(
            #"{"id":"\#(Self.team)","name":"qa","display_name":"QA","last_team_icon_update":1234}"#.utf8)).team
        #expect(team.iconRevision == 1_234)
    }

    @Test func archivedChannelSettingIsReadFromClientConfig() throws {
        let v10 = try WireJSON.decoder().decode(ClientConfigWire.self, from: Data(
            #"{"Version":"10.11.24","ExperimentalViewArchivedChannels":"false"}"#.utf8))
        #expect(v10.viewArchivedChannels == false)
        let v11 = try WireJSON.decoder().decode(ClientConfigWire.self, from: Data(#"{"Version":"11.11.1"}"#.utf8))
        #expect(v11.viewArchivedChannels == nil)
    }

    @Test func channelNameRulesMatchTheServer() {
        #expect(ChannelNameRules.slug(from: "  Release Planning 2026! ") == "release-planning-2026")
        #expect(ChannelNameRules.slug(from: "Ünïcode—Team__x") == "n-code-team__x")
        #expect(ChannelNameRules.slug(from: "---") == "")
        #expect(ChannelNameRules.slug(from: String(repeating: "a", count: 100)).utf8.count == 64)
        #expect(ChannelNameRules.problem(with: "ok") == nil)
        #expect(ChannelNameRules.problem(with: "a") == .tooShort)
        #expect(ChannelNameRules.problem(with: String(repeating: "a", count: 65)) == .tooLong)
        #expect(ChannelNameRules.problem(with: "Upper") == .invalidCharacters)
        #expect(ChannelNameRules.problem(with: "has space") == .invalidCharacters)
        #expect(ChannelNameRules.problem(with: "-dash") == .invalidStart)
        #expect(ChannelNameRules.problem(with: "trailing-") == nil)
        #expect(ChannelNameRules.problem(with: Self.me + "__" + Self.team) == .reserved)
        #expect(ChannelNameRules.problem(with: String(repeating: "ab12", count: 10)) == .reserved)
    }
}

/// Minimal channel JSON for these tests.
enum FrameJSON {
    static func channel(_ id: String) -> String {
        #"{"id":"\#(id)","team_id":"\#(SidebarAPITests.team)","type":"O","name":"n\#(id.prefix(4))","display_name":"Channel"}"#
    }
}
