import Foundation

/// An autocomplete query found immediately before the caret.
nonisolated struct CompletionContext: Hashable, Sendable {
    let trigger: CompletionTrigger
    /// UTF-16 offset of the trigger character in the composer text.
    let triggerLocation: Int
    /// UTF-16 offset of the caret (end of the query).
    let caretLocation: Int
    /// Text between the trigger and the caret (no whitespace, bounded length).
    let query: String

    /// Range replaced when a completion is accepted: trigger plus query.
    var replacementRange: NSRange {
        NSRange(location: triggerLocation, length: caretLocation - triggerLocation)
    }
}

/// Finds `@user`, `~channel`, and `:emoji` queries before the caret.
///
/// Rules (matching the official web client's word-boundary behavior): the trigger
/// must be at the start of the text or directly after whitespace; the query runs
/// from the trigger to the caret, contains no whitespace, and is at most
/// `maximumQueryLength` UTF-16 units; the nearest trigger character to the caret
/// decides (so `name@example` or `10:30` never trigger); emoji need at least two
/// query characters. Work is bounded by the query length, never by the draft size.
nonisolated enum CompletionQueryDetector {
    static let maximumQueryLength = 64

    static func detect(in text: NSString, selection: NSRange) -> CompletionContext? {
        guard selection.location != NSNotFound, selection.length == 0, selection.location <= text.length else {
            return nil
        }
        let caret = selection.location
        if caret > 0, caret <= 513, text.character(at: 0) == 0x2F {
            let query = text.substring(with: NSRange(location: 1, length: caret - 1))
            guard !query.contains(where: \.isNewline) else { return nil }
            return CompletionContext(trigger: .command, triggerLocation: 0, caretLocation: caret, query: query)
        }
        let lowestTriggerLocation = max(0, caret - maximumQueryLength - 1)
        var index = caret
        while index > lowestTriggerLocation {
            let unit = text.character(at: index - 1)
            if isWhitespace(unit) { return nil }
            if let trigger = trigger(for: unit) {
                let triggerLocation = index - 1
                if triggerLocation > 0, !isWhitespace(text.character(at: triggerLocation - 1)) { return nil }
                let queryLength = caret - index
                guard queryLength >= trigger.minimumQueryLength else { return nil }
                let query = text.substring(with: NSRange(location: index, length: queryLength))
                return CompletionContext(trigger: trigger, triggerLocation: triggerLocation, caretLocation: caret,
                                         query: query)
            }
            index -= 1
        }
        return nil
    }

    private static func trigger(for unit: unichar) -> CompletionTrigger? {
        switch unit {
        case 0x40: .user     // @
        case 0x7E: .channel  // ~
        case 0x3A: .emoji    // :
        default: nil
        }
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        // Surrogate halves are never whitespace; `Unicode.Scalar(_:)` rejects them.
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }
}
