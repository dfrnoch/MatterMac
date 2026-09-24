/// Server-configurable parsing behaviour (not resource limits).
public struct MarkupOptions: Hashable, Sendable {
    /// Characters required after `#` for a hashtag. Mattermost's
    /// `ServiceSettings.MinimumHashtagLength` (client config `MinimumHashtagLength`),
    /// default 3: `#abc` is a hashtag, `#ab` is not.
    public var minimumHashtagLength: Int

    public init(minimumHashtagLength: Int = 3) {
        self.minimumHashtagLength = minimumHashtagLength
    }

    public static let standard = MarkupOptions()
}

/// Safe, bounded parser for Mattermost message markup (SPEC §14). Hand-written rather
/// than built on `AttributedString(markdown:)`; see SPEC §14 for
/// the required subset. This is not full webapp rendering parity.
///
/// Properties:
/// - Pure and synchronous; safe to call from any isolation domain. It does CPU work
///   proportional to the input, so callers run it off the main actor (for example from
///   a `@concurrent` function) once per content revision.
/// - Linear-time: every scan either consumes input or spends a bounded look-ahead
///   budget; emphasis uses the CommonMark delimiter algorithm with `openers_bottom`.
/// - No recursion while parsing; rendering recurses at most
///   `limits.maximumNestingDepth` levels (blocks and inlines separately).
/// - Never drops content: when a limit is reached, rich parsing stops at the start of
///   the affected top-level block and the rest of the input is kept verbatim in a
///   trailing `.plainFallback` (`hitLimits == true`).
/// - HTML is never interpreted; it stays literal text.
public enum MarkupParser {
    public static func parse(_ text: String, limits: MarkupLimits = .standard,
                             options: MarkupOptions = .standard) -> MessageDocument {
        guard !text.isEmpty else { return .empty }
        let bytes = Array(text.utf8)
        let total = bytes.count

        var parseEnd = total
        var truncated = false
        if let overLimit = firstByteBeyondScalarLimit(bytes, limit: limits.maximumInputCharacters) {
            truncated = true
            parseEnd = startOfLine(containing: overLimit, in: bytes)
        }

        let tree = MarkupBlockParser.parse(bytes, end: parseEnd, limits: limits)
        let topLevel = tree.nodes[0].children
        var cut = tree.cutOffset
        if truncated && cut == nil {
            cut = topLevel.last.map { tree.nodes[$0].sourceStart } ?? parseEnd
        }

        var converter = MarkupTreeConverter(
            bytes: bytes, tree: tree,
            budget: MarkupInlineBudget(nodesRemaining: max(0, limits.maximumInlineNodes),
                                       lookaheadRemaining: 65_536 + 16 * parseEnd,
                                       maximumDepth: max(0, limits.maximumNestingDepth),
                                       minimumHashtagLength: options.minimumHashtagLength))
        var blocks: [MarkupBlock] = []
        blocks.reserveCapacity(topLevel.count + 1)
        for index in topLevel {
            let start = tree.nodes[index].sourceStart
            if let cut, start >= cut { break }
            guard let block = converter.convert(index) else {
                cut = start
                break
            }
            blocks.append(block)
        }
        guard let cut, cut < total else { return MessageDocument(blocks: blocks) }
        blocks.append(.plainFallback(String(decoding: bytes[cut..<total], as: UTF8.self)))
        return MessageDocument(blocks: blocks, hitLimits: true)
    }

    /// Byte index of the first scalar beyond `limit` scalars, or `nil` if within limit.
    private static func firstByteBeyondScalarLimit(_ bytes: [UInt8], limit: Int) -> Int? {
        if limit <= 0 { return 0 }
        if bytes.count <= limit { return nil }  // Every scalar is at least one byte.
        var scalars = 0
        for (index, byte) in bytes.enumerated() where byte & 0xC0 != 0x80 {
            if scalars == limit { return index }
            scalars += 1
        }
        return nil
    }

    private static func startOfLine(containing index: Int, in bytes: [UInt8]) -> Int {
        var position = index
        while position > 0 {
            let previous = bytes[position - 1]
            if previous == MarkupByte.newline || previous == MarkupByte.carriageReturn { break }
            position -= 1
        }
        return position
    }
}

