import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI

@Suite("Profile and file-search wire")
struct ProfileWireTests {
    @Test func patchOmitsUnchangedFieldsAndCountsScalars() throws {
        let data = try JSONEncoder().encode(UserProfilePatchBody(patch: .init(nickname: "")))
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(value == ["nickname": ""])
        #expect(UserProfilePatch(firstName: String(repeating: "e\u{301}", count: 33)).fieldOverLimit == .firstName)
        #expect(UserProfilePatch(position: String(repeating: "a", count: 128)).fieldOverLimit == nil)
    }

    @Test func detailedStatusUsesSecondsAndIgnoresStaleEnd() throws {
        let id = "qnoo9uxat3gubgs5iqfbo74zxe"
        for status in ["dnd", "ooo"] {
            let data = Data("{\"user_id\":\"\(id)\",\"status\":\"\(status)\",\"dnd_end_time\":1234}".utf8)
            let detail = try WireJSON.decoder().decode(StatusWire.self, from: data).detail
            #expect(detail.status == PresenceStatus(wire: status))
            #expect(detail.doNotDisturbEnd == (status == "dnd" ? Date(timeIntervalSince1970: 1234) : nil))
        }
        #expect(!PresenceStatus.outOfOffice.isManuallySelectable)
        #expect(PresenceStatus.outOfOffice.silencesNotifications)
    }

    @Test func multipartRejectsHeaderInjectionAndBoundaryCollision() {
        #expect(MultipartFormBody(field: "image\r\nX:1", fileName: "profile.png", contentType: "image/png", content: Data()) == nil)
        #expect(MultipartFormBody(field: "image", fileName: "profile.png", contentType: "image/png", content: Data("--collision".utf8), boundary: "collision") == nil)
        let body = MultipartFormBody(field: "image", fileName: "profile.png", contentType: "image/png", content: Data([1, 2]), boundary: "safe")
        #expect(body?.data.suffix(12) == Data("\r\n--safe--\r\n".utf8))
    }
    @Test func fileResultsRespectOrderAndRejectMismatchedIDs() throws {
        let first = "qnoo9uxat3gubgs5iqfbo74zxe", second = "qnoo9uxat3gubgs5iqfbo74zxf"
        let json = """
        {"order":["\(first)","\(first)","\(second)"],"file_infos":{
        "\(first)":{"id":"\(first)","name":"first.txt","size":12},
        "\(second)":{"id":"\(first)","name":"mismatch.txt"}}}
        """
        let result = try WireJSON.decoder().decode(FileInfoListWire.self, from: Data(json.utf8))
        #expect(result.files.map(\.id.rawValue) == [first])
        #expect(result.skippedMalformed == 1)
    }

}
