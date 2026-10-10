import Foundation

/// The read-only GitHub token a private fork's updater presents. docs/features/updates.md
enum UpdateToken {
    /// The Keychain store names an item by UUID, so the one token has one that never changes.
    private static let account = UUID(uuidString: "3A7DEF97-DC54-4EDF-A2E2-511BB4CC5753") ?? UUID()

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
