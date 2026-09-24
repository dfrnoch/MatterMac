// Line-oriented block structure pass, modelled on the CommonMark reference algorithm
// (commonmark.js `incorporateLine`): each line first continues the open containers,
// then may open new containers/leaves, then its remaining text is added to the tip.
// Every step is bounded: containers nest at most `maximumNestingDepth` deep, at most
// `maximumBlocks` blocks are created, and each line is visited once. The tree lives in
// a flat arena (no recursion while building).
//
// Supported: paragraphs, ATX and setext headings, fenced (``` and ~~~) and indented
// code, block quotes, bullet/ordered lists, thematic breaks, GFM pipe tables. Not
// interpreted: HTML blocks and link reference definitions (kept as paragraph text).

struct MarkupBlockTree {
    enum Kind: UInt8 {
        case document, blockQuote, list, item, paragraph, heading, fencedCode, indentedCode, thematicBreak, table
    }

    /// One stored line of leaf content: `[start, end)` in the source after container
    /// prefixes were removed; `extraSpaces` re-creates a partially consumed tab.
    struct Line {
        var lineStart: Int
        var start: Int
        var end: Int
        var extraSpaces: Int
    }

    struct Node {
        var kind: Kind
        var parent: Int
        var children: [Int] = []
        var isOpen = true
        /// Byte offset of the line on which the block started (used for fallback cuts).
        var sourceStart: Int
        /// Number of block-quote/list containers enclosing (and including) this node.
        var containerDepth: Int
        var lines: [Line] = []
        // Lists and items.
        var isOrdered = false
        var listMarker: UInt8 = 0
        var listStart = 1
        var markerOffset = 0
        var padding = 0
        // Fenced code.
        var fenceCharacter: UInt8 = 0
        var fenceLength = 0
        var fenceOffset = 0
        var infoStart = 0
        var infoEnd = 0
        // Headings.
        var headingLevel = 0
        var headingStart = 0
        var headingEnd = 0
        // Tables.
        var tableHeader: [String] = []
        var tableRows: [[String]] = []
    }

    var nodes: [Node]
    /// Byte offset where rich parsing stopped because a limit was reached, if any.
    var cutOffset: Int?
}

struct MarkupBlockParser {
    typealias Kind = MarkupBlockTree.Kind

    private enum Continuation { case matched, notMatched, lineFinished }
    private enum StartResult { case none, container, leaf }

    private let bytes: [UInt8]
    private let limits: MarkupLimits
    private var nodes: [MarkupBlockTree.Node]
    private var tip = 0
    private var oldTip = 0
    private var lastMatchedContainer = 0
    private var allClosed = true
    private var blocksCreated = 0
    private var cutOffset: Int?

    // Per-line cursor (columns follow CommonMark tab stops of 4).
    private var lineStart = 0
    private var lineEnd = 0
    private var offset = 0
    private var column = 0
    private var nextNonspace = 0
    private var nextNonspaceColumn = 0
    private var indent = 0
    private var indented = false
    private var blank = false
    private var partiallyConsumedTab = false
    private var lineConsumed = false

    private static let codeIndent = 4

    init(bytes: [UInt8], limits: MarkupLimits) {
        self.bytes = bytes
        self.limits = limits
        var root = MarkupBlockTree.Node(kind: .document, parent: -1, sourceStart: 0, containerDepth: 0)
        root.children.reserveCapacity(4)
        self.nodes = [root]
        self.nodes.reserveCapacity(16)
    }

    /// Parses `bytes[0..<end]`, where `end` is a line boundary.
    static func parse(_ bytes: [UInt8], end: Int, limits: MarkupLimits) -> MarkupBlockTree {
        var parser = MarkupBlockParser(bytes: bytes, limits: limits)
        parser.run(end: end)
        return MarkupBlockTree(nodes: parser.nodes, cutOffset: parser.cutOffset)
    }

    private mutating func run(end: Int) {
        var position = 0
        while position < end {
            var lineTerminator = position
            while lineTerminator < end {
                let byte = bytes[lineTerminator]
                if byte == MarkupByte.newline || byte == MarkupByte.carriageReturn { break }
                lineTerminator += 1
            }
            processLine(start: position, end: lineTerminator)
            if cutOffset != nil { return }
            if lineTerminator >= end { break }
            if bytes[lineTerminator] == MarkupByte.carriageReturn, lineTerminator + 1 < end,
               bytes[lineTerminator + 1] == MarkupByte.newline {
                position = lineTerminator + 2
            } else {
                position = lineTerminator + 1
            }
        }
        while tip > 0 { finalize(tip) }
        nodes[0].isOpen = false
    }

