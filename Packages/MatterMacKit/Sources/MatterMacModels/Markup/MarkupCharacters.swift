// Byte- and scalar-level classification used by the markup parser. The parser works
// on the UTF-8 bytes of the message: every syntax character is ASCII, so slicing at
// syntax characters always lands on scalar boundaries. Non-ASCII scalars are decoded
// only where a rule needs Unicode classes (flanking, hashtags, e-mail local parts).

enum MarkupByte {
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let backslash = UInt8(ascii: "\\")
    static let backtick = UInt8(ascii: "`")
    static let tilde = UInt8(ascii: "~")
    static let asterisk = UInt8(ascii: "*")
    static let underscore = UInt8(ascii: "_")
    static let hash = UInt8(ascii: "#")
    static let at = UInt8(ascii: "@")
    static let colon = UInt8(ascii: ":")
    static let pipe = UInt8(ascii: "|")
    static let dash = UInt8(ascii: "-")
    static let plus = UInt8(ascii: "+")
    static let dot = UInt8(ascii: ".")
    static let equals = UInt8(ascii: "=")
    static let greaterThan = UInt8(ascii: ">")
    static let lessThan = UInt8(ascii: "<")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let exclamation = UInt8(ascii: "!")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")

    @inline(__always) static func isSpaceOrTab(_ byte: UInt8) -> Bool { byte == space || byte == tab }

    @inline(__always) static func isDigit(_ byte: UInt8) -> Bool { byte &- 0x30 < 10 }

    @inline(__always) static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) &- 0x61 < 26 }

    @inline(__always) static func isAlphanumeric(_ byte: UInt8) -> Bool { isDigit(byte) || isLetter(byte) }

    /// JavaScript `\w` (ASCII letters, digits, underscore), used where Mattermost's
    /// webapp regexes use `\w`/`\b`.
    @inline(__always) static func isWordByte(_ byte: UInt8) -> Bool { isAlphanumeric(byte) || byte == underscore }

    /// ASCII whitespace as used for line-level decisions (space, tab, LF, VT, FF, CR).
    @inline(__always) static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == space || (byte >= 0x09 && byte <= 0x0D)
    }

    /// ASCII punctuation per CommonMark: `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`.
    @inline(__always) static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        (byte >= 0x21 && byte <= 0x2F) || (byte >= 0x3A && byte <= 0x40) || (byte >= 0x5B && byte <= 0x60)
            || (byte >= 0x7B && byte <= 0x7E)
    }

    /// Mattermost username / mention characters `[A-Za-z0-9._-]`.
    @inline(__always) static func isUsernameByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == dot || byte == dash || byte == underscore
    }

    /// Emoji short-name characters `[A-Za-z0-9_+-]`.
    @inline(__always) static func isEmojiNameByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == underscore || byte == plus || byte == dash
    }
}

enum MarkupScalar {
    /// Decodes the scalar starting at `index`. The input is valid UTF-8 (it comes from a
    /// Swift `String`), but decoding is defensive: malformed or truncated sequences
    /// yield U+FFFD with a length of one byte so scanning always makes progress.
    @inline(__always)
    static func decode(_ bytes: [UInt8], at index: Int, end: Int) -> (scalar: Unicode.Scalar, length: Int) {
        let b0 = bytes[index]
        if b0 < 0x80 { return (Unicode.Scalar(b0), 1) }
        return decodeMultibyte(bytes, at: index, end: end, lead: b0)
    }

    private static func decodeMultibyte(_ bytes: [UInt8], at index: Int, end: Int,
                                        lead: UInt8) -> (scalar: Unicode.Scalar, length: Int) {
        let length: Int
        var value: UInt32
        switch lead {
        case 0xC2...0xDF: length = 2; value = UInt32(lead & 0x1F)
        case 0xE0...0xEF: length = 3; value = UInt32(lead & 0x0F)
        case 0xF0...0xF4: length = 4; value = UInt32(lead & 0x07)
        default: return ("\u{FFFD}", 1)
        }
        guard index + length <= end else { return ("\u{FFFD}", 1) }
        for offset in 1..<length {
            let byte = bytes[index + offset]
            guard byte & 0xC0 == 0x80 else { return ("\u{FFFD}", 1) }
            value = (value << 6) | UInt32(byte & 0x3F)
        }
        return (Unicode.Scalar(value) ?? "\u{FFFD}", length)
    }

    /// Decodes the scalar that ends right before `index`, not looking below `lowerBound`.
    @inline(__always)
    static func decode(_ bytes: [UInt8], before index: Int,
                       lowerBound: Int) -> (scalar: Unicode.Scalar, length: Int)? {
        guard index > lowerBound else { return nil }
        let last = bytes[index - 1]
        if last < 0x80 { return (Unicode.Scalar(last), 1) }
        var start = index - 1
        while start > lowerBound, index - start < 4, bytes[start] & 0xC0 == 0x80 { start -= 1 }
        let decoded = decode(bytes, at: start, end: index)
        guard start + decoded.length == index else { return ("\u{FFFD}", 1) }
        return decoded
    }

    /// Unicode whitespace per CommonMark: Zs plus tab, LF, FF, CR.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 { return value == 0x20 || (value >= 0x09 && value <= 0x0D) }
        return scalar.properties.generalCategory == .spaceSeparator
    }

    /// Unicode punctuation per CommonMark 0.31 (general categories P* and S*).
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 { return MarkupByte.isASCIIPunctuation(UInt8(value)) }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// `\p{L}`.
    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 { return MarkupByte.isLetter(UInt8(value)) }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    /// `\p{M}`: combining marks, including variation selectors and the keycap mark.
    static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value >= 0x300 else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// `\p{Nd}`.
    static func isDecimalDigit(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 { return MarkupByte.isDigit(UInt8(value)) }
        return scalar.properties.generalCategory == .decimalNumber
    }

    /// A scalar that continues the preceding grapheme (combining mark, variation
    /// selector, ZWJ). A syntax character followed by one of these is part of a
    /// grapheme such as the keycap `*️⃣` and is kept literal.
    static func extendsGrapheme(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200D || isMark(scalar)
    }

    /// Letters, marks, decimal digits, and underscore: characters that make an
    /// adjacent `@`, `#`, or `~` part of a word rather than the start of a token.
    static func isWordLike(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 { return MarkupByte.isWordByte(UInt8(value)) }
        return isLetter(scalar) || isMark(scalar) || isDecimalDigit(scalar)
    }
}
