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
        let entries = value.components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return nil }
        var domains: [String] = []
        for entry in entries {
            let addresses = matches(in: entry)
            guard let last = addresses.last,
                entry.filter({ $0 == "@" }).count == addresses.count
            else { return nil }
            let trailing = entry[last.range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " >,\"\t\r"))
            guard trailing.isEmpty else { return nil }
            for (previous, next) in zip(addresses, addresses.dropFirst()) {
                let between = entry[previous.range.upperBound..<next.range.lowerBound]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " >,\"\t\r"))
                guard between.isEmpty || between.hasSuffix("<") else { return nil }
            }
            domains.append(contentsOf: addresses.map(\.domain))
        }
        return domains
    }
}
