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
}
