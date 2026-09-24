public import MatterMacModels

/// Composes the display document for a post: the parsed message followed by basic
/// message attachments (pretext, title, text, fields, footer). Interactive attachment
/// actions are never executed; a note is appended instead (SPEC §18).
public struct PostDocumentBuilder: Sendable {
    public let parse: @Sendable (String, MarkupLimits) -> MessageDocument
    public let limits: MarkupLimits

    public init(limits: MarkupLimits = .standard, parse: @escaping @Sendable (String, MarkupLimits) -> MessageDocument) {
        self.parse = parse
        self.limits = limits
    }

    public func document(for post: Post) -> MessageDocument {
        var document = post.message.isEmpty ? MessageDocument.empty : parse(post.message, limits)
        for attachment in post.props.attachments {
            var blocks: [MarkupBlock] = []
            if !attachment.pretext.isEmpty { blocks += parse(attachment.pretext, limits).blocks }
            if !attachment.authorName.isEmpty { blocks.append(.paragraph([.emphasis([.text(attachment.authorName)])])) }
            if !attachment.title.isEmpty {
                let label: [MarkupInline] = [.strong([.text(attachment.title)])]
                if let link = SafeLink(attachment.titleLink) {
                    blocks.append(.paragraph([.link(destination: link, label: label)]))
                } else {
                    blocks.append(.paragraph(label))
                }
            }
            if !attachment.text.isEmpty {
                blocks += parse(attachment.text, limits).blocks
            } else if attachment.title.isEmpty && attachment.pretext.isEmpty && !attachment.fallback.isEmpty {
                blocks.append(.paragraph([.text(attachment.fallback)]))
            }
            for field in attachment.fields {
                var inlines: [MarkupInline] = []
                if !field.title.isEmpty { inlines.append(.strong([.text(field.title + ": ")])) }
                inlines += Self.inlines(of: parse(field.value, limits))
                blocks.append(.paragraph(inlines))
            }
            if !attachment.footer.isEmpty {
                blocks.append(.paragraph([.emphasis([.text(attachment.footer)])]))
            }
            if attachment.hasUnsupportedActions {
                blocks.append(.paragraph([.emphasis([.text(String(localized: "Interactive buttons in this message are not supported in MatterMac."))])]))
            }
            if !blocks.isEmpty { document.blocks.append(.blockQuote(blocks)) }
        }
        return document
    }

    /// Flattens a small document into inline content (for attachment field values).
    static func inlines(of document: MessageDocument) -> [MarkupInline] {
        var result: [MarkupInline] = []
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { result.append(.lineBreak) }
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines):
                result += inlines
            case .codeBlock(_, let code):
                result.append(.code(code))
            default:
                result.append(.text(MessageDocument(blocks: [block]).plainText))
            }
        }
        return result
    }
}
