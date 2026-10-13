import CryptoKit
import Foundation

@main
struct RewriteHistoryKeyTests {
    static func main() throws {
        let store = KeychainSecretStore(scope: "history-key-test-\(UUID().uuidString)")
        defer { try? store.removeSecret(for: RewriteHistoryKey.account) }
        guard let first = RewriteHistoryKey.keychain(store: store),
            let second = RewriteHistoryKey.keychain(store: store)
        else { fatalError("a fresh test scope must create and recover its key") }
        let firstBytes = first.withUnsafeBytes { Data($0) }
        precondition(firstBytes.count == 32)
        precondition(firstBytes == second.withUnsafeBytes { Data($0) })
        for malformed in ["not base64", Data([1, 2, 3]).base64EncodedString()] {
            try store.setSecret(malformed, for: RewriteHistoryKey.account)
            precondition(RewriteHistoryKey.keychain(store: store) == nil)
            let preserved = try store.secret(for: RewriteHistoryKey.account)
            precondition(preserved == malformed)
        }
        print("6 key persistence and invalid-key checks passed")
    }
}