    // MARK: - Line processing

    private mutating func processLine(start: Int, end: Int) {
        lineStart = start
        lineEnd = end
        offset = start
        column = 0
        blank = false
        partiallyConsumedTab = false
        lineConsumed = false

        var allMatched = true
        var container = 0
        oldTip = tip

        while let last = nodes[container].children.last, nodes[last].isOpen {
            container = last
            findNextNonspace()
            switch continueBlock(container) {
            case .matched: break
            case .notMatched: allMatched = false
            case .lineFinished: return
            }
            if !allMatched {
                container = nodes[container].parent
                break
            }
        }

        allClosed = container == oldTip
        lastMatchedContainer = container
        let containerKind = nodes[container].kind
        var matchedLeaf = containerKind == .fencedCode || containerKind == .indentedCode

        while !matchedLeaf {
            findNextNonspace()
            if !indented && !maybeSpecial(at: nextNonspace) {
                advanceNextNonspace()
                break
            }
            let result = tryBlockStarts(&container)
            if cutOffset != nil { return }
            switch result {
            case .container: continue
            case .leaf: matchedLeaf = true
            case .none: advanceNextNonspace()
            }
            if result == .none { break }
        }
        if lineConsumed { return }

        if !allClosed && !blank && nodes[tip].kind == .paragraph {
            addLine()  // Lazy paragraph continuation.
            return
        }
        closeUnmatchedBlocks()
        switch nodes[container].kind {
        case .paragraph, .fencedCode, .indentedCode:
            addLine()
        case .table:
            guard offset < lineEnd else { return }
            if Self.hasUnescapedPipe(bytes, offset, lineEnd) {
                addTableRow(container)
            } else {
                finalize(container)
                startParagraph()
            }
        default:
            if offset < lineEnd && !blank { startParagraph() }
        }
    }

    private mutating func startParagraph() {
        guard addChild(.paragraph) != nil else { return }
        advanceNextNonspace()
        addLine()
    }

    private mutating func continueBlock(_ index: Int) -> Continuation {
        switch nodes[index].kind {
        case .document, .list:
            return .matched
        case .blockQuote:
            guard !indented, byte(at: nextNonspace) == MarkupByte.greaterThan else { return .notMatched }
            advanceNextNonspace()
            advanceOffset(1, columns: false)
            if MarkupByte.isSpaceOrTab(byte(at: offset)) { advanceOffset(1, columns: true) }
            return .matched
        case .item:
            let required = nodes[index].markerOffset + nodes[index].padding
            if blank {
                if nodes[index].children.isEmpty { return .notMatched }
                advanceNextNonspace()
            } else if indent >= required {
                advanceOffset(required, columns: true)
            } else {
                return .notMatched
            }
            return .matched
        case .paragraph, .table:
            return blank ? .notMatched : .matched
        case .heading, .thematicBreak:
            return .notMatched
        case .fencedCode:
            let fence = nodes[index].fenceCharacter
            if indent <= 3, byte(at: nextNonspace) == fence {
                var runEnd = nextNonspace
                while runEnd < lineEnd, bytes[runEnd] == fence { runEnd += 1 }
                if runEnd - nextNonspace >= nodes[index].fenceLength,
                   Self.isBlank(bytes, runEnd, lineEnd) {
                    finalize(index)
                    return .lineFinished
                }
            }
            var remaining = nodes[index].fenceOffset
            while remaining > 0, MarkupByte.isSpaceOrTab(byte(at: offset)) {
                advanceOffset(1, columns: true)
                remaining -= 1
            }
            return .matched
        case .indentedCode:
            if indent >= Self.codeIndent {
                advanceOffset(Self.codeIndent, columns: true)
            } else if blank {
                advanceNextNonspace()
            } else {
                return .notMatched
            }
            return .matched
        }
    }

    // MARK: - Block starts