/// Converts the block arena into `MarkupBlock` values, running the inline parser for
/// paragraphs and headings. Recursion follows block nesting, which the block parser
/// bounded by `maximumNestingDepth`.
struct MarkupTreeConverter {
    let bytes: [UInt8]
    let tree: MarkupBlockTree
    var budget: MarkupInlineBudget

    mutating func convert(_ index: Int) -> MarkupBlock? {
        let node = tree.nodes[index]
        switch node.kind {
        case .paragraph:
            guard let inlines = MarkupInlineParser.parse(paragraphBytes(node.lines), budget: &budget) else {
                return nil
            }
            return .paragraph(inlines)
        case .heading:
            let content = node.lines.isEmpty
                ? Array(bytes[node.headingStart..<max(node.headingStart, node.headingEnd)])
                : paragraphBytes(node.lines)
            guard let inlines = MarkupInlineParser.parse(content, budget: &budget) else { return nil }
            return .heading(level: node.headingLevel, inlines)
        case .fencedCode:
            return .codeBlock(language: fenceLanguage(node), code: codeText(node.lines))
        case .indentedCode:
            return .codeBlock(language: nil, code: codeText(node.lines))
        case .blockQuote:
            var children: [MarkupBlock] = []
            children.reserveCapacity(node.children.count)
            for child in node.children {
                guard let block = convert(child) else { return nil }
                children.append(block)
            }
            return .blockQuote(children)
        case .list:
            var items: [[MarkupBlock]] = []
            items.reserveCapacity(node.children.count)
            for item in node.children {
                var blocks: [MarkupBlock] = []
                for child in tree.nodes[item].children {
                    guard let block = convert(child) else { return nil }
                    blocks.append(block)
                }
                items.append(blocks)
            }
            return .list(ordered: node.isOrdered, start: node.listStart, items: items)
        case .thematicBreak:
            return .thematicBreak
        case .table:
            return .table(header: node.tableHeader, rows: node.tableRows)
        case .document, .item:
            return nil
        }
    }

    /// Paragraph lines with surrounding spaces/tabs removed, joined by `\n` (every
    /// newline is a Mattermost line break).
    private func paragraphBytes(_ lines: [MarkupBlockTree.Line]) -> [UInt8] {
        var out: [UInt8] = []
        var capacity = 0
        for line in lines { capacity += line.end - line.start + 1 }
        out.reserveCapacity(capacity)
        for (position, line) in lines.enumerated() {
            var start = line.start
            var end = line.end
            while start < end, MarkupByte.isSpaceOrTab(bytes[start]) { start += 1 }
            while end > start, MarkupByte.isSpaceOrTab(bytes[end - 1]) { end -= 1 }
            if position > 0 { out.append(MarkupByte.newline) }
            out.append(contentsOf: bytes[start..<end])
        }
        return out
    }

    /// Code content exactly as written (after container prefixes and the fence's own
    /// indentation), lines joined by `\n`, no trailing newline.
    private func codeText(_ lines: [MarkupBlockTree.Line]) -> String {
        var out: [UInt8] = []
        var capacity = 0
        for line in lines { capacity += line.end - line.start + line.extraSpaces + 1 }
        out.reserveCapacity(capacity)
        for (position, line) in lines.enumerated() {
            if position > 0 { out.append(MarkupByte.newline) }
            if line.extraSpaces > 0 { out.append(contentsOf: repeatElement(MarkupByte.space, count: line.extraSpaces)) }
            out.append(contentsOf: bytes[line.start..<line.end])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// First word of the info string (```` ```swift title ```` → `swift`), or `nil`.
    private func fenceLanguage(_ node: MarkupBlockTree.Node) -> String? {
        var end = node.infoStart
        while end < node.infoEnd, !MarkupByte.isSpaceOrTab(bytes[end]) { end += 1 }
        guard end > node.infoStart else { return nil }
        return String(decoding: bytes[node.infoStart..<end], as: UTF8.self)
    }
}
