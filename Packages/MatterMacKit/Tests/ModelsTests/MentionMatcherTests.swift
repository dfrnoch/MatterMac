import Testing
import MatterMacModels

@Suite("Mention matching and notification properties")
struct MentionMatcherTests {
    private func matcher(keys: String = "", firstName: Bool = false, channelWide: Bool = true) -> MentionMatcher {
        let props = UserNotifyProps(values: ["mention_keys": keys, "first_name": firstName ? "true" : "false"])
        return MentionMatcher(username: "alice", firstName: "Alice", props: props, channelWideMentions: channelWide)
    }

    @Test func usernameMatchesAsAWholeWordIgnoringCase() {
        let m = matcher()
        #expect(m.matches("hey @alice"))
        #expect(m.matches("@ALICE, look"))
        #expect(m.matches("(@alice)"))
        #expect(m.matches("ask @alice."))
        #expect(!m.matches("hey @alice.smith"))
        #expect(!m.matches("hey @alicex"))
        #expect(!m.matches("mail alice@alice.example"))
        #expect(!m.matches("hey alice")) // the username needs its "@"
    }

    @Test func customKeysAndFirstNameAreOptIn() {
        #expect(!matcher().matches("the Deploy is done"))
        let keyed = matcher(keys: "deploy, on-call ,", firstName: true)
        #expect(keyed.matches("the Deploy is done"))
        #expect(keyed.matches("who is ON-CALL?"))
        #expect(!keyed.matches("redeployed"))
        #expect(keyed.matches("thanks alice!"))
        #expect(!matcher(firstName: false).matches("thanks alice!"))
    }

    @Test func channelWideMentionsFollowTheSetting() {
        #expect(matcher().matches("@channel standup"))
        #expect(matcher().matches("ping @here"))
        #expect(matcher().matches("@all: release"))
        #expect(!matcher(channelWide: false).matches("@channel standup"))
        #expect(!matcher().matches("#channel"))
    }

    @Test func notifyPropsDefaultsAndEditingAreBounded() {
        var props = UserNotifyProps(values: [:])
        #expect(props.desktop == .mention)
        #expect(props.desktopSound)
        #expect(props.channelWideMentions)
        #expect(!props.firstNameMentions)
        props.mentionKeys = [" Deploy ", "deploy", "", "a,b", "ship"]
        #expect(props.values["mention_keys"] == "deploy,ship")
        props.mentionKeys = (0..<100).map { "k\($0)" }
        #expect(props.mentionKeys.count == UserNotifyProps.maximumMentionKeys)
        let many = Dictionary(uniqueKeysWithValues: (0..<60).map { ("key\($0)", "v") })
        let bounded = UserNotifyProps.bounded(many)
        #expect(bounded.values.count == UserNotifyProps.maximumKeys)
        #expect(!bounded.isComplete)
        #expect(UserNotifyProps.bounded(["desktop": "all"]).isComplete)
        #expect(DesktopNotificationLevel(wire: "bogus") == .mention)
        #expect(ChannelDesktopLevel(wire: nil) == .default)
    }
}
