import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

@Suite("Quick switcher matching and results", .serialized)
struct QuickSwitcherTests {
    // MARK: Matching

    @Test func foldingIgnoresCaseAndDiacritics() {
        #expect(QuickSwitchMatching.fold("Dorničák") == "dornicak")
        #expect(QuickSwitchMatching.fold("ÉQUIPE Ｑ") == "equipe q")
    }

    @Test func ranksExactPrefixWordPrefixSubstringAndAllWords() {
        typealias M = QuickSwitchMatching
        #expect(M.rank("town square", in: ["town square"]) == .exact)
        #expect(M.rank("town", in: ["town square"]) == .prefix)
        #expect(M.rank("squ", in: ["town square"]) == .wordPrefix)
        #expect(M.rank("squ", in: ["town-square"]) == .wordPrefix)
        #expect(M.rank("own", in: ["town square"]) == .substring)
        #expect(M.rank("anna ben", in: ["anna clark, ben ortiz"]) == .allWords)
        #expect(M.rank("anna zed", in: ["anna clark, ben ortiz"]) == nil)
        #expect(M.rank("xyz", in: ["town square"]) == nil)
        #expect(M.rank("", in: ["town square"]) == nil)
        // The best candidate wins.
        #expect(M.rank("rel", in: ["pre-release", "release"]) == .prefix)
        #expect(QuickSwitchMatching.Rank.prefix < .substring)
    }

    @Test func groupUsernamesDropTheCurrentUser() {
        #expect(QuickSwitchMatching.groupUsernames("anna, alice, ben", excluding: "alice") == ["anna", "ben"])
        #expect(QuickSwitchMatching.groupUsernames("anna,ben, ", excluding: "alice") == ["anna", "ben"])
        #expect(QuickSwitchMatching.groupTitle([], fallback: "Group") == "Group")
        #expect(QuickSwitchMatching.groupTitle(["Anna Clark", "ben"], fallback: "") == "Anna Clark, ben")
    }

    @Test func directoryFindsKnownUsersByUsername() {
        var directory = DirectoryStore(budget: .standard)
        let anna = User(id: UserID(unchecked: CoreFixtures.id("anna", 1)), username: "Anna", firstName: "Anna")
        directory.upsertUser(anna)
        directory.pin(CoreFixtures.me)
        let found = directory.peekUsers(usernames: ["anna", "alice", "nobody"])
        #expect(found["anna"]?.id == anna.id)
        #expect(found["alice"]?.id == CoreFixtures.me.id)
        #expect(found["nobody"] == nil)
        #expect(directory.peekUsers(usernames: []).isEmpty)
    }

    // MARK: Session results

    private static let anna = User(id: UserID(unchecked: CoreFixtures.id("anna", 1)), username: "anna",
                                   firstName: "Anna", lastName: "Clark",
                                   lastPictureUpdate: MattermostTimestamp(milliseconds: 42))
    private static let ben = User(id: UserID(unchecked: CoreFixtures.id("ben", 1)), username: "ben",
                                  firstName: "Ben", lastName: "Ortiz")
    private static let zoe = User(id: UserID(unchecked: CoreFixtures.id("zoe", 1)), username: "zoe",
                                  firstName: "Zoë", lastName: "Dvořák")
    private static let group = Channel(id: ChannelID(unchecked: CoreFixtures.id("gm", 1)), teamID: nil, type: .group,
                                       name: "a1b2c3", displayName: "alice, anna, ben, carl")

