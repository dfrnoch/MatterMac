import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI

@Suite("Scheduled post wire")
struct ScheduledPostWireTests {
    let team = "teamteamteamteamteamteamte"
    let channel = "chanchanchanchanchanchanch"

    func scheduled(_ id: String, at: Int64, error: String = "", root: String = "") -> String {
        """
        {"id":"\(id)","channel_id":"\(channel)","root_id":"\(root)","message":"later","file_ids":[],
         "scheduled_at":\(at),"processed_at":0,"error_code":"\(error)","update_at":5,"user_id":"u","props":{}}
        """
    }

    @Test func listFlattensTeamAndDirectChannelsSoonestFirstAndSkipsMalformed() throws {
        let json = """
        {"\(team)":[\(scheduled("bbbbbbbbbbbbbbbbbbbbbbbbbb", at: 3_000)),{"id":"bad id!"}],
         "directChannels":[\(scheduled("aaaaaaaaaaaaaaaaaaaaaaaaaa", at: 2_000, error: "channel_archived",
                                     root: "rootrootrootrootrootrootro"))]}
        """
        let posts = try WireJSON.decoder().decode(ScheduledPostListWire.self, from: Data(json.utf8)).posts
        #expect(posts.map(\.id.rawValue) == ["aaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbb"])
        #expect(posts[0].hasFailed && posts[0].errorCode == "channel_archived")
        #expect(posts[0].rootID?.rawValue == "rootrootrootrootrootrootro")
        #expect(posts[1].rootID == nil && !posts[1].hasFailed)
        #expect(posts[1].scheduledAt == MattermostTimestamp(milliseconds: 3_000))
    }

    @Test func bodySendsEmptyRootAndMilliseconds() throws {
        let body = ScheduledPostBody(id: nil, channel_id: channel, root_id: "", message: "hi", file_ids: [],
                                     scheduled_at: 1_800_000_000_000)
        let value = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(body)) as? [String: Any])
        #expect(value["scheduled_at"] as? Int64 == 1_800_000_000_000)
        #expect(value["root_id"] as? String == "")
        #expect(value["id"] == nil)
    }
}
