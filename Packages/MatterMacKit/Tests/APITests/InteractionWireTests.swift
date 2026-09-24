import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI

@Suite("Link preview, unread and pin wire handling")
struct InteractionWireTests {
    private func post(_ extra: String) throws -> Post {
        let json = """
            {"id":"p1xxxxxxxxxxxxxxxxxxxxxxxx","channel_id":"c1xxxxxxxxxxxxxxxxxxxxxxxx","user_id":"u1xxxxxxxxxxxxxxxxxxxxxxxx",
             "message":"see https://example.com/article","create_at":1000,"update_at":1000,"edit_at":0,"delete_at":0,
             "is_pinned":true\(extra)}
            """
        return try WireJSON.decoder().decode(PostWire.self, from: Data(json.utf8)).post
    }

    @Test func decodesOpenGraphEmbedWithMeasuredImage() throws {
        let decoded = try post("""
            ,"metadata":{"embeds":[{"type":"opengraph","url":"https://example.com/article","data":{
              "type":"article","url":"https://example.com/article","title":"  An   article\\ntitle ",
              "description":"Short description.","site_name":"Example",
              "images":[{"url":"http://img.example.com/a.png","secure_url":"https://img.example.com/a.png","width":0,"height":0}]}}],
             "images":{"https://img.example.com/a.png":{"width":1200,"height":630,"format":"png","frame_count":0},
                       "https://other.example/x.png":{"width":1,"height":1}}}
            """)
        #expect(decoded.isPinned)
        let preview = try #require(decoded.linkPreview)
        #expect(preview.kind == .website)
        #expect(preview.link.url.absoluteString == "https://example.com/article")
        #expect(preview.title == "An article title")
        #expect(preview.description == "Short description.")
        #expect(preview.siteName == "Example")
        #expect(preview.image == LinkPreview.Image(url: "https://img.example.com/a.png", width: 1_200, height: 630))
    }

    @Test func decodesDirectImageEmbedAndDropsSVG() throws {
        let image = try post("""
            ,"metadata":{"embeds":[{"type":"image","url":"https://example.com/cat.jpg"}],
             "images":{"https://example.com/cat.jpg":{"width":800,"height":600,"format":"jpeg"}}}
            """)
        #expect(image.linkPreview?.kind == .image)
        #expect(image.linkPreview?.image?.width == 800)
        let svg = try post("""
            ,"metadata":{"embeds":[{"type":"image","url":"https://example.com/logo.svg"}],
             "images":{"https://example.com/logo.svg":{"width":10,"height":10,"format":"svg"}}}
            """)
        #expect(svg.linkPreview == nil, "an image preview without a raster image is dropped")
    }

