import Foundation

enum ComposerAudience: String, Codable, CaseIterable, Equatable, Sendable {
    case internalRecipients = "internal"
    case externalRecipients = "external"

    var title: String {
        switch self {
        case .internalRecipients: "Internal"
        case .externalRecipients: "External"
        }
    }

    var instructions: String {
        switch self {
        case .internalRecipients:
            """
            The recipients are internal coworkers. Use a relaxed, concise and conversational \
            professional tone. Be direct, use natural contractions and avoid client-facing formality.
            """
        case .externalRecipients:
            """
            The recipients include a client, vendor or other external contact. Use a polished, \
            professional and client-safe tone. Be clear and complete, avoid overly casual phrasing \
            and do not make unsupported commitments.
            """
        }
    }

    static func detected(recipient: String?, internalDomains: String) -> Self {
        let approved = normalizedDomains(in: internalDomains)
        guard !approved.isEmpty, let recipient else { return .externalRecipients }
        let recipients = recipientDomains(in: recipient)
        guard !recipients.isEmpty else { return .externalRecipients }
        return recipients.allSatisfy { recipientDomain in
            approved.contains { approvedDomain in
                recipientDomain == approvedDomain
                    || recipientDomain.hasSuffix("." + approvedDomain)
            }
        } ? .internalRecipients : .externalRecipients
    }

    static func normalizedDomains(in value: String) -> [String] {
        var seen = Set<String>()
        return domainEntries(in: value)
            .compactMap { component in
                let domain = normalizedDomain(component)
                guard let domain, seen.insert(domain).inserted
                else { return nil }
                return domain
            }
    }

    static func invalidDomains(in value: String) -> [String] {
        domainEntries(in: value).filter { normalizedDomain($0) == nil }
    }

    private static func domainEntries(in value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",;\n\t "))
            .filter { !$0.isEmpty }
    }

    private static func normalizedDomain(_ value: String) -> String? {
        let domain = value.trimmingCharacters(in: CharacterSet(charactersIn: " @."))
            .lowercased()
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, labels.allSatisfy(validDomainLabel) else { return nil }
        return domain
    }

    private static func validDomainLabel(_ label: Substring) -> Bool {
        guard let first = label.first, let last = label.last,
            first.isLetter || first.isNumber, last.isLetter || last.isNumber
        else { return false }
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func recipientDomains(in value: String) -> [String] {
        let pattern = #"[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@([\p{L}\p{N}](?:[\p{L}\p{N}.-]*[\p{L}\p{N}])?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .compactMap { match in
                guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value)
                else { return nil }
                return value[range].lowercased()
            }
    }
}