    private mutating func tryBlockStarts(_ container: inout Int) -> StartResult {
        let first = byte(at: nextNonspace)
        let containerKind = nodes[container].kind

        // Block quote.
        if !indented && first == MarkupByte.greaterThan {
            advanceNextNonspace()
            advanceOffset(1, columns: false)
            if MarkupByte.isSpaceOrTab(byte(at: offset)) { advanceOffset(1, columns: true) }
            closeUnmatchedBlocks()
            guard addChild(.blockQuote) != nil else { return .none }
            container = tip
            return .container
        }

        // ATX heading.
        if !indented && first == MarkupByte.hash, let level = atxHeadingLevel() {
            advanceNextNonspace()
            advanceOffset(level, columns: false)
            closeUnmatchedBlocks()
            guard let heading = addChild(.heading) else { return .none }
            var contentStart = offset
            while contentStart < lineEnd, MarkupByte.isSpaceOrTab(bytes[contentStart]) { contentStart += 1 }
            var contentEnd = lineEnd
            while contentEnd > contentStart, MarkupByte.isSpaceOrTab(bytes[contentEnd - 1]) { contentEnd -= 1 }
            var closing = contentEnd
            while closing > contentStart, bytes[closing - 1] == MarkupByte.hash { closing -= 1 }
            if closing < contentEnd, closing == contentStart || MarkupByte.isSpaceOrTab(bytes[closing - 1]) {
                contentEnd = closing
                while contentEnd > contentStart, MarkupByte.isSpaceOrTab(bytes[contentEnd - 1]) { contentEnd -= 1 }
            }
            nodes[heading].headingLevel = level
            nodes[heading].headingStart = contentStart
            nodes[heading].headingEnd = contentEnd
            offset = lineEnd
            container = tip
            return .leaf
        }

        // Fenced code.
        if !indented && (first == MarkupByte.backtick || first == MarkupByte.tilde) {
            var runEnd = nextNonspace
            while runEnd < lineEnd, bytes[runEnd] == first { runEnd += 1 }
            let length = runEnd - nextNonspace
            if length >= 3 {
                var infoStart = runEnd
                while infoStart < lineEnd, MarkupByte.isSpaceOrTab(bytes[infoStart]) { infoStart += 1 }
                var infoEnd = lineEnd
                while infoEnd > infoStart, MarkupByte.isSpaceOrTab(bytes[infoEnd - 1]) { infoEnd -= 1 }
                let backtickInInfo = first == MarkupByte.backtick
                    && bytes[infoStart..<infoEnd].contains(MarkupByte.backtick)
                if !backtickInInfo {
                    let fenceIndent = indent
                    closeUnmatchedBlocks()
                    guard let code = addChild(.fencedCode) else { return .none }
                    nodes[code].fenceCharacter = first
                    nodes[code].fenceLength = length
                    nodes[code].fenceOffset = fenceIndent
                    nodes[code].infoStart = infoStart
                    nodes[code].infoEnd = infoEnd
                    offset = lineEnd
                    lineConsumed = true
                    container = tip
                    return .leaf
                }
            }
        }

        // GFM table: a delimiter row directly below a paragraph line.
        if !indented && containerKind == .paragraph
            && (first == MarkupByte.pipe || first == MarkupByte.colon || first == MarkupByte.dash),
            let delimiterCells = Self.delimiterRowCellCount(bytes, nextNonspace, lineEnd),
            let headerLine = nodes[container].lines.last {
            let header = Self.splitCells(bytes, headerLine.start, headerLine.end)
            if header.count == delimiterCells,
               Self.hasUnescapedPipe(bytes, headerLine.start, headerLine.end)
                || Self.hasUnescapedPipe(bytes, nextNonspace, lineEnd) {
                closeUnmatchedBlocks()
                let table: Int
                if nodes[container].lines.count > 1 {
                    nodes[container].lines.removeLast()
                    finalize(container)
                    guard let created = addChild(.table) else { return .none }
                    nodes[created].sourceStart = headerLine.lineStart
                    table = created
                } else {
                    nodes[container].kind = .table
                    nodes[container].lines = []
                    table = container
                }
                nodes[table].tableHeader = header
                offset = lineEnd
                lineConsumed = true
                container = table
                return .leaf
            }
        }

        // Setext heading underline.
        if !indented && containerKind == .paragraph && (first == MarkupByte.equals || first == MarkupByte.dash) {
            var runEnd = nextNonspace
            while runEnd < lineEnd, bytes[runEnd] == first { runEnd += 1 }
            if Self.isBlank(bytes, runEnd, lineEnd) {
                closeUnmatchedBlocks()
                nodes[container].kind = .heading
                nodes[container].headingLevel = first == MarkupByte.equals ? 1 : 2
                offset = lineEnd
                lineConsumed = true
                return .leaf
            }
        }

        // Thematic break.
        if !indented && (first == MarkupByte.asterisk || first == MarkupByte.dash || first == MarkupByte.underscore),
           Self.isThematicBreak(bytes, nextNonspace, lineEnd) {
            closeUnmatchedBlocks()
            guard addChild(.thematicBreak) != nil else { return .none }
            offset = lineEnd
            container = tip
            return .leaf
        }

        // List item.
        if !indented || containerKind == .list, let marker = parseListMarker(containerKind) {
            closeUnmatchedBlocks()
            if nodes[tip].kind != .list || !listsMatch(tip, marker) {
                guard let list = addChild(.list) else { return .none }
                nodes[list].isOrdered = marker.ordered
                nodes[list].listMarker = marker.marker
                nodes[list].listStart = marker.start
            }
            guard let item = addChild(.item) else { return .none }
            nodes[item].isOrdered = marker.ordered
            nodes[item].listMarker = marker.marker
            nodes[item].markerOffset = marker.markerOffset
            nodes[item].padding = marker.padding
            container = tip
            return .container
        }

        // Indented code.
        if indented && nodes[tip].kind != .paragraph && !blank {
            advanceOffset(Self.codeIndent, columns: true)
            closeUnmatchedBlocks()
            guard addChild(.indentedCode) != nil else { return .none }
            container = tip
            return .leaf
        }

        return .none
    }

