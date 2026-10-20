import Foundation

enum UpdateFailure: LocalizedError, Equatable {
    case downloadFailed(String)
    case accessRefused
    case feedMissing
    case rateLimited
    case checkInProgress
    case extractFailed(String)
    case noAppInArchive
    case quarantined
    case bundleMismatch
    case repositoryMismatch
    case identityMismatch
    case versionMismatch(expected: String, found: String)
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail):
            return String(localized: "The download did not finish. \(detail)")
        case .accessRefused:
            return String(localized: "GitHub refused access to this build's releases.")
        case .feedMissing:
            return String(localized: "GitHub has no public releases for this build.")
        case .rateLimited:
            return String(localized: "GitHub is limiting update checks from this network.")
        case .checkInProgress:
            return String(localized: "Tinycast is already checking for updates.")
        case .extractFailed(let detail):
            return String(localized: "The downloaded archive could not be expanded. \(detail)")
        case .noAppInArchive:
            return String(localized: "The downloaded archive does not contain Tinycast.")
        case .quarantined:
            return String(
                localized: "macOS quarantined the downloaded app and Tinycast could not clear the flag.")
        case .bundleMismatch:
            return String(localized: "The downloaded app is not this build of Tinycast.")
        case .repositoryMismatch:
            return String(
                localized: "The downloaded app receives updates from a different repository.")
        case .identityMismatch:
            return String(
                localized: "The downloaded app is not signed by the identity this copy was signed with.")
        case .versionMismatch(let expected, let found):
            return String(localized: "The downloaded app is version \(found), not \(expected).")
        case .replaceFailed(let detail):
            return String(localized: "Tinycast could not be replaced. \(detail)")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .identityMismatch, .bundleMismatch, .repositoryMismatch, .versionMismatch:
            return String(
                localized: """
                    Nothing was installed. Download the release from GitHub instead, so you can \
                    check it yourself.
                    """)
        case .replaceFailed:
            return String(
                localized: """
                    Nothing was installed. This usually means /Applications is not writable by \
                    your account.
                    """)
        case .quarantined:
            return String(localized: "Nothing was installed.")
        case .accessRefused:
            return String(localized: "Add or replace the update token in Settings › General.")
        case .feedMissing:
            return String(
                localized: "If its repository is private, add an update token in Settings › General.")
        case .rateLimited:
            return String(localized: "Try again later, or add an update token in Settings › General.")
        case .checkInProgress:
            return String(localized: "Try again in a moment.")
        default:
            return nil
        }
    }
}
