// Inline pass for one paragraph or heading. Two levels, mirroring the official webapp
// (marked for structure, then `doFormatText` on each resulting text node):
//
// 1. Structure: backslash escapes, code spans, `<autolinks>`, bare URLs, `[links](...)`,
//    `![images](...)`, and `*`/`_`/`~~` delimiter runs resolved with the CommonMark
//    delimiter-stack algorithm (including the `openers_bottom` optimisation that keeps
//    pathological inputs linear). Nodes live in a flat arena with sibling links, so
//    wrapping a run of siblings into an emphasis or link is O(1) and nothing recurses.
// 2. Decoration: each maximal run of text nodes is scanned once for e-mail addresses,
//    `@mentions`, `~channel` mentions, `:emoji:`, and `#hashtags`. Code, URLs, and
//    escaped characters are never decorated.
//
// Work is bounded: every created node spends `maximumInlineNodes` budget, container
// depth is checked against `maximumNestingDepth` when a container is formed, and all
// forward scans that can fail (link tails, autolinks, bare URLs) spend a shared
// look-ahead budget proportional to the message size. Exhausting any of them fails
// the block, which the caller turns into a verbatim fallback.

struct MarkupInlineBudget {
    var nodesRemaining: Int
    var lookaheadRemaining: Int
    let maximumDepth: Int
    let minimumHashtagLength: Int
}

struct MarkupInlineParser {
    private enum NodeKind: UInt8 {
        case root, text, literal, code, link, emphasis, strong, strikethrough, lineBreak
    }

    private struct Node {
        var kind: NodeKind
        var start: Int
        var end: Int
        var payload = -1
        var prev = -1
        var next = -1
        var firstChild = -1
        var lastChild = -1
        var depth = 0
    }

    private struct Delimiter {
        let node: Int
        let character: UInt8
        var count: Int
        let originalCount: Int
        let canOpen: Bool
        let canClose: Bool
        var prev: Int
        var next: Int
    }

    private struct Bracket {
        let node: Int
        var active: Bool
        let delimiterBottom: Int
    }

    private struct LinkInfo {
        let destination: SafeLink?
        let rawDestination: String
    }

    /// Longest raw link destination / bare URL / autolink that is scanned.
    private static let maximumDestinationBytes = 4_096
    private static let maximumTitleBytes = 1_024
    private static let maximumParenthesisDepth = 32
    /// Longest `:emoji_name:` recognised. System short names reach 72 characters in the
    /// v11.11.1 data (custom emoji are limited to 64).
    static let maximumEmojiNameLength = 80

    private let bytes: [UInt8]
    private let count: Int
    private var budget: MarkupInlineBudget
    private var nodes: [Node]
    private var delimiters: [Delimiter] = []
    private var delimiterTop = -1
    private var brackets: [Bracket] = []
    private var codes: [String] = []
    private var links: [LinkInfo] = []
    private var failed = false
    private var backticksScannedToEnd = false
    private var lastBacktickRun: [Int: Int] = [:]

    private init(bytes: [UInt8], budget: MarkupInlineBudget) {
        self.bytes = bytes
        self.count = bytes.count
        self.budget = budget
        self.nodes = [Node(kind: .root, start: 0, end: 0)]
        self.nodes.reserveCapacity(8)
    }

    /// Parses inline content. Returns `nil` when a limit was exceeded; `budget` is
    /// updated either way.
    static func parse(_ bytes: [UInt8], budget: inout MarkupInlineBudget) -> [MarkupInline]? {
        guard !bytes.isEmpty else { return [] }
        var parser = MarkupInlineParser(bytes: bytes, budget: budget)
        parser.scan()
        var output: [MarkupInline] = []
        if !parser.failed {
            output = parser.render(first: parser.nodes[0].firstChild, inLabel: false)
        }
        budget = parser.budget
        return parser.failed ? nil : output
    }

    // MARK: - Level 1: structure