    private func atxHeadingLevel() -> Int? {
        var index = nextNonspace
        var level = 0
        while index < lineEnd, bytes[index] == MarkupByte.hash, level < 7 {
            index += 1
            level += 1
        }
        guard level >= 1, level <= 6 else { return nil }
        guard index == lineEnd || MarkupByte.isSpaceOrTab(bytes[index]) else { return nil }
        return level
    }

    private struct ListMarker {
        var ordered: Bool
        var marker: UInt8
        var start: Int
        var markerOffset: Int
        var padding: Int
    }

    private mutating func parseListMarker(_ containerKind: Kind) -> ListMarker? {
        guard indent < 4, nextNonspace < lineEnd else { return nil }
        let markerStart = nextNonspace
        let first = bytes[markerStart]
        var markerLength: Int
        var result = ListMarker(ordered: false, marker: first, start: 1, markerOffset: indent, padding: 0)
        if first == MarkupByte.asterisk || first == MarkupByte.plus || first == MarkupByte.dash {
            markerLength = 1
        } else if MarkupByte.isDigit(first) {
            var index = markerStart
            var value = 0
            while index < lineEnd, MarkupByte.isDigit(bytes[index]), index - markerStart < 9 {
                value = value * 10 + Int(bytes[index] - 0x30)
                index += 1
            }
            guard index < lineEnd, bytes[index] == MarkupByte.dot || bytes[index] == MarkupByte.closeParen
            else { return nil }
            guard containerKind != .paragraph || value == 1 else { return nil }
            result.ordered = true
            result.start = value
            result.marker = bytes[index]
            markerLength = index - markerStart + 1
        } else {
            return nil
        }
        let afterMarker = markerStart + markerLength
        if afterMarker < lineEnd && !MarkupByte.isSpaceOrTab(bytes[afterMarker]) { return nil }
        if containerKind == .paragraph && Self.isBlank(bytes, afterMarker, lineEnd) { return nil }

        advanceNextNonspace()
        advanceOffset(markerLength, columns: true)
        let spacesStartColumn = column
        let spacesStartOffset = offset
        repeat {
            advanceOffset(1, columns: true)
        } while column - spacesStartColumn < 5 && offset < lineEnd && MarkupByte.isSpaceOrTab(bytes[offset])
        let blankItem = offset >= lineEnd
        let spacesAfterMarker = column - spacesStartColumn
        if spacesAfterMarker >= 5 || spacesAfterMarker < 1 || blankItem {
            result.padding = markerLength + 1
            column = spacesStartColumn
            offset = spacesStartOffset
            partiallyConsumedTab = false
            if MarkupByte.isSpaceOrTab(byte(at: offset)) { advanceOffset(1, columns: true) }
        } else {
            result.padding = markerLength + spacesAfterMarker
        }
        return result
    }

    private func listsMatch(_ list: Int, _ marker: ListMarker) -> Bool {
        nodes[list].isOrdered == marker.ordered && nodes[list].listMarker == marker.marker
    }

    // MARK: - Tree maintenance

