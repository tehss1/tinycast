import CryptoKit
import Foundation

/// The key that seals Composer history, kept in Keychain so the file alone reveals nothing.
enum RewriteHistoryKey {
    static let account = UUID(
        uuid: (
            0x6B, 0x1E, 0x90, 0x4C, 0x2F, 0xA3, 0x4D, 0x71,
            0x8C, 0x05, 0xE7, 0x3A, 0x9D, 0x62, 0xB4, 0x18
        ))

    /// A Keychain error yields no key rather than a new one, which would orphan the saved history.
    static func keychain(store: KeychainSecretStore = .historyKey) -> SymmetricKey? {
        do {
            if let stored = try store.secret(for: account) {
                return decoded(stored)
            }
            let key = SymmetricKey(size: .bits256)
            let encoded = key.withUnsafeBytes { Data($0).base64EncodedString() }
            if try store.addSecretIfAbsent(encoded, for: account) { return key }
            guard let stored = try store.secret(for: account) else { return nil }
            return decoded(stored)
        } catch {
            return nil
        }
    }

    private static func decoded(_ stored: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: stored),
            data.count == SymmetricKeySize.bits256.bitCount / 8
        else { return nil }
        return SymmetricKey(data: data)
    }
}
