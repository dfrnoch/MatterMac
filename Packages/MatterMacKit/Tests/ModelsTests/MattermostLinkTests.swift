import Foundation
import Testing
import MatterMacModels

@Suite("Server link recognition")
struct MattermostLinkTests {
    let root = try! ServerURLNormalizer.normalize("https://chat.example.org", allowInsecureLoopback: false)
    let subpath = try! ServerURLNormalizer.normalize("https://example.org/company/chat", allowInsecureLoopback: false)
    let postID = "abcdefghijklmnopqrstuvwxyz"

    func link(_ raw: String, _ endpoint: ServerEndpoint) -> MattermostLink? {
        URL(string: raw).flatMap { MattermostLink(url: $0, endpoint: endpoint) }
    }

    @Test func recognizesPermalinksChannelsAndDirectMessages() {
        #expect(link("https://chat.example.org/qa/pl/\(postID)", root) == .post(team: "qa", postID: PostID(unchecked: postID)))
        #expect(link("https://CHAT.example.org:443/qa/pl/\(postID)?x=1#y", root) == .post(team: "qa", postID: PostID(unchecked: postID)))
        #expect(link("https://chat.example.org/qa/channels/town-square", root) == .channel(team: "qa", name: "town-square"))
        #expect(link("https://chat.example.org/qa/messages/@Bob.Smith", root) == .directMessage(team: "qa", username: "bob.smith"))
        #expect(link("https://example.org/company/chat/qa/pl/\(postID)", subpath) == .post(team: "qa", postID: PostID(unchecked: postID)))
    }

    @Test func leavesOtherLinksExternal() {
        let rejected = [
            "https://other.example.org/qa/pl/\(postID)",              // another server
            "http://chat.example.org/qa/pl/\(postID)",                // another scheme
            "https://chat.example.org:8443/qa/pl/\(postID)",          // another port
            "https://chat.example.org/qa/pl/short",                   // not a post id
            "https://chat.example.org/qa/pl/\(postID)/extra",
            "https://chat.example.org/qa/channels/Bad%20Name",
            "https://chat.example.org/QA/channels/town-square",       // team names are lowercase
            "https://chat.example.org/qa/messages/bob",               // needs @
            "https://chat.example.org/api/v4/posts/\(postID)",
            "https://chat.example.org/qa",
        ]
        for raw in rejected { #expect(link(raw, root) == nil, "\(raw)") }
        #expect(link("https://example.org/qa/pl/\(postID)", subpath) == nil, "outside the server's subpath")
        #expect(link("https://example.org/company/other/qa/pl/\(postID)", subpath) == nil)
    }

    @Test func previewTextIsBoundedAndNormalized() {
        #expect(LinkPreview.bounded("  a \n\t b  ", 100) == "a b")
        #expect(LinkPreview.bounded("abcdef", 3) == "abc…")
        #expect(LinkPreview.bounded("ŽŽŽ", 4) == "ŽŽ…", "cuts at a character boundary")
        let preview = LinkPreview(kind: .website, link: SafeLink("https://example.org/a")!,
                                  title: String(repeating: "x", count: 1_000))
        #expect(preview.title.utf8.count <= LinkPreview.maximumTitleBytes + 3)
        #expect(preview.host == "example.org")
    }
}