    private func harness(fullNames: Bool = true) async -> SidebarHarness {
        await SidebarHarness(configure: { state in
            let me = state.me.id
            if fullNames {
                state.preferences = [Preference(category: "display_settings", name: "name_format", value: "full_name")]
            }
            state.users[Self.anna.id] = Self.anna
            state.users[Self.ben.id] = Self.ben
            state.users[Self.zoe.id] = Self.zoe
            let annaDM = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", 1)), teamID: nil, type: .direct,
                                 name: [me.rawValue, Self.anna.id.rawValue].sorted().joined(separator: "__"),
                                 displayName: "", totalMessageCount: 4)
            let benDM = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", 2)), teamID: nil, type: .direct,
                                name: [me.rawValue, Self.ben.id.rawValue].sorted().joined(separator: "__"), displayName: "")
            var archived = CoreFixtures.channel(4)
            archived.displayName = "Old Launch"
            archived.deleteAt = MattermostTimestamp(milliseconds: 5)
            var release = CoreFixtures.channel(5)
            release.displayName = "Pre-release"
            release.name = "pre-release"
            var mentions = CoreFixtures.channel(6, total: 3)
            mentions.displayName = "Releases"
            mentions.name = "releases"
            for channel in [annaDM, benDM, archived, release, mentions, Self.group] {
                state.channels[channel.id] = channel
            }
            state.memberships[annaDM.id] = ChannelMembership(channelID: annaDM.id, userID: me,
                                                              lastViewedAt: MattermostTimestamp(milliseconds: 10))
            state.memberships[benDM.id] = ChannelMembership(channelID: benDM.id, userID: me,
                                                             lastViewedAt: MattermostTimestamp(milliseconds: 900))
            state.memberships[archived.id] = ChannelMembership(channelID: archived.id, userID: me,
                                                                lastViewedAt: MattermostTimestamp(milliseconds: 999))
            state.memberships[release.id] = ChannelMembership(channelID: release.id, userID: me,
                                                               lastViewedAt: MattermostTimestamp(milliseconds: 500))
            state.memberships[mentions.id] = ChannelMembership(channelID: mentions.id, userID: me,
                                                                mentionCount: 2)
            state.memberships[Self.group.id] = ChannelMembership(channelID: Self.group.id, userID: me,
                                                                  lastViewedAt: MattermostTimestamp(milliseconds: 700))
            state.statuses[Self.anna.id] = .away
        })
    }

    private func ready(_ h: SidebarHarness) async {
        _ = await eventually {
            await h.session.quickSwitcherResults(query: "").contains { $0.title == "Anna Clark" }
        }
    }

    @Test func emptyQueryListsUnreadThenRecentWithoutArchivedChannels() async {
        let h = await harness()
        await ready(h)
        let items = await h.session.quickSwitcherResults(query: "")
        // Mentions first, then other unread; then most recently viewed.
        #expect(items.prefix(2).map(\.title) == ["Releases", "Anna Clark"])
        #expect(items.prefix(2).allSatisfy { $0.section == .unread })
        #expect(items[0].mentionCount == 2)
        #expect(items.dropFirst(2).allSatisfy { $0.section == .recent })
        #expect(Array(items.dropFirst(2).prefix(3).map(\.title)) == ["Ben Ortiz", "Anna Clark, Ben Ortiz, carl", "Pre-release"])
        #expect(!items.contains { $0.title == "Old Launch" })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func queryRanksPrefixMatchesFirstAndKeepsArchivedChannels() async {
        let h = await harness()
        await ready(h)
        let items = await h.session.quickSwitcherResults(query: "rel")
        #expect(items.map(\.title) == ["Releases", "Pre-release"])
        #expect(items.allSatisfy { $0.section == .matches })
        let archived = await h.session.quickSwitcherResults(query: "launch")
        #expect(archived.map(\.title) == ["Old Launch"])
        #expect(archived.first?.isArchived == true)
        #expect(archived.first?.subtitle == "Archived")
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func groupMessagesUseDisplayNamesAndAvatarsOfKnownMembers() async throws {
        let h = await harness()
        await ready(h)
        let items = await h.session.quickSwitcherResults(query: "carl")
        let group = try #require(items.first { $0.kind == .channel(Self.group.id) })
        #expect(group.title == "Anna Clark, Ben Ortiz, carl")  // carl is unknown: username
        #expect(group.people.map(\.id) == [Self.anna.id, Self.ben.id])
        #expect(group.people.first?.revision == 42)
        #expect(group.subtitle == "4 members")
        #expect(group.channelType == .group)
        // Members match by display name and by username.
        #expect(await h.session.quickSwitcherResults(query: "ortiz").contains { $0.kind == .channel(Self.group.id) })
        #expect(await h.session.quickSwitcherResults(query: "anna ben").contains { $0.kind == .channel(Self.group.id) })
        // The DM with a member outranks the group, which was viewed more recently.
        let ben = await h.session.quickSwitcherResults(query: "ben")
        #expect(ben.prefix(2).map(\.title) == ["Ben Ortiz", "Anna Clark, Ben Ortiz, carl"])
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func directMessagesCarryPartnerAvatarPresenceAndUsername() async {
        let h = await harness()
        await ready(h)
        _ = await eventually { await h.session.quickSwitcherResults(query: "anna").first?.presence == .away }
        let items = await h.session.quickSwitcherResults(query: "anna")
        let dm = items.first
        #expect(dm?.title == "Anna Clark")
        #expect(dm?.subtitle == "@anna")
        #expect(dm?.people.first?.id == Self.anna.id)
        #expect(dm?.presence == .away)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func peopleWithoutADirectMessageFollowAsTheirOwnSection() async {
        let h = await harness()
        await ready(h)
        // "zoe" has no DM: from autocomplete, and a diacritic-insensitive local
        // search for her surname finds nothing local.
        let items = await h.session.quickSwitcherResults(query: "zoe")
        let person = items.first { $0.kind == .user(Self.zoe.id) }
        #expect(person?.section == .people)
        #expect(person?.title == "Zoë Dvořák")
        #expect(person?.subtitle == "@zoe")
        #expect(person?.people.map(\.id) == [Self.zoe.id])
        // Existing DM partners are not repeated as people.
        let anna = await h.session.quickSwitcherResults(query: "anna")
        #expect(!anna.contains { $0.kind == .user(Self.anna.id) })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func diacriticInsensitiveMatchingFindsDirectMessages() async {
        let h = await SidebarHarness(configure: { state in
            let me = state.me.id
            state.preferences = [Preference(category: "display_settings", name: "name_format", value: "full_name")]
            state.users[Self.zoe.id] = Self.zoe
            let dm = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", 3)), teamID: nil, type: .direct,
                             name: [me.rawValue, Self.zoe.id.rawValue].sorted().joined(separator: "__"), displayName: "")
            state.channels[dm.id] = dm
            state.memberships[dm.id] = ChannelMembership(channelID: dm.id, userID: me)
        })
        _ = await eventually { await h.session.quickSwitcherResults(query: "").contains { $0.title == "Zoë Dvořák" } }
        let items = await h.session.quickSwitcherResults(query: "dvorak")
        #expect(items.first?.title == "Zoë Dvořák")
        #expect(items.first?.section == .matches)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func resultsStayBounded() async {
        let h = await harness()
        await ready(h)
        #expect(await h.session.quickSwitcherResults(query: "", limit: 2).count == 2)
        #expect(await h.session.quickSwitcherResults(query: "a", limit: 3).count <= 3)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func itemKeepsAtMostThreePeople() {
        let people = (1...5).map {
            QuickSwitchItem.Person(id: UserID(unchecked: CoreFixtures.id("p", $0)), revision: 0, name: "P\($0)")
        }
        let item = QuickSwitchItem(kind: .channel(.fixture(1)), title: "G", subtitle: "", channelType: .group,
                                   isUnread: false, people: people)
        #expect(item.people.count == QuickSwitchItem.maxPeople)
    }
}
