import SwiftUI
import MatterMacModels
import MatterMacCore
import MatterMacPlatform

/// Channel headers and purposes as readable SwiftUI text: Markdown is parsed by the
/// bounded `MarkupParser` (never `AttributedString(markdown:)`), and only `SafeLink`
/// destinations become links. Mentions, hashtags and emoji stay text.
enum ChannelHeaderMarkup {
    /// Channel headers are at most 1,024 characters on the server; anything longer is
    /// kept verbatim by the parser's fallback rather than parsed.
    static let limits = MarkupLimits(maximumInputCharacters: 4_096, maximumNestingDepth: 6,
                                     maximumBlocks: 64, maximumInlineNodes: 1_024)

    static func render(_ text: String, parse: (@Sendable (String, MarkupLimits) -> MessageDocument)?) -> AttributedString {
        guard let parse else { return AttributedString(text) }
        let document = parse(text, limits)
        var out = AttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { out += AttributedString("\n") }
            append(block, to: &out, depth: 0)
        }
        return out
    }

    private static func append(_ block: MarkupBlock, to out: inout AttributedString, depth: Int) {
        switch block {
        case .paragraph(let inlines):
            append(inlines, to: &out, intent: [], depth: 0)
        case .heading(_, let inlines):
            append(inlines, to: &out, intent: .stronglyEmphasized, depth: 0)
        case .blockQuote(let blocks) where depth < 4:
            for (index, child) in blocks.enumerated() {
                if index > 0 { out += AttributedString("\n") }
                append(child, to: &out, depth: depth + 1)
            }
        case .list(let list) where depth < 4:
            for (index, item) in list.items.enumerated() {
                if index > 0 { out += AttributedString("\n") }
                out += AttributedString(list.isOrdered ? "\(list.start &+ index). " : "• ")
                for (blockIndex, child) in item.blocks.enumerated() {
                    if blockIndex > 0 { out += AttributedString("\n") }
                    append(child, to: &out, depth: depth + 1)
                }
            }
        case .codeBlock(_, let code):
            var run = AttributedString(code)
            run.inlinePresentationIntent = .code
            out += run
        default:
            out += AttributedString(MessageDocument(blocks: [block]).plainText)
        }
    }

    private static func append(_ inlines: [MarkupInline], to out: inout AttributedString,
                               intent: InlinePresentationIntent, depth: Int, link: URL? = nil) {
        for inline in inlines {
            switch inline {
            case .text(let text): out += run(text, intent, link)
            case .code(let text): out += run(text, intent.union(.code), link)
            case .emphasis(let children) where depth < 8:
                append(children, to: &out, intent: intent.union(.emphasized), depth: depth + 1, link: link)
            case .strong(let children) where depth < 8:
                append(children, to: &out, intent: intent.union(.stronglyEmphasized), depth: depth + 1, link: link)
            case .strikethrough(let children) where depth < 8:
                append(children, to: &out, intent: intent.union(.strikethrough), depth: depth + 1, link: link)
            case .link(let destination, let label) where depth < 8:
                // A rejected destination keeps its label as plain text.
                append(label, to: &out, intent: intent, depth: depth + 1, link: destination?.url ?? link)
            case .emoji(let name): out += run(EmojiText.display(name), intent, link)
            case .mention(let name): out += run("@" + name, intent, link)
            case .channelMention(let name): out += run("~" + name, intent, link)
            case .hashtag(let tag): out += run("#" + tag, intent, link)
            case .lineBreak, .softBreak: out += AttributedString("\n")
            default:
                out += run(MessageDocument(blocks: [.paragraph([inline])]).plainText, intent, link)
            }
        }
    }

    private static func run(_ text: String, _ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
        var run = AttributedString(text)
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
        if let link { run.link = link }
        return run
    }

    /// Opens a clicked header link: links into this server open inside MatterMac,
    /// other `SafeLink` destinations in the default browser, anything else nowhere.
    @MainActor
    static func openAction(for session: SessionViewModel) -> OpenURLAction {
        OpenURLAction { [weak session] url in
            guard let session, let safe = SafeLink(url.absoluteString) else { return .discarded }
            if let serverLink = MattermostLink(url: safe.url, endpoint: session.session.endpoint) {
                session.open(serverLink)
            } else {
                ExternalLinks.open(safe)
            }
            return .handled
        }
    }
}
