import Foundation

/// Only boundary fingerprints are saved; signatures and quoted messages stay in Outlook.
struct ComposerDraftAnchor: Codable, Equatable, Sendable {
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
        prefixFingerprint = Self.fingerprint(prefix)
        suffixFingerprint = Self.fingerprint(suffix)
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
            Self.fingerprint(String(body[..<selection.lowerBound])) == prefixFingerprint,
            Self.fingerprint(String(body[selection.upperBound...])) == suffixFingerprint
        else { return nil }
        return range
    }

    func rangePreservingTrailingLineBreaks(in body: String) -> NSRange? {
        guard let range = range(in: body), let selection = Range(range, in: body) else {
            return nil
        }
        var end = selection.upperBound
        while end > selection.lowerBound {
            let previous = body.index(before: end)
            guard body[previous].isNewline else { break }
            end = previous
        }
        return NSRange(selection.lowerBound..<end, in: body)
    }

    /// A caret invocation is an explicit Insert, even when the saved draft boundary went stale.
    /// Replace still needs a matched boundary or a fresh selection to avoid overwriting other text.
    static func restoredRange(
        in body: String, anchor: ComposerDraftAnchor?, selectedRange: NSRange,
        insertsAtCaret: Bool
    ) -> NSRange? {
        if let range = anchor?.rangePreservingTrailingLineBreaks(in: body) { return range }
        guard Range(selectedRange, in: body) != nil else { return nil }
        return selectedRange.length > 0 || insertsAtCaret ? selectedRange : nil
    }

    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