    @Test func ignoresUnsafeUnsupportedAndAttachmentEmbeds() throws {
        let unsafe = try post(#","metadata":{"embeds":[{"type":"opengraph","url":"javascript:alert(1)","data":{"title":"x"}}]}"#)
        #expect(unsafe.linkPreview == nil)
        let link = try post(#","metadata":{"embeds":[{"type":"link","url":"https://example.com"}]}"#)
        #expect(link.linkPreview == nil)
        let permalink = try post(#","metadata":{"embeds":[{"type":"permalink","data":{"post_id":"x"}}]}"#)
        #expect(permalink.linkPreview == nil)
        let empty = try post(#","metadata":{"embeds":[{"type":"opengraph","url":"https://example.com","data":{"title":""}}]}"#)
        #expect(empty.linkPreview == nil, "an OpenGraph embed without text is not shown")
        let attachments = try post("""
            ,"props":{"attachments":[{"text":"hi"}]},
             "metadata":{"embeds":[{"type":"opengraph","url":"https://example.com","data":{"title":"t"}}]}
            """)
        #expect(attachments.linkPreview == nil, "message attachments take the embed's place")
        let malformed = try post(#","metadata":{"embeds":{"not":"a list"}}"#)
        #expect(malformed.linkPreview == nil)
    }

    @Test func boundsPreviewText() throws {
        let longTitle = String(repeating: "Ž", count: 400)
        let decoded = try post("""
            ,"metadata":{"embeds":[{"type":"opengraph","url":"https://example.com","data":{"title":"\(longTitle)",
              "description":"\(String(repeating: "word ", count: 400))"}}]}
            """)
        let preview = try #require(decoded.linkPreview)
        #expect(preview.title.utf8.count <= LinkPreview.maximumTitleBytes + 3)
        #expect(preview.title.hasSuffix("…"))
        #expect(preview.description.utf8.count <= LinkPreview.maximumDescriptionBytes + 3)
        #expect(preview.image == nil)
    }

    @Test func decodesChannelUnreadState() throws {
        let json = #"""
            {"team_id":"t1xxxxxxxxxxxxxxxxxxxxxxxx","user_id":"u1xxxxxxxxxxxxxxxxxxxxxxxx","channel_id":"c1xxxxxxxxxxxxxxxxxxxxxxxx",
             "msg_count":7,"mention_count":1,"mention_count_root":1,"urgent_mention_count":0,"msg_count_root":5,
             "last_viewed_at":1999}
            """#
        let state = try WireJSON.decoder().decode(ChannelUnreadWire.self, from: Data(json.utf8)).state
        #expect(state == ChannelUnreadState(channelID: ChannelID(unchecked: "c1xxxxxxxxxxxxxxxxxxxxxxxx"),
                                            lastViewedAt: MattermostTimestamp(milliseconds: 1_999), messageCount: 7,
                                            messageCountRoot: 5, mentionCount: 1, mentionCountRoot: 1, urgentMentionCount: 0))
    }

    @Test func proxiedImagePathCarriesTheURLAsAQueryParameter() throws {
        let (segments, query) = try MattermostHTTPClient.imagePath(.proxiedImage(url: "https://img.example.com/a%20b.png?x=1&y=2"))
        #expect(segments == ["image"])
        #expect(query.count == 1 && query[0].name == "url")
        #expect(query[0].value == "https://img.example.com/a%20b.png?x=1&y=2")
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "mailto:a@example.com", "https://user:pw@example.com/x.png"] {
            #expect(throws: APIError.self) { try MattermostHTTPClient.imagePath(.proxiedImage(url: bad)) }
        }
    }

    @Test func preferenceListKeepsSavedPostsSeparatelyBounded() throws {
        let rows = (0..<3).map {
            #"{"user_id":"u1xxxxxxxxxxxxxxxxxxxxxxxx","category":"flagged_post","name":"p\#($0)xxxxxxxxxxxxxxxxxxxxxxx","value":"true"}"#
        } + [#"{"user_id":"u1xxxxxxxxxxxxxxxxxxxxxxxx","category":"theme","name":"","value":"{}"}"#,
             #"{"user_id":"u1xxxxxxxxxxxxxxxxxxxxxxxx","category":"favorite_channel","name":"c1xxxxxxxxxxxxxxxxxxxxxxxx","value":"true"}"#]
        let list = try WireJSON.decoder().decode(PreferenceListWire.self, from: Data(("[" + rows.joined(separator: ",") + "]").utf8))
        #expect(list.preferences.filter { $0.category == "flagged_post" }.count == 3)
        #expect(list.preferences.contains { $0.category == "favorite_channel" })
        #expect(!list.preferences.contains { $0.category == "theme" })
        #expect(!list.truncated)
    }

    @Test func clientConfigReportsImageProxyAndLinkPreviews() throws {
        let config = try WireJSON.decoder().decode(ClientConfigWire.self, from: Data(
            #"{"Version":"11.11.1","HasImageProxy":"true","EnableLinkPreviews":"false"}"#.utf8))
        #expect(config.capabilities.hasImageProxy == true)
        #expect(config.capabilities.linkPreviewsEnabled == false)
        let limited = try WireJSON.decoder().decode(ClientConfigWire.self, from: Data(#"{"Version":"10.11.24"}"#.utf8))
        #expect(limited.capabilities.hasImageProxy == nil)
    }
}
