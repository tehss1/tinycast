import Foundation

/// Only boundary fingerprints are saved; signatures and quoted messages stay in Outlook.
struct ComposerDraftAnchor: Codable, Equatable, Sendable {
    struct TextBoundaries: Equatable, Sendable {
        let startsAtLineStart: Bool
        let endsAtLineEnd: Bool
        let followingLineBreakCount: Int
        let selectedLineBreakCount: Int

        var coversWholeLines: Bool { startsAtLineStart && endsAtLineEnd }

        init?(body: String, range: NSRange) {
            guard let selection = Range(range, in: body) else { return nil }
            startsAtLineStart = selection.lowerBound == body.startIndex
                || body[body.index(before: selection.lowerBound)].isNewline
            endsAtLineEnd = selection.upperBound == body.endIndex
                || body[selection.upperBound].isNewline
                || (!selection.isEmpty && body[body.index(before: selection.upperBound)].isNewline)
            followingLineBreakCount = body[selection.upperBound...].prefix(while: \.isNewline).count
            selectedLineBreakCount = body[selection].reversed().prefix(while: \.isNewline).count
        }
    }

    let prefixLength: Int
    let suffixLength: Int
    let prefixFingerprint: String
    let suffixFingerprint: String

    init?(body: String, range: NSRange) {
        guard let selection = Range(range, in: body),
            selection.lowerBound.samePosition(in: body.unicodeScalars) != nil,
            selection.upperBound.samePosition(in: body.unicodeScalars) != nil
        else { return nil }
        let prefix = String(body[..<selection.lowerBound])
        let suffix = String(body[selection.upperBound...])
        prefixLength = prefix.utf16.count
        suffixLength = suffix.utf16.count
        prefixFingerprint = TextFingerprint.of(prefix)
        suffixFingerprint = TextFingerprint.of(suffix)
    }

    func range(in body: String) -> NSRange? {
        let length = body.utf16.count
        guard prefixLength >= 0, suffixLength >= 0,
            prefixLength <= length, suffixLength <= length - prefixLength
        else { return nil }
        let range = NSRange(location: prefixLength, length: length - prefixLength - suffixLength)
        guard let selection = Range(range, in: body),
            selection.lowerBound.samePosition(in: body.unicodeScalars) != nil,
            selection.upperBound.samePosition(in: body.unicodeScalars) != nil,
            TextFingerprint.of(String(body[..<selection.lowerBound])) == prefixFingerprint,
            TextFingerprint.of(String(body[selection.upperBound...])) == suffixFingerprint
        else { return nil }
        return range
    }

    func rangePreservingLineBreaks(in body: String) -> NSRange? {
        guard let range = range(in: body), let selection = Range(range, in: body) else {
            return nil
        }
        return Self.trimmingLineBreaks(selection, in: body)
    }

    /// Insert's paragraph separator lands inside the saved boundary but is never the draft.
    private static func trimmingLineBreaks(
        _ selection: Range<String.Index>, in body: String
    ) -> NSRange {
        var start = selection.lowerBound
        while start < selection.upperBound, body[start].isNewline {
            start = body.index(after: start)
        }
        var end = selection.upperBound
        while end > start {
            let previous = body.index(before: end)
            guard body[previous].isNewline else { break }
            end = previous
        }
        return NSRange(start..<end, in: body)
    }

    /// The saved draft is the target only when the press lands on it; anywhere else wins.
    static func restoredRange(
        in body: String, anchor: ComposerDraftAnchor?, selectedRange: NSRange,
        insertsAtCaret: Bool
    ) -> NSRange? {
        guard let selection = Range(selectedRange, in: body) else { return nil }
        let draft = anchor?.rangePreservingLineBreaks(in: body)
        if !selection.isEmpty {
            guard let draft, trimmingLineBreaks(selection, in: body) == draft else {
                return selectedRange
            }
            return draft
        }
        guard let draft, let saved = anchor?.range(in: body),
            saved.location <= selectedRange.location, selectedRange.location <= NSMaxRange(saved)
        else { return insertsAtCaret ? selectedRange : nil }
        return draft
    }
}