    private static func canContain(_ parent: Kind, _ child: Kind) -> Bool {
        switch parent {
        case .document, .blockQuote, .item: child != .item
        case .list: child == .item
        default: false
        }
    }

    /// Adds a block under the tip (closing blocks that cannot contain it). Returns `nil`
    /// and records the cut when a limit is exceeded.
    private mutating func addChild(_ kind: Kind) -> Int? {
        while !Self.canContain(nodes[tip].kind, kind) { finalize(tip) }
        blocksCreated += 1
        let parentDepth = nodes[tip].containerDepth
        let depth = kind == .blockQuote || kind == .list ? parentDepth + 1 : parentDepth
        if blocksCreated > limits.maximumBlocks || depth > limits.maximumNestingDepth {
            recordCut()
            return nil
        }
        let index = nodes.count
        nodes.append(MarkupBlockTree.Node(kind: kind, parent: tip, sourceStart: lineStart, containerDepth: depth))
        nodes[tip].children.append(index)
        tip = index
        return index
    }

    private mutating func addTableRow(_ table: Int) {
        blocksCreated += 1
        if blocksCreated > limits.maximumBlocks {
            recordCut()
            return
        }
        var cells = Self.splitCells(bytes, offset, lineEnd)
        let columns = nodes[table].tableHeader.count
        if cells.count < columns { cells.append(contentsOf: repeatElement("", count: columns - cells.count)) }
        nodes[table].tableRows.append(cells)
    }

    /// The cut starts at the top-level block that contains the tip, or at the current
    /// line when a new top-level block was being opened.
    private mutating func recordCut() {
        var node = tip
        while node > 0, nodes[node].parent > 0 { node = nodes[node].parent }
        cutOffset = node > 0 ? nodes[node].sourceStart : lineStart
    }

    private mutating func finalize(_ index: Int) {
        nodes[index].isOpen = false
        if nodes[index].kind == .indentedCode {
            while let last = nodes[index].lines.last,
                  Self.isBlank(bytes, last.start, last.end) {
                nodes[index].lines.removeLast()
            }
        }
        tip = max(nodes[index].parent, 0)
    }

    private mutating func closeUnmatchedBlocks() {
        guard !allClosed else { return }
        while oldTip != lastMatchedContainer {
            let parent = nodes[oldTip].parent
            finalize(oldTip)
            oldTip = parent
        }
        allClosed = true
    }

    private mutating func addLine() {
        var extra = 0
        if partiallyConsumedTab {
            offset += 1
            extra = 4 - (column % 4)
            partiallyConsumedTab = false
        }
        nodes[tip].lines.append(.init(lineStart: lineStart, start: min(offset, lineEnd), end: lineEnd,
                                      extraSpaces: extra))
    }

    // MARK: - Cursor

    @inline(__always) private func byte(at index: Int) -> UInt8 { index < lineEnd ? bytes[index] : 0 }

    private mutating func findNextNonspace() {
        var index = offset
        var columns = column
        while index < lineEnd {
            let current = bytes[index]
            if current == MarkupByte.space {
                index += 1
                columns += 1
            } else if current == MarkupByte.tab {
                index += 1
                columns += 4 - (columns % 4)
            } else {
                break
            }
        }
        blank = index >= lineEnd
        nextNonspace = index
        nextNonspaceColumn = columns
        indent = columns - column
        indented = indent >= Self.codeIndent
    }

    private mutating func advanceNextNonspace() {
        offset = nextNonspace
        column = nextNonspaceColumn
        partiallyConsumedTab = false
    }

    private mutating func advanceOffset(_ count: Int, columns: Bool) {
        var remaining = count
        while remaining > 0, offset < lineEnd {
            if bytes[offset] == MarkupByte.tab {
                let charsToTab = 4 - (column % 4)
                if columns {
                    partiallyConsumedTab = charsToTab > remaining
                    let advance = min(remaining, charsToTab)
                    column += advance
                    if !partiallyConsumedTab { offset += 1 }
                    remaining -= advance
                } else {
                    partiallyConsumedTab = false
                    column += charsToTab
                    offset += 1
                    remaining -= 1
                }
            } else {
                partiallyConsumedTab = false
                offset += 1
                column += 1
                remaining -= 1
            }
        }
    }

