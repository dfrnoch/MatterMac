import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI

@Suite("User wire decoding")
struct UserWireTests {
    private func decode(_ json: String) throws -> User {
        try WireJSON.decoder().decode(UserWire.self, from: Data(json.utf8)).user
    }

    @Test func decodesTimeZoneEmailAndCustomStatus() throws {
        let status = #"{\"emoji\":\"palm_tree\",\"text\":\"Vacation\",\"duration\":\"date_and_time\",\"expires_at\":\"2030-01-02T03:04:05Z\"}"#
        let user = try decode("""
            {"id":"qnoo9uxat3gubgs5iqfbo74zxe","username":"alice","email":"alice@example.test","roles":"system_user system_guest",
             "timezone":{"useAutomaticTimezone":"false","automaticTimezone":"Europe/Prague","manualTimezone":"America/New_York"},
             "props":{"customStatus":"\(status)"}}
            """)
        #expect(user.email == "alice@example.test")
        #expect(user.timeZoneIdentifier == "America/New_York")
        #expect(user.isGuest)
        #expect(user.customStatus?.emoji == "palm_tree")
        #expect(user.customStatus?.text == "Vacation")
        #expect(user.customStatus?.expiresAt == Date(timeIntervalSince1970: 1_893_553_445))
        #expect(user.customStatus?.isVisible(at: Date(timeIntervalSince1970: 1_893_553_446)) == false)
    }

    @Test func zeroExpiryMeansNoneAndMalformedStatusIsIgnored() throws {
        let status = #"{\"emoji\":\"\",\"text\":\"Focus\",\"duration\":\"\",\"expires_at\":\"0001-01-01T00:00:00Z\"}"#
        let user = try decode("""
            {"id":"qnoo9uxat3gubgs5iqfbo74zxe","username":"alice","timezone":{"useAutomaticTimezone":"true","automaticTimezone":"Europe/Prague"},
             "props":{"customStatus":"\(status)"}}
            """)
        #expect(user.timeZoneIdentifier == "Europe/Prague")
        #expect(user.customStatus == CustomStatus(emoji: "", text: "Focus", expiresAt: nil))
        let broken = try decode(#"{"id":"qnoo9uxat3gubgs5iqfbo74zxe","username":"alice","props":{"customStatus":"{not json"}}"#)
        #expect(broken.customStatus == nil)
        #expect(broken.timeZoneIdentifier == nil)
    }
}
