import Foundation

struct QuickActionContext: Equatable, Sendable {
    let recipient: String?
    let subject: String?
    let recentThread: String?
    var documentIdentity: String?
    var threadFingerprints: [String] = []

    var isEmpty: Bool {
        recipient == nil && subject == nil && recentThread == nil
    }

    var isComplete: Bool {
        recentThread != nil && recipient != nil && subject != nil
    }

    var captureTitle: String {
        if isComplete { return "Email context captured" }
        return isEmpty ? "Email context unavailable" : "Partial email context"
    }

    static func outlookRecipients(from candidates: [String]) -> String? {
        var addresses: [String] = []
        var labels: [String: String] = [:]
        for candidate in candidates {
            let matches = EmailAddressPattern.matches(in: candidate)
            for match in matches {
                let range = match.range
                let address = String(candidate[range])
                let key = address.lowercased()
                var name = ""
                if matches.count == 1 {
                    name = String(candidate[..<range.lowerBound])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ,;<>\"\n\t"))
                    if ["to:", "to", "cc:", "cc", "bcc:", "bcc"].contains(name.lowercased()) { name = "" }
                }
                let label = name.isEmpty ? address : "\(name) <\(address)>"
                if labels[key] == nil { addresses.append(key) }
                if labels[key] == nil || (labels[key]?.contains("<") == false && !name.isEmpty) {
                    labels[key] = label
                }
            }
        }
        let result = addresses.compactMap { labels[$0] }.joined(separator: "; ")
        return result.isEmpty ? nil : result
    }

    /// Identifies the email without persisting another copy of the quoted Outlook thread.
    var historyIdentity: String? {
        guard !isEmpty || documentIdentity != nil else { return nil }
        let material = [recipient ?? "", subject ?? "", recentThread ?? documentIdentity ?? ""]
            .joined(separator: "\u{1f}")
        return TextFingerprint.of(material)
    }

    var historyFingerprints: [String] {
        if !threadFingerprints.isEmpty { return threadFingerprints }
        guard let recentThread else { return [] }
        return Self.messageSections(in: recentThread).map(TextFingerprint.of)
    }

    private static func messageSections(in thread: String) -> [String] {
        var sections: [String] = []
        var current: [String] = []
        for line in thread.components(separatedBy: .newlines) {
            if isMessageBoundary(line), !current.isEmpty {
                sections.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections
    }

    static func outlook(
        body: String, selectedRange: NSRange, recipient: String?, subject: String?,
        documentIdentity: String? = nil
    ) -> Self? {
        guard let selection = Range(selectedRange, in: body) else { return nil }
        let suffix = String(body[selection.upperBound...])
        let thread = recentOutlookThread(in: suffix)
        let context = Self(
            recipient: cleaned(recipient),
            subject: cleaned(subject),
            recentThread: thread, documentIdentity: documentIdentity,
            threadFingerprints: allThreadFingerprints(in: suffix))
        return context.isEmpty && documentIdentity == nil ? nil : context
    }

    private static let maximumThreadCharacters = 6_000

    private static func allThreadFingerprints(in suffix: String) -> [String] {
        let lines = suffix.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: isMessageBoundary) else { return [] }
        return messageSections(in: lines[start...].joined(separator: "\n")).map(TextFingerprint.of)
    }

    /// Outlook puts sender headers after the draft signature; the third begins older history.
    private static func recentOutlookThread(in suffix: String) -> String? {
        let lines = suffix.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: isMessageBoundary) else { return nil }

        var boundaryCount = 0
        var kept: [String] = []
        for line in lines[start...] {
            if isMessageBoundary(line) {
                boundaryCount += 1
                if boundaryCount == 3 { break }
            }
            kept.append(line)
        }

        let compact = collapseBlankLines(kept.joined(separator: "\n"))
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(maximumThreadCharacters))
    }

    /// Outlook writes the quoted header in the sender's display language, not the reader's.
    private static let senderLabels = ["From:", "Von:", "De:", "Da:", "Van:", "Från:", "Fra:", "Od:"]
    private static let replyAttributions = [
        " schrieb:", " a écrit :", " escribió:", " ha scritto:", " escreveu:", " schreef:"
    ]

    private static func isMessageBoundary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return senderLabels.contains { trimmed.hasPrefix($0) }
            || (trimmed.hasPrefix("On ") && trimmed.hasSuffix(" wrote:"))
            || replyAttributions.contains { trimmed.hasSuffix($0) }
    }

    private static func collapseBlankLines(_ value: String) -> String {
        var output: [String] = []
        var previousWasBlank = false
        for line in value.components(separatedBy: .newlines) {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank && previousWasBlank { continue }
            output.append(line.trimmingCharacters(in: .whitespaces))
            previousWasBlank = blank
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned =
            value
            .replacingOccurrences(of: "\u{fffc}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