    private func maybeSpecial(at index: Int) -> Bool {
        guard index < lineEnd else { return false }
        switch bytes[index] {
        case MarkupByte.hash, MarkupByte.backtick, MarkupByte.tilde, MarkupByte.asterisk, MarkupByte.plus,
             MarkupByte.underscore, MarkupByte.equals, MarkupByte.greaterThan, MarkupByte.dash,
             MarkupByte.pipe, MarkupByte.colon, UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return false
        }
    }

    // MARK: - Line predicates (pure)

    static func isBlank(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
        var index = start
        while index < end {
            if !MarkupByte.isSpaceOrTab(bytes[index]) { return false }
            index += 1
        }
        return true
    }

    static func isThematicBreak(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
        let marker = bytes[start]
        var count = 0
        var index = start
        while index < end {
            let current = bytes[index]
            if current == marker {
                count += 1
            } else if !MarkupByte.isSpaceOrTab(current) {
                return false
            }
            index += 1
        }
        return count >= 3
    }

    static func hasUnescapedPipe(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
        var index = start
        while index < end {
            let current = bytes[index]
            if current == MarkupByte.backslash {
                index += 2
                continue
            }
            if current == MarkupByte.pipe { return true }
            index += 1
        }
        return false
    }

    /// Number of cells if `[start, end)` is a GFM delimiter row (`| :--- | ---: |`).
    static func delimiterRowCellCount(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Int? {
        var lower = start
        var upper = end
        while upper > lower, MarkupByte.isSpaceOrTab(bytes[upper - 1]) { upper -= 1 }
        if lower < upper, bytes[lower] == MarkupByte.pipe { lower += 1 }
        if upper > lower, bytes[upper - 1] == MarkupByte.pipe { upper -= 1 }
        guard lower < upper else { return nil }
        var cells = 0
        var index = lower
        while index <= upper {
            var cellEnd = index
            while cellEnd < upper, bytes[cellEnd] != MarkupByte.pipe { cellEnd += 1 }
            var cellStart = index
            var trimmedEnd = cellEnd
            while cellStart < trimmedEnd, MarkupByte.isSpaceOrTab(bytes[cellStart]) { cellStart += 1 }
            while trimmedEnd > cellStart, MarkupByte.isSpaceOrTab(bytes[trimmedEnd - 1]) { trimmedEnd -= 1 }
            if cellStart < trimmedEnd, bytes[cellStart] == MarkupByte.colon { cellStart += 1 }
            if trimmedEnd > cellStart, bytes[trimmedEnd - 1] == MarkupByte.colon { trimmedEnd -= 1 }
            guard trimmedEnd > cellStart else { return nil }
            for position in cellStart..<trimmedEnd where bytes[position] != MarkupByte.dash { return nil }
            cells += 1
            index = cellEnd + 1
        }
        return cells
    }

    /// Splits a table row on unescaped pipes; `\|` becomes `|`, cells are trimmed. Cell
    /// text is otherwise kept verbatim (no inline interpretation).
    static func splitCells(_ bytes: [UInt8], _ start: Int, _ end: Int) -> [String] {
        var lower = start
        var upper = end
        while lower < upper, MarkupByte.isSpaceOrTab(bytes[lower]) { lower += 1 }
        while upper > lower, MarkupByte.isSpaceOrTab(bytes[upper - 1]) { upper -= 1 }
        if lower < upper, bytes[lower] == MarkupByte.pipe { lower += 1 }
        if upper > lower, bytes[upper - 1] == MarkupByte.pipe,
           !(upper - 2 >= lower && bytes[upper - 2] == MarkupByte.backslash) {
            upper -= 1
        }
        var cells: [String] = []
        var cell: [UInt8] = []
        var index = lower
        func finishCell() {
            var cellStart = 0
            var cellEnd = cell.count
            while cellStart < cellEnd, MarkupByte.isSpaceOrTab(cell[cellStart]) { cellStart += 1 }
            while cellEnd > cellStart, MarkupByte.isSpaceOrTab(cell[cellEnd - 1]) { cellEnd -= 1 }
            cells.append(String(decoding: cell[cellStart..<cellEnd], as: UTF8.self))
            cell.removeAll(keepingCapacity: true)
        }
        while index < upper {
            let current = bytes[index]
            if current == MarkupByte.backslash, index + 1 < upper, bytes[index + 1] == MarkupByte.pipe {
                cell.append(MarkupByte.pipe)
                index += 2
                continue
            }
            if current == MarkupByte.pipe {
                finishCell()
            } else {
                cell.append(current)
            }
            index += 1
        }
        finishCell()
        return cells
    }
}
