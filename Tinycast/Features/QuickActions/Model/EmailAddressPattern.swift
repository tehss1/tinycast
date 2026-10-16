import Foundation

enum EmailAddressPattern {
    struct Match {
        let range: Range<String.Index>
        let domain: String
    }

    private static let expression = try? NSRegularExpression(
        pattern: #"[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@([\p{L}\p{N}](?:[\p{L}\p{N}.-]*[\p{L}\p{N}])?)"#)

    static func matches(in value: String) -> [Match] {
        guard let expression else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .compactMap { match in
                guard let range = Range(match.range, in: value),
                    let domain = Range(match.range(at: 1), in: value)
                else { return nil }
                return Match(range: range, domain: value[domain].lowercased())
            }
    }

    static func recipientDomains(in value: String) -> [String]? {
        guard let entries = recipientEntries(in: value), !entries.isEmpty else { return nil }
        var domains: [String] = []
        for entry in entries {
            let addresses = matches(in: entry)
            guard addresses.count == 1, let address = addresses.first,
                entry.filter({ $0 == "@" }).count == 1
            else { return nil }
            let leading = entry[..<address.range.lowerBound].trimmingCharacters(in: .whitespaces)
            let trailing = entry[address.range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard (leading.isEmpty && trailing.isEmpty)
                || (leading.hasSuffix("<") && trailing == ">")
            else { return nil }
            domains.append(address.domain)
        }
        return domains
    }

    private static func recipientEntries(in value: String) -> [String]? {
        var entries: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var inAddress = false
        for character in value {
            if escaped {
                escaped = false
            } else if character == "\\", quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted {
                if character == "<" {
                    guard !inAddress else { return nil }
                    inAddress = true
                } else if character == ">" {
                    guard inAddress else { return nil }
                    inAddress = false
                } else if character == "," || character == ";" || character.isNewline {
                    guard !inAddress else { return nil }
                    let entry = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !entry.isEmpty { entries.append(entry) }
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        guard !quoted, !inAddress else { return nil }
        let entry = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entry.isEmpty { entries.append(entry) }
        return entries
    }
}
