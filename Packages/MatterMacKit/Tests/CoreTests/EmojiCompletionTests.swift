import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import TestSupport

@Suite("Emoji completion", .serialized)
struct EmojiCompletionTests {
    @Test func colonTriggerReturnsBoundedSystemEmojiPrefixFirst() async {
        let h = await SessionHarness()
        let items = await h.session.completions(trigger: ":", query: "smi", channel: h.channel.id)
        #expect(items.count == 8)
        #expect(items.allSatisfy { $0.title.hasPrefix(":smi") && $0.title.hasSuffix(":") })
        #expect(items.first?.insertion == ":smile:")
        #expect(items.first?.subtitle == "😄")
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func exactAndAliasMatches() async {
        let h = await SessionHarness()
        let tada = await h.session.completions(trigger: ":", query: "tada", channel: h.channel.id)
        #expect(tada.first?.id == "tada")
        #expect(tada.first?.insertion == ":tada:")
        let thumbs = await h.session.completions(trigger: ":", query: "Thumbs", channel: h.channel.id)
        #expect(thumbs.map(\.insertion) == [":thumbsdown:", ":thumbsup:"])
        #expect(thumbs.map(\.subtitle) == ["👎", "👍"])
        let prefixThenSubstring = await h.session.completions(trigger: ":", query: "heart", channel: h.channel.id)
        #expect(prefixThenSubstring.first?.insertion == ":heart:")
        let unknown = await h.session.completions(trigger: ":", query: "zzqqxx", channel: h.channel.id)
        #expect(unknown.isEmpty)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func noCandidatesAfterShutdown() async {
        let h = await SessionHarness()
        _ = await h.session.shutdown(revokeServerSession: false)
        #expect(await h.session.completions(trigger: ":", query: "smile", channel: h.channel.id).isEmpty)
    }
}
