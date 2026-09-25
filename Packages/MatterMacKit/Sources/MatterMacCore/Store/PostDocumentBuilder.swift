public import MatterMacModels

/// Composes the display document for a post: the parsed message followed by basic
/// message attachments. Each attachment's pretext becomes ordinary blocks, followed by
/// one `.attachment` block (accent, author, title/link, text, fields, image link,
/// footer). Interactive attachment actions are never executed; the block records them
/// so a note is shown instead (SPEC §18).
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
            if !attachment.pretext.isEmpty { document.blocks += parse(attachment.pretext, limits).blocks }
            var block = MarkupAttachment(
                accent: MarkupAttachment.Accent(attachment.color),
                author: attachment.authorName,
                title: attachment.title,
                titleLink: attachment.title.isEmpty ? nil : SafeLink(attachment.titleLink),
                imageLink: SafeLink(attachment.imageURL).flatMap { $0.kind == .web ? $0 : nil },
                footer: attachment.footer,
                hasUnsupportedActions: attachment.hasUnsupportedActions)
            if !attachment.text.isEmpty {
                block.text = parse(attachment.text, limits).blocks
            } else if attachment.title.isEmpty && attachment.pretext.isEmpty && !attachment.fallback.isEmpty {
                block.text = [.paragraph([.text(attachment.fallback)])]
            }
            block.fields = attachment.fields.map { field in
                MarkupAttachment.Field(title: field.title,
                                       value: field.value.isEmpty ? [] : parse(field.value, limits).blocks,
                                       isShort: field.isShort)
            }
            if !block.isEmpty { document.blocks.append(.attachment(block)) }
        }
        return document
    }
}
