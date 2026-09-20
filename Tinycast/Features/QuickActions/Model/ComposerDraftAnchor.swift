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

    /// A blank Outlook draft starts with the line breaks separating the caret from its signature.
    /// Consume that run only at the start of an insertion; delivery puts one normal break back.
    static func deliveryRange(in body: String, selectedRange: NSRange) -> NSRange {
        guard selectedRange.location == 0, selectedRange.length == 0 else { return selectedRange }
        var end = body.startIndex
        while end < body.endIndex, body[end].isNewline { end = body.index(after: end) }
        return NSRange(body.startIndex..<end, in: body)
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
