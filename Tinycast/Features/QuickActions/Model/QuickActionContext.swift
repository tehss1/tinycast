import Foundation

struct QuickActionContext: Equatable, Sendable {
    enum OutlookCaptureBudget {
        static let total: Duration = .milliseconds(750)
        static let maximumCall: Duration = .milliseconds(100)
        static let readingReserve: Duration = .milliseconds(350)
        static let maximumDiscovery: Duration = .milliseconds(250)

        static func discoveryAllowance(elapsed: Duration) -> Duration {
            max(.zero, min(maximumDiscovery, total - elapsed - readingReserve))
        }

        static func shouldDiscover(found: Set<String>, wanted: Set<String>) -> Bool {
            !wanted.isSubset(of: found)
        }

        static func callTimeout(remaining: Duration) -> Float? {
            guard remaining > .zero else { return nil }
            let duration = min(maximumCall, remaining).components
            return Float(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        }
    }

    let recipient: String?
    let subject: String?
    let recentThread: String?
    var documentIdentity: String?
    var threadFingerprints: [String] = []

    var isEmpty: Bool {
        recipient == nil && subject == nil && recentThread == nil
    }

    var isComplete: Bool {
        guard let recipient, EmailAddressPattern.recipientDomains(in: recipient) != nil else { return false }
        return recentThread != nil && subject != nil
    }

    var captureTitle: String {
        if isComplete { return "Email context captured" }
        return isEmpty ? "Email context unavailable" : "Partial email context"
    }

    private static let incompleteRecipientsNotice = "[Additional recipients unavailable]"
    private static let recipientFieldLabels = Set(["to:", "to", "cc:", "cc", "bcc:", "bcc"])
    private static let presenceLabels = Set([
        "presence unknown", "offline", "available", "away", "busy", "do not disturb"
    ])

    static func outlookRecipients(from candidates: [String], captureComplete: Bool = true) -> String? {
        var addresses: [String] = []
        var labels: [String: String] = [:]
        var complete = captureComplete
        for rawCandidate in candidates {
            guard var candidate = cleaned(rawCandidate) else { continue }
            let components = candidate.components(separatedBy: ",")
            if let last = components.last,
                presenceLabels.contains(last.trimmingCharacters(in: .whitespaces).lowercased())
            {
                candidate = components.dropLast().joined(separator: ",")
            }
            let matches = EmailAddressPattern.matches(in: candidate)
            if matches.isEmpty {
                let label = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !label.isEmpty && !recipientFieldLabels.contains(label) { complete = false }
                continue
            }
            if !isSingleChip(candidate, matches: matches),
                EmailAddressPattern.recipientDomains(in: withoutFieldLabel(candidate)) == nil
            {
                complete = false
            }
            for match in matches {
                let range = match.range
                let address = String(candidate[range])
                let key = address.lowercased()
                var name = ""
                if matches.count == 1 {
                    name = String(candidate[..<range.lowerBound])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ,;<>\"\n\t"))
                    if recipientFieldLabels.contains(name.lowercased()) { name = "" }
                }
                let label = name.isEmpty ? address : "\(displayName(name)) <\(address)>"
                if labels[key] == nil { addresses.append(key) }
                if labels[key] == nil || (labels[key]?.contains("<") == false && !name.isEmpty) {
                    labels[key] = label
                }
            }
        }
        var recipients = addresses.compactMap { labels[$0] }
        if !complete { recipients.append(incompleteRecipientsNotice) }
        let result = recipients.joined(separator: "; ")
        return result.isEmpty ? nil : result
    }

    /// Outlook reads a chip as "Name, address": the name may hold commas, nothing may follow.
    private static func isSingleChip(
        _ candidate: String, matches: [EmailAddressPattern.Match]
    ) -> Bool {
        guard matches.count == 1, let range = matches.first?.range else { return false }
        let trailing = candidate[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (trailing.isEmpty || trailing == ">") && !candidate[..<range.lowerBound].contains(";")
    }

    private static func withoutFieldLabel(_ candidate: String) -> String {
        guard let colon = candidate.firstIndex(of: ":"),
            recipientFieldLabels.contains(
                candidate[...colon].trimmingCharacters(in: .whitespaces).lowercased())
        else { return candidate }
        return String(candidate[candidate.index(after: colon)...])
    }

    /// Quoted when it holds a separator, so a comma in a name never reads as a second recipient.
    private static func displayName(_ name: String) -> String {
        guard name.contains(where: { ",;\"<>".contains($0) }) else { return name }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Identifies the email without persisting another copy of the quoted Outlook thread.
    var historyIdentity: String? {
        guard subject != nil || recentThread != nil || documentIdentity != nil else { return nil }
        let material = [subject ?? "", recentThread ?? documentIdentity ?? ""]
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
        " schrieb:", " a écrit:", " escribió:", " ha scritto:", " escreveu:", " schreef:"
    ]

    private static func isMessageBoundary(_ line: String) -> Bool {
        // French puts a space, often non-breaking, before every colon.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{a0}", with: " ")
            .replacingOccurrences(of: " :", with: ":")
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
