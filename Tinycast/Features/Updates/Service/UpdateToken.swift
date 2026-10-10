import Foundation

/// The read-only GitHub token a private fork's updater presents. docs/features/updates.md
enum UpdateToken {
    /// The Keychain store names an item by UUID, so the one token has one that never changes.
    private static let account = UUID(
        uuid: (
            0x3A, 0x7D, 0xEF, 0x97, 0xDC, 0x54, 0x4E, 0xDF,
            0xA2, 0xE2, 0x51, 0x1B, 0xB4, 0xCC, 0x57, 0x53
        ))

    static func read() -> String? {
        try? KeychainSecretStore.updateToken.secret(for: account)
    }

    static var isStored: Bool {
        (try? KeychainSecretStore.updateToken.hasSecret(for: account)) ?? false
    }

    static func save(_ token: String) throws {
        try KeychainSecretStore.updateToken.setSecret(token, for: account)
    }

    static func remove() throws {
        try KeychainSecretStore.updateToken.removeSecret(for: account)
    }
}