    private static let structural: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for character in "\n\\`*_~[]!<hHwWmM".utf8 { table[Int(character)] = true }
        return table
    }()

    private mutating func scan() {
        var index = 0
        var textStart = 0
        let structural = Self.structural
        while index < count {
            if failed { return }
            let byte = bytes[index]
            guard structural[Int(byte)] else {
                index += 1
                continue
            }
            switch byte {
            case MarkupByte.newline:
                flushText(textStart, index)
                appendNode(.lineBreak, index, index)
                index += 1
                textStart = index

            case MarkupByte.backslash:
                guard index + 1 < count else {
                    index += 1
                    continue
                }
                let escaped = bytes[index + 1]
                if MarkupByte.isASCIIPunctuation(escaped) {
                    flushText(textStart, index)
                    appendNode(.literal, index + 1, index + 2)
                    index += 2
                    textStart = index
                } else if escaped == MarkupByte.newline {
                    flushText(textStart, index)
                    appendNode(.lineBreak, index, index)
                    index += 2
                    textStart = index
                } else {
                    index += 1
                }

            case MarkupByte.backtick:
                var runEnd = index
                while runEnd < count, bytes[runEnd] == MarkupByte.backtick { runEnd += 1 }
                let runLength = runEnd - index
                if let closer = findBacktickCloser(from: runEnd, length: runLength) {
                    flushText(textStart, index)
                    codes.append(codeSpanText(runEnd, closer))
                    let node = appendNode(.code, index, closer + runLength)
                    nodes[node].payload = codes.count - 1
                    index = closer + runLength
                    textStart = index
                } else {
                    index = runEnd
                }

            case MarkupByte.asterisk, MarkupByte.underscore, MarkupByte.tilde:
                var runEnd = index
                while runEnd < count, bytes[runEnd] == byte { runEnd += 1 }
                let runLength = runEnd - index
                if (byte == MarkupByte.tilde && runLength != 2) || followedByGraphemeExtender(runEnd) {
                    index = runEnd
                    continue
                }
                flushText(textStart, index)
                let flanking = flanking(index, runEnd, byte)
                let node = appendNode(.text, index, runEnd)
                if flanking.canOpen || flanking.canClose {
                    pushDelimiter(node: node, character: byte, count: runLength,
                                  canOpen: flanking.canOpen, canClose: flanking.canClose)
                }
                index = runEnd
                textStart = index

            case MarkupByte.openBracket:
                flushText(textStart, index)
                let node = appendNode(.text, index, index + 1)
                brackets.append(Bracket(node: node, active: true, delimiterBottom: delimiterTop))
                index += 1
                textStart = index

            case MarkupByte.exclamation:
                guard index + 1 < count, bytes[index + 1] == MarkupByte.openBracket else {
                    index += 1
                    continue
                }
                flushText(textStart, index)
                let node = appendNode(.text, index, index + 2)
                brackets.append(Bracket(node: node, active: true, delimiterBottom: delimiterTop))
                index += 2
                textStart = index

            case MarkupByte.closeBracket:
                flushText(textStart, index)
                if let end = closeBracket(at: index) {
                    index = end
                } else {
                    appendNode(.text, index, index + 1)
                    index += 1
                }
                textStart = index

            case MarkupByte.lessThan:
                if let autolink = scanAutolink(at: index) {
                    flushText(textStart, index)
                    appendLink(labelStart: index + 1, labelEnd: autolink.end - 1, destination: autolink.destination,
                               raw: autolink.raw, wholeEnd: autolink.end)
                    index = autolink.end
                    textStart = index
                } else {
                    index += 1
                }

            default:  // h, H, w, W, m, M: possible bare URL at a word boundary.
                if isURLBoundary(index), let url = scanBareURL(at: index) {
                    flushText(textStart, index)
                    if let destination = url.destination {
                        appendLink(labelStart: index, labelEnd: url.end, destination: destination, raw: url.raw,
                                   wholeEnd: url.end)
                    } else {
                        appendNode(.literal, index, url.end)
                    }
                    index = url.end
                    textStart = index
                } else {
                    index += 1
                }
            }
        }
        flushText(textStart, count)
        if !failed { processEmphasis(bottom: -1) }
    }

    // MARK: Arena

    @discardableResult
    private mutating func appendNode(_ kind: NodeKind, _ start: Int, _ end: Int) -> Int {
        let index = makeNode(kind, start, end)
        appendToRoot(index)
        return index
    }

    private mutating func makeNode(_ kind: NodeKind, _ start: Int, _ end: Int) -> Int {
        budget.nodesRemaining -= 1
        if budget.nodesRemaining < 0 { failed = true }
        nodes.append(Node(kind: kind, start: start, end: end))
        return nodes.count - 1
    }

    private mutating func appendToRoot(_ index: Int) {
        let last = nodes[0].lastChild
        nodes[index].prev = last
        nodes[index].next = -1
        if last >= 0 { nodes[last].next = index } else { nodes[0].firstChild = index }
        nodes[0].lastChild = index
    }

    private mutating func unlinkFromRoot(_ index: Int) {
        let prev = nodes[index].prev
        let next = nodes[index].next
        if prev >= 0 { nodes[prev].next = next } else { nodes[0].firstChild = next }
        if next >= 0 { nodes[next].prev = prev } else { nodes[0].lastChild = prev }
    }

    private mutating func flushText(_ start: Int, _ end: Int) {
        if end > start { appendNode(.text, start, end) }
    }

    private mutating func spendLookahead(_ bytesScanned: Int) {
        budget.lookaheadRemaining -= bytesScanned
        if budget.lookaheadRemaining < 0 { failed = true }
    }

    // MARK: Delimiters and emphasis

    private func followedByGraphemeExtender(_ index: Int) -> Bool {
        guard index < count, bytes[index] >= 0x80 else { return false }
        return MarkupScalar.extendsGrapheme(MarkupScalar.decode(bytes, at: index, end: count).scalar)
    }

    private func flanking(_ start: Int, _ end: Int, _ character: UInt8) -> (canOpen: Bool, canClose: Bool) {
        let before = MarkupScalar.decode(bytes, before: start, lowerBound: 0)?.scalar
        let after = end < count ? MarkupScalar.decode(bytes, at: end, end: count).scalar : nil
        let beforeWhitespace = before.map(MarkupScalar.isWhitespace) ?? true
        let afterWhitespace = after.map(MarkupScalar.isWhitespace) ?? true
        let beforePunctuation = before.map(MarkupScalar.isPunctuation) ?? false
        let afterPunctuation = after.map(MarkupScalar.isPunctuation) ?? false
        let leftFlanking = !afterWhitespace && (!afterPunctuation || beforeWhitespace || beforePunctuation)
        let rightFlanking = !beforeWhitespace && (!beforePunctuation || afterWhitespace || afterPunctuation)
        if character == MarkupByte.underscore {
            return (leftFlanking && (!rightFlanking || beforePunctuation),
                    rightFlanking && (!leftFlanking || afterPunctuation))
        }
        return (leftFlanking, rightFlanking)
    }

    private mutating func pushDelimiter(node: Int, character: UInt8, count: Int, canOpen: Bool, canClose: Bool) {
        delimiters.append(Delimiter(node: node, character: character, count: count, originalCount: count,
                                    canOpen: canOpen, canClose: canClose, prev: delimiterTop, next: -1))
        let index = delimiters.count - 1
        if delimiterTop >= 0 { delimiters[delimiterTop].next = index }
        delimiterTop = index
    }

    private mutating func removeDelimiter(_ index: Int) {
        let prev = delimiters[index].prev
        let next = delimiters[index].next
        if prev >= 0 { delimiters[prev].next = next }
        if next >= 0 { delimiters[next].prev = prev } else { delimiterTop = prev }
    }

    private static func bottomKey(_ delimiter: Delimiter) -> Int {
        let base: Int
        switch delimiter.character {
        case MarkupByte.asterisk: base = 0
        case MarkupByte.underscore: base = 6
        default: return 12
        }
        return base + (delimiter.canOpen ? 3 : 0) + delimiter.originalCount % 3
    }

    /// CommonMark "process emphasis" over delimiters above `bottom` (`-1`: all).
    private mutating func processEmphasis(bottom: Int) {
        var openersBottom = [Int](repeating: bottom, count: 13)
        var closer = delimiterTop
        if closer == bottom { return }
        while closer >= 0, delimiters[closer].prev != bottom, delimiters[closer].prev >= 0 {
            closer = delimiters[closer].prev
        }
        while closer >= 0 {
            if failed { return }
            let closing = delimiters[closer]
            if !closing.canClose {
                closer = closing.next
                continue
            }
            let key = Self.bottomKey(closing)
            var opener = closing.prev
            var found = false
            while opener >= 0, opener != bottom, opener != openersBottom[key] {
                let opening = delimiters[opener]
                if opening.character == closing.character && opening.canOpen {
                    if closing.character == MarkupByte.tilde {
                        found = opening.count == closing.count
                    } else {
                        let oddMatch = (closing.canOpen || opening.canClose) && closing.originalCount % 3 != 0
                            && (opening.originalCount + closing.originalCount) % 3 == 0
                        found = !oddMatch
                    }
                    if found { break }
                }
                opener = opening.prev
            }
            guard found else {
                openersBottom[key] = closing.prev
                let next = closing.next
                if !closing.canOpen { removeDelimiter(closer) }
                closer = next
                continue
            }
            let used = closing.character == MarkupByte.tilde
                ? 2 : (delimiters[closer].count >= 2 && delimiters[opener].count >= 2 ? 2 : 1)
            let kind: NodeKind = closing.character == MarkupByte.tilde
                ? .strikethrough : (used == 2 ? .strong : .emphasis)
            delimiters[opener].count -= used
            delimiters[closer].count -= used
            let openerNode = delimiters[opener].node
            let closerNode = delimiters[closer].node
            nodes[openerNode].end -= used
            nodes[closerNode].start += used
            wrapBetween(openerNode, closerNode, kind)
            var between = delimiters[opener].next
            while between >= 0, between != closer {
                let next = delimiters[between].next
                removeDelimiter(between)
                between = next
            }
            if delimiters[opener].count == 0 {
                unlinkFromRoot(openerNode)
                removeDelimiter(opener)
            }
            if delimiters[closer].count == 0 {
                let next = delimiters[closer].next
                unlinkFromRoot(closerNode)
                removeDelimiter(closer)
                closer = next
            }
        }
        while delimiterTop >= 0, delimiterTop != bottom { removeDelimiter(delimiterTop) }
    }

    /// Moves the siblings strictly between `opener` and `closer` into a new container
    /// inserted between them.
    private mutating func wrapBetween(_ opener: Int, _ closer: Int, _ kind: NodeKind) {
        let container = makeNode(kind, 0, 0)
        let first = nodes[opener].next
        var depth = 0
        if first != closer, first >= 0 {
            let last = nodes[closer].prev
            nodes[container].firstChild = first
            nodes[container].lastChild = last
            nodes[first].prev = -1
            nodes[last].next = -1
            var child = first
            while child >= 0 {
                depth = max(depth, nodes[child].depth)
                child = nodes[child].next
            }
        }
        nodes[container].depth = depth + 1
        nodes[opener].next = container
        nodes[container].prev = opener
        nodes[container].next = closer
        nodes[closer].prev = container
        if depth + 1 > budget.maximumDepth { failed = true }
    }

    // MARK: Links

    private mutating func closeBracket(at index: Int) -> Int? {
        guard let opener = brackets.last else { return nil }
        guard opener.active, let tail = scanLinkTail(at: index + 1) else {
            brackets.removeLast()
            return nil
        }
        if failed { return nil }
        brackets.removeLast()
        processEmphasis(bottom: opener.delimiterBottom)
        let raw = unescapedString(tail.destinationStart, tail.destinationEnd)
        links.append(LinkInfo(destination: MarkupLinkPolicy.destination(forLinkTarget: raw), rawDestination: raw))
        let link = opener.node
        let first = nodes[link].next
        nodes[link].kind = .link
        nodes[link].payload = links.count - 1
        var depth = 0
        if first >= 0 {
            nodes[link].firstChild = first
            nodes[link].lastChild = nodes[0].lastChild
            nodes[first].prev = -1
            var child = first
            while child >= 0 {
                depth = max(depth, nodes[child].depth)
                child = nodes[child].next
            }
        }
        nodes[link].depth = depth + 1
        nodes[link].next = -1
        nodes[0].lastChild = link
        if depth + 1 > budget.maximumDepth { failed = true }
        // Links cannot contain links: deactivate every earlier opener. Deactivation always
        // covers a suffix of the stack, so stopping at the first inactive one is exact.
        var earlier = brackets.count - 1
        while earlier >= 0, brackets[earlier].active {
            brackets[earlier].active = false
            earlier -= 1
        }
        return tail.end
    }

    private struct LinkTail {
        var destinationStart: Int
        var destinationEnd: Int
        var end: Int
    }

    /// `(destination "optional title")` directly after `]`.
    private mutating func scanLinkTail(at start: Int) -> LinkTail? {
        guard start < count, bytes[start] == MarkupByte.openParen else { return nil }
        var index = skipLinkWhitespace(start + 1)
        let destinationStart: Int
        let destinationEnd: Int
        let scanStart = index
        if index < count, bytes[index] == MarkupByte.lessThan {
            var cursor = index + 1
            while cursor < count, cursor - index <= Self.maximumDestinationBytes {
                let byte = bytes[cursor]
                if byte == MarkupByte.greaterThan { break }
                if byte == MarkupByte.newline || byte == MarkupByte.lessThan { break }
                if byte == MarkupByte.backslash, cursor + 1 < count,
                   MarkupByte.isASCIIPunctuation(bytes[cursor + 1]) {
                    cursor += 2
                    continue
                }
                cursor += 1
            }
            spendLookahead(cursor - scanStart + 1)
            guard cursor < count, bytes[cursor] == MarkupByte.greaterThan else { return nil }
            destinationStart = index + 1
            destinationEnd = cursor
            index = cursor + 1
        } else {
            var depth = 0
            var cursor = index
            while cursor < count {
                let byte = bytes[cursor]
                if byte <= MarkupByte.space || byte == 0x7F { break }
                if byte == MarkupByte.backslash, cursor + 1 < count,
                   MarkupByte.isASCIIPunctuation(bytes[cursor + 1]) {
                    cursor += 2
                    continue
                }
                if byte == MarkupByte.openParen {
                    depth += 1
                    if depth > Self.maximumParenthesisDepth { break }
                } else if byte == MarkupByte.closeParen {
                    if depth == 0 { break }
                    depth -= 1
                }
                cursor += 1
                if cursor - index > Self.maximumDestinationBytes { break }
            }
            spendLookahead(cursor - scanStart + 1)
            guard depth == 0, cursor - index <= Self.maximumDestinationBytes else { return nil }
            destinationStart = index
            destinationEnd = cursor
            index = cursor
        }
        let afterDestination = index
        index = skipLinkWhitespace(index)
        if index < count, index > afterDestination,
           bytes[index] == MarkupByte.quote || bytes[index] == MarkupByte.apostrophe
            || bytes[index] == MarkupByte.openParen {
            let opening = bytes[index]
            let closing = opening == MarkupByte.openParen ? MarkupByte.closeParen : opening
            var cursor = index + 1
            while cursor < count, bytes[cursor] != closing, cursor - index <= Self.maximumTitleBytes {
                if bytes[cursor] == MarkupByte.backslash { cursor += 1 }
                if opening == MarkupByte.openParen, cursor < count, bytes[cursor] == MarkupByte.openParen {
                    break
                }
                cursor += 1
            }
            spendLookahead(cursor - index + 1)
            guard cursor < count, bytes[cursor] == closing else { return nil }
            index = skipLinkWhitespace(cursor + 1)
        }
        guard index < count, bytes[index] == MarkupByte.closeParen else { return nil }
        return LinkTail(destinationStart: destinationStart, destinationEnd: destinationEnd, end: index + 1)
    }

    private func skipLinkWhitespace(_ start: Int) -> Int {
        var index = start
        var newlines = 0
        while index < count {
            let byte = bytes[index]
            if MarkupByte.isSpaceOrTab(byte) {
                index += 1
            } else if byte == MarkupByte.newline, newlines == 0 {
                newlines += 1
                index += 1
            } else {
                break
            }
        }
        return index
    }

    private func unescapedString(_ start: Int, _ end: Int) -> String {
        guard bytes[start..<end].contains(MarkupByte.backslash) else {
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(end - start)
        var index = start
        while index < end {
            if bytes[index] == MarkupByte.backslash, index + 1 < end, MarkupByte.isASCIIPunctuation(bytes[index + 1]) {
                out.append(bytes[index + 1])
                index += 2
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func appendLink(labelStart: Int, labelEnd: Int, destination: SafeLink?, raw: String,
                                     wholeEnd: Int) {
        links.append(LinkInfo(destination: destination, rawDestination: raw))
        let link = makeNode(.link, labelStart, wholeEnd)
        let label = makeNode(.literal, labelStart, labelEnd)
        nodes[link].payload = links.count - 1
        nodes[link].firstChild = label
        nodes[link].lastChild = label
        nodes[link].depth = 1
        appendToRoot(link)
    }

    private struct ScannedLink {
        var end: Int
        var destination: SafeLink?
        var raw: String
    }

    /// `<scheme:...>`, `<user@example.com>`, or `<www.example.com>`.
    private mutating func scanAutolink(at start: Int) -> ScannedLink? {
        var cursor = start + 1
        while cursor < count, cursor - start <= Self.maximumDestinationBytes {
            let byte = bytes[cursor]
            if byte == MarkupByte.greaterThan || byte <= MarkupByte.space || byte == MarkupByte.lessThan
                || byte == 0x7F {
                break
            }
            cursor += 1
        }
        spendLookahead(cursor - start)
        guard cursor < count, bytes[cursor] == MarkupByte.greaterThan, cursor > start + 1 else { return nil }
        let inner = String(decoding: bytes[(start + 1)..<cursor], as: UTF8.self)
        let end = cursor + 1
        if Self.hasURIScheme(bytes, start + 1, cursor) {
            return ScannedLink(end: end, destination: SafeLink(inner), raw: inner)
        }
        if Self.hasPrefixCaseInsensitive(bytes, start + 1, cursor, "www.") {
            return ScannedLink(end: end, destination: SafeLink("https://" + inner), raw: inner)
        }
        if Self.isAutolinkEmail(bytes, start + 1, cursor) {
            return ScannedLink(end: end, destination: SafeLink("mailto:" + inner), raw: inner)
        }
        return nil
    }

    /// `scheme:` with 2...32 scheme characters (CommonMark absolute URI).
    static func hasURIScheme(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
        guard start < end, MarkupByte.isLetter(bytes[start]) else { return false }
        var index = start + 1
        while index < end, index - start <= 32 {
            let byte = bytes[index]
            if byte == MarkupByte.colon { return index - start >= 2 }
            guard MarkupByte.isAlphanumeric(byte) || byte == MarkupByte.plus || byte == MarkupByte.dot
                || byte == MarkupByte.dash
            else { return false }
            index += 1
        }
        return false
    }

    private static func isAutolinkEmail(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
        var index = start
        while index < end, bytes[index] != MarkupByte.at {
            let byte = bytes[index]
            guard MarkupByte.isAlphanumeric(byte) || "!#$%&'*+/=?^_`{|}~.-".utf8.contains(byte) else { return false }
            index += 1
        }
        guard index > start, index < end else { return false }
        index += 1
        var labelLength = 0
        var sawDot = false
        while index < end {
            let byte = bytes[index]
            if byte == MarkupByte.dot {
                guard labelLength > 0 else { return false }
                sawDot = true
                labelLength = 0
            } else if MarkupByte.isAlphanumeric(byte) || byte == MarkupByte.dash {
                labelLength += 1
                guard labelLength <= 63 else { return false }
            } else {
                return false
            }
            index += 1
        }
        return sawDot && labelLength > 0
    }

    static func hasPrefixCaseInsensitive(_ bytes: [UInt8], _ start: Int, _ end: Int,
                                         _ prefix: StaticString) -> Bool {
        let length = prefix.utf8CodeUnitCount
        guard end - start >= length else { return false }
        return prefix.withUTF8Buffer { buffer in
            for offset in 0..<length {
                var byte = bytes[start + offset]
                if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") { byte |= 0x20 }
                if byte != buffer[offset] { return false }
            }
            return true
        }
    }

    // MARK: Bare URLs

    private func isURLBoundary(_ index: Int) -> Bool {
        guard let previous = MarkupScalar.decode(bytes, before: index, lowerBound: 0)?.scalar else { return true }
        if previous.value < 0x80 { return !MarkupByte.isAlphanumeric(UInt8(previous.value)) }
        return !(MarkupScalar.isLetter(previous) || MarkupScalar.isMark(previous) || MarkupScalar.isDecimalDigit(previous))
    }

    /// Bare `http://`, `https://`, `www.`, and `mailto:` URLs, following the webapp's
    /// GFM URL rule: punctuation is included only when followed by a URL character,
    /// parentheses only as balanced groups, and trailing `?!.,:*_~'"` is trimmed.
    private mutating func scanBareURL(at start: Int) -> ScannedLink? {
        let prefixLength: Int
        let destinationPrefix: String
        let allowsBracketHost: Bool
        if Self.hasPrefixCaseInsensitive(bytes, start, count, "https://") {
            (prefixLength, destinationPrefix, allowsBracketHost) = (8, "", true)
        } else if Self.hasPrefixCaseInsensitive(bytes, start, count, "http://") {
            (prefixLength, destinationPrefix, allowsBracketHost) = (7, "", true)
        } else if Self.hasPrefixCaseInsensitive(bytes, start, count, "www.") {
            (prefixLength, destinationPrefix, allowsBracketHost) = (4, "https://", false)
        } else if Self.hasPrefixCaseInsensitive(bytes, start, count, "mailto:") {
            (prefixLength, destinationPrefix, allowsBracketHost) = (7, "", false)
        } else {
            return nil
        }
        let bodyStart = start + prefixLength
        guard bodyStart < count else { return nil }
        let firstBody = bytes[bodyStart]
        // The body must start like a host (or an address, or an IPv6 literal `[`).
        guard MarkupByte.isAlphanumeric(firstBody) || firstBody >= 0x80
            || (allowsBracketHost && firstBody == MarkupByte.openBracket)
        else { return nil }

        var cursor = bodyStart
        let limit = min(count, start + Self.maximumDestinationBytes)
        scanning: while cursor < limit {
            let byte = bytes[cursor]
            switch byte {
            case 0...MarkupByte.space, 0x7F, MarkupByte.lessThan, MarkupByte.greaterThan, MarkupByte.backtick,
                 MarkupByte.closeParen:
                break scanning
            case MarkupByte.openParen:
                guard let groupEnd = balancedGroupEnd(from: cursor, limit: limit) else { break scanning }
                cursor = groupEnd
            case MarkupByte.exclamation, MarkupByte.openBracket, MarkupByte.closeBracket, UInt8(ascii: "{"),
                 UInt8(ascii: ";"), MarkupByte.colon, MarkupByte.apostrophe, MarkupByte.quote, UInt8(ascii: ","),
                 UInt8(ascii: "?"):
                guard cursor + 1 < limit, Self.isURLContinuation(bytes[cursor + 1]) else { break scanning }
                cursor += 1
            case 0x80...0xFF:
                let decoded = MarkupScalar.decode(bytes, at: cursor, end: count)
                if Self.terminatesURL(decoded.scalar) { break scanning }
                cursor += decoded.length
            default:
                cursor += 1
            }
        }
        spendLookahead(cursor - start)
        if cursor >= limit, limit < count, !MarkupByte.isASCIIWhitespace(bytes[limit]) {
            // Longer than the scan bound: not linked; the caller keeps it as text.
            return ScannedLink(end: cursor, destination: nil, raw: "")
        }
        var end = cursor
        while end > bodyStart, "?!.,:*_~'\"".utf8.contains(bytes[end - 1]) { end -= 1 }
        guard end > bodyStart else { return nil }
        let raw = String(decoding: bytes[start..<end], as: UTF8.self)
        return ScannedLink(end: end, destination: SafeLink(destinationPrefix + raw), raw: raw)
    }

    private static func isURLContinuation(_ byte: UInt8) -> Bool {
        !(MarkupByte.isASCIIWhitespace(byte) || byte == MarkupByte.openParen || byte == MarkupByte.closeParen
            || byte == MarkupByte.lessThan || byte == MarkupByte.greaterThan)
    }

    /// Unicode whitespace, CJK/full-width punctuation, and typographic quotes end a URL.
    private static func terminatesURL(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xAB, 0xBB, 0x2018, 0x2019, 0x201C, 0x201D, 0x3001, 0x3002, 0x300C...0x3011,
             0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF5E:
            return true
        default:
            return MarkupScalar.isWhitespace(scalar) || scalar.properties.generalCategory == .format
        }
    }

    /// End (exclusive) of a `( ... )` group with at most one nested level, or `nil`.
    private func balancedGroupEnd(from start: Int, limit: Int) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < limit {
            let byte = bytes[cursor]
            if byte <= MarkupByte.space || byte == MarkupByte.lessThan || byte == MarkupByte.greaterThan { return nil }
            if byte == MarkupByte.openParen {
                depth += 1
                if depth > 2 { return nil }
            } else if byte == MarkupByte.closeParen {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return nil
    }

    // MARK: Code spans

    /// Start of the closing backtick run of exactly `length`, scanning from `start`.
    /// After one unsuccessful scan to the end, later queries are answered from the
    /// recorded last position of each run length (cmark's approach), keeping this linear.
    private mutating func findBacktickCloser(from start: Int, length: Int) -> Int? {
        if backticksScannedToEnd {
            guard let last = lastBacktickRun[length], last >= start else { return nil }
        }
        var index = start
        while index < count {
            if bytes[index] == MarkupByte.backtick {
                let runStart = index
                while index < count, bytes[index] == MarkupByte.backtick { index += 1 }
                let runLength = index - runStart
                if runLength == length { return runStart }
                lastBacktickRun[runLength] = runStart
            } else {
                index += 1
            }
        }
        backticksScannedToEnd = true
        return nil
    }

    private func codeSpanText(_ start: Int, _ end: Int) -> String {
        var content = Array(bytes[start..<end])
        for index in content.indices where content[index] == MarkupByte.newline { content[index] = MarkupByte.space }
        if content.count >= 2, content.first == MarkupByte.space, content.last == MarkupByte.space,
           content.contains(where: { $0 != MarkupByte.space }) {
            content.removeFirst()
            content.removeLast()
        }
        return String(decoding: content, as: UTF8.self)
    }

    // MARK: - Rendering to MarkupInline

    private mutating func render(first: Int, inLabel: Bool) -> [MarkupInline] {
        var output: [MarkupInline] = []
        var current = first
        while current >= 0, !failed {
            let node = nodes[current]
            switch node.kind {
            case .text, .literal:
                var runEnd = current
                while runEnd >= 0, nodes[runEnd].kind == .text || nodes[runEnd].kind == .literal {
                    runEnd = nodes[runEnd].next
                }
                renderTextRun(from: current, until: runEnd, inLabel: inLabel, into: &output)
                current = runEnd
                continue
            case .code:
                appendOutput(.code(codes[node.payload]), to: &output)
            case .lineBreak:
                appendOutput(.lineBreak, to: &output)
            case .emphasis:
                appendOutput(.emphasis(render(first: node.firstChild, inLabel: inLabel)), to: &output)
            case .strong:
                appendOutput(.strong(render(first: node.firstChild, inLabel: inLabel)), to: &output)
            case .strikethrough:
                appendOutput(.strikethrough(render(first: node.firstChild, inLabel: inLabel)), to: &output)
            case .link:
                let label = render(first: node.firstChild, inLabel: true)
                if inLabel {
                    // A link inside a link label (e.g. a bare URL) is shown as its label.
                    for inline in label { appendOutput(inline, to: &output) }
                } else {
                    let info = links[node.payload]
                    let shown = label.isEmpty && !info.rawDestination.isEmpty ? [.text(info.rawDestination)] : label
                    appendOutput(.link(destination: info.destination, label: shown), to: &output)
                }
            case .root:
                break
            }
            current = node.next
        }
        return output
    }

    /// Appends to the rendered output, merging adjacent text. Rendering does not spend
    /// budget for nodes that already paid for themselves in the structure pass;
    /// decoration tokens are charged in `decorate`.
    private func appendOutput(_ inline: MarkupInline, to output: inout [MarkupInline]) {
        if case .text(let text) = inline, case .text(let previous)? = output.last {
            output[output.count - 1] = .text(previous + text)
            return
        }
        output.append(inline)
    }

    /// Renders consecutive text/literal nodes. Contiguous `.text` pieces are decorated
    /// together so context such as `foo_@bar` is judged on the joined text; literal
    /// pieces (escapes, rejected URLs) are emitted verbatim.
    private mutating func renderTextRun(from first: Int, until end: Int, inLabel: Bool,
                                        into output: inout [MarkupInline]) {
        var current = first
        var previousScalar: Unicode.Scalar?
        while current != end, current >= 0 {
            let node = nodes[current]
            var pieceEnd = node.end
            var next = node.next
            while next != end, next >= 0, nodes[next].kind == node.kind, nodes[next].start == pieceEnd {
                pieceEnd = nodes[next].end
                next = nodes[next].next
            }
            if pieceEnd > node.start {
                if node.kind == .literal {
                    appendOutput(.text(String(decoding: bytes[node.start..<pieceEnd], as: UTF8.self)), to: &output)
                } else {
                    let following: Unicode.Scalar? = next != end && next >= 0 && nodes[next].end > nodes[next].start
                        ? MarkupScalar.decode(bytes, at: nodes[next].start, end: count).scalar : nil
                    decorate(node.start, pieceEnd, previous: previousScalar, following: following,
                             interactive: !inLabel, into: &output)
                }
                previousScalar = MarkupScalar.decode(bytes, before: pieceEnd, lowerBound: node.start)?.scalar
            }
            current = next
        }
    }

    // MARK: - Level 2: decoration

    private static let decorationTriggers: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for character in "@~:#".utf8 { table[Int(character)] = true }
        return table
    }()

    private struct Token {
        var start: Int
        var end: Int
        var inline: MarkupInline
    }

    /// Context for one decoration scan. `previous`/`following` are the scalars just
    /// outside `[lower, upper)` when the run continues across a piece boundary (`nil`
    /// means a hard boundary such as the start of a text node).
    private struct DecorationScope {
        let lower: Int
        let upper: Int
        let previous: Unicode.Scalar?
        let following: Unicode.Scalar?
        var pendingStart: Int
        var lastTokenEnd = -1
    }

    private mutating func decorate(_ lower: Int, _ upper: Int, previous: Unicode.Scalar?,
                                   following: Unicode.Scalar?, interactive: Bool,
                                   into output: inout [MarkupInline]) {
        var scope = DecorationScope(lower: lower, upper: upper, previous: previous, following: following,
                                    pendingStart: lower)
        let triggers = Self.decorationTriggers
        var index = lower
        while index < upper {
            let byte = bytes[index]
            guard triggers[Int(byte)] else {
                index += 1
                continue
            }
            var token: Token?
            switch byte {
            case MarkupByte.at where interactive:
                token = matchEmail(at: index, scope) ?? matchMention(at: index, scope)
            case MarkupByte.tilde where interactive:
                token = matchChannel(at: index, scope)
            case MarkupByte.hash where interactive:
                token = matchHashtag(at: index, scope)
            case MarkupByte.colon:
                token = matchEmoji(at: index, scope)
            default:
                token = nil
            }
            guard let token else {
                index += 1
                continue
            }
            // A token splits the run: charge the token and the text piece before it.
            budget.nodesRemaining -= 2
            if budget.nodesRemaining < 0 { failed = true }
            if token.start > scope.pendingStart {
                appendOutput(.text(String(decoding: bytes[scope.pendingStart..<token.start], as: UTF8.self)),
                             to: &output)
            }
            appendOutput(token.inline, to: &output)
            index = token.end
            scope.pendingStart = token.end
            scope.lastTokenEnd = token.end
            if failed { return }
        }
        if upper > scope.pendingStart {
            appendOutput(.text(String(decoding: bytes[scope.pendingStart..<upper], as: UTF8.self)), to: &output)
        }
    }

    /// The scalar before `index` for boundary rules; `nil` at a hard boundary (run start
    /// without context, or right after a token, matching the webapp where tokens are
    /// replaced by opaque placeholders before later rules run).
    private func scalar(before index: Int, _ scope: DecorationScope) -> Unicode.Scalar? {
        if index == scope.lastTokenEnd { return nil }
        if index <= scope.lower { return scope.previous }
        return MarkupScalar.decode(bytes, before: index, lowerBound: scope.lower)?.scalar
    }

    private func scalar(at index: Int, _ scope: DecorationScope) -> Unicode.Scalar? {
        if index >= scope.upper { return scope.following }
        return MarkupScalar.decode(bytes, at: index, end: scope.upper).scalar
    }

    private func string(_ start: Int, _ end: Int) -> String {
        String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func isEmailLocal(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 {
            let byte = UInt8(scalar.value)
            return MarkupByte.isAlphanumeric(byte) || "!#$%&'*+-/=?^_`{|}~.".utf8.contains(byte)
        }
        return MarkupScalar.isLetter(scalar) || MarkupScalar.isDecimalDigit(scalar)
    }

    /// The webapp's e-mail rule: a local part of letters, digits, and `!#$%&'*+-/=?^_`{|}~`
    /// (single inner dots), `@`, a domain of letters/digits/`.`/`-`, and a final label of
    /// 2–5 letters not followed by a letter; not preceded by a letter or digit.
    private func matchEmail(at: Int, _ scope: DecorationScope) -> Token? {
        let floor = max(scope.pendingStart, scope.lower)
        var start = at
        while start > floor, let previous = MarkupScalar.decode(bytes, before: start, lowerBound: floor),
              Self.isEmailLocal(previous.scalar) {
            start -= previous.length
        }
        guard start < at else { return nil }
        var probe = at - 1
        while probe > start {
            if bytes[probe] == MarkupByte.dot && bytes[probe - 1] == MarkupByte.dot {
                start = probe + 1
                break
            }
            probe -= 1
        }
        while start < at, bytes[start] == MarkupByte.dot { start += 1 }
        guard start < at, bytes[at - 1] != MarkupByte.dot else { return nil }
        if start == floor, let previous = scalar(before: start, scope),
           MarkupScalar.isLetter(previous) || MarkupScalar.isDecimalDigit(previous) {
            return nil
        }
        var domainEnd = at + 1
        while domainEnd < scope.upper {
            let decoded = MarkupScalar.decode(bytes, at: domainEnd, end: scope.upper)
            let value = decoded.scalar.value
            guard MarkupScalar.isLetter(decoded.scalar) || (value >= 0x30 && value <= 0x39)
                || value == 0x2E || value == 0x2D
            else { break }
            domainEnd += decoded.length
        }
        guard domainEnd > at + 1 else { return nil }
        var end = domainEnd
        while end > at + 2 {
            let nextIsLetter = scalar(at: end, scope).map(MarkupScalar.isLetter) ?? false
            if !nextIsLetter {
                var labelStart = end
                var letters = 0
                while labelStart > at + 1, letters < 6,
                      let previous = MarkupScalar.decode(bytes, before: labelStart, lowerBound: at + 1),
                      MarkupScalar.isLetter(previous.scalar) {
                    labelStart -= previous.length
                    letters += 1
                }
                if (2...5).contains(letters), labelStart - 1 > at + 1, bytes[labelStart - 1] == MarkupByte.dot {
                    let email = string(start, end)
                    guard let destination = SafeLink("mailto:" + email) else { return nil }
                    return Token(start: start, end: end, inline: .link(destination: destination, label: [.text(email)]))
                }
            }
            end -= MarkupScalar.decode(bytes, before: end, lowerBound: at + 1)?.length ?? 1
        }
        return nil
    }

    /// `@username` / `@user:remote` / `@channel` / `@here` / `@all` (webapp
    /// `(?:\B|\b_+)@([a-z0-9.\-_]+(?::[a-z0-9.\-_]+)?)`, case-insensitive), with trailing
    /// dots left as text.
    private func matchMention(at: Int, _ scope: DecorationScope) -> Token? {
        var boundary = at
        while boundary > scope.pendingStart, bytes[boundary - 1] == MarkupByte.underscore { boundary -= 1 }
        if let previous = scalar(before: boundary, scope), MarkupScalar.isWordLike(previous) { return nil }
        var end = at + 1
        while end < scope.upper, MarkupByte.isUsernameByte(bytes[end]) { end += 1 }
        guard end > at + 1 else { return nil }
        if end + 1 < scope.upper, bytes[end] == MarkupByte.colon, MarkupByte.isAlphanumeric(bytes[end + 1]) {
            end += 1
            while end < scope.upper, MarkupByte.isUsernameByte(bytes[end]) { end += 1 }
        }
        while end > at + 1, bytes[end - 1] == MarkupByte.dot { end -= 1 }
        guard end > at + 1 else { return nil }
        return Token(start: at, end: end, inline: .mention(string(at + 1, end)))
    }

    /// `~channel-name` candidate (webapp `\B(~([a-z0-9.\-_]*))`, trailing punctuation
    /// trimmed). Whether the channel exists is decided by the presentation layer.
    private func matchChannel(at: Int, _ scope: DecorationScope) -> Token? {
        if let previous = scalar(before: at, scope), MarkupScalar.isWordLike(previous) { return nil }
        var end = at + 1
        while end < scope.upper, MarkupByte.isUsernameByte(bytes[end]) { end += 1 }
        while end > at + 1, !MarkupByte.isAlphanumeric(bytes[end - 1]) { end -= 1 }
        guard end > at + 1 else { return nil }
        return Token(start: at, end: end, inline: .channelMention(string(at + 1, end)))
    }

    /// `:name:` with `[A-Za-z0-9_+-]` names, not adjacent to `\w` characters (webapp
    /// `(?<!\w)(:([\w+-]+):)(?!\w)`).
    private func matchEmoji(at: Int, _ scope: DecorationScope) -> Token? {
        if let previous = scalar(before: at, scope), previous.value < 0x80,
           MarkupByte.isWordByte(UInt8(previous.value)) {
            return nil
        }
        var end = at + 1
        while end < scope.upper, end - at - 1 < Self.maximumEmojiNameLength, MarkupByte.isEmojiNameByte(bytes[end]) {
            end += 1
        }
        guard end > at + 1, end < scope.upper, bytes[end] == MarkupByte.colon else { return nil }
        if let next = scalar(at: end + 1, scope), next.value < 0x80, MarkupByte.isWordByte(UInt8(next.value)) {
            return nil
        }
        return Token(start: at, end: end + 1, inline: .emoji(string(at + 1, end)))
    }

    /// `#tag`: a letter, then letters, marks, digits, `_`, `.`, `-`, ending in a letter,
    /// mark, or digit; at least `minimumHashtagLength` characters after `#`; not inside a
    /// word (webapp `(^|\W)(#\p{L}[\p{L}\d\-_.]*[\p{L}\d])`, minimum length 3).
    private func matchHashtag(at: Int, _ scope: DecorationScope) -> Token? {
        if let previous = scalar(before: at, scope), MarkupScalar.isWordLike(previous) { return nil }
        guard at + 1 < scope.upper else { return nil }
        let first = MarkupScalar.decode(bytes, at: at + 1, end: scope.upper)
        guard MarkupScalar.isLetter(first.scalar) else { return nil }
        var end = at + 1 + first.length
        var characters = 1
        while end < scope.upper {
            let decoded = MarkupScalar.decode(bytes, at: end, end: scope.upper)
            let value = decoded.scalar.value
            guard MarkupScalar.isLetter(decoded.scalar) || MarkupScalar.isMark(decoded.scalar)
                || (value >= 0x30 && value <= 0x39) || value == 0x5F || value == 0x2E || value == 0x2D
            else { break }
            end += decoded.length
            characters += 1
        }
        while end > at + 1, bytes[end - 1] == MarkupByte.underscore || bytes[end - 1] == MarkupByte.dot
            || bytes[end - 1] == MarkupByte.dash {
            end -= 1
            characters -= 1
        }
        guard characters >= max(1, budget.minimumHashtagLength) else { return nil }
        return Token(start: at, end: end, inline: .hashtag(string(at + 1, end)))
    }
}

/// Destination policy for Markdown link targets.
enum MarkupLinkPolicy {
    /// `[label](target)`: absolute targets must pass `SafeLink`; scheme-less targets
    /// (`example.com/x`, `www.example.com`) are treated as `https://` (the webapp uses
    /// `http://`); relative targets (`/team/pl/...`, `#x`, `./x`) are not openable.
    static func destination(forLinkTarget raw: String) -> SafeLink? {
        guard let first = raw.utf8.first else { return nil }
        let bytes = Array(raw.utf8)
        if MarkupInlineParser.hasURIScheme(bytes, 0, bytes.count) { return SafeLink(raw) }
        switch first {
        case UInt8(ascii: "/"), UInt8(ascii: "#"), UInt8(ascii: "?"), UInt8(ascii: "."):
            return nil
        default:
            return SafeLink("https://" + raw)
        }
    }
}
