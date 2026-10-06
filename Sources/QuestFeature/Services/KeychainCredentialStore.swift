import Foundation
import Security

/// Generic-password items in the login keychain, one per connection.
/// Plainly `Sendable`: its only state is an immutable service name, and the
/// Keychain calls are thread-safe.
public final class KeychainCredentialStore: CredentialStore, Sendable {
    private let service: String

    public init(service: String = "com.ainkrad.quest") {
        self.service = service
    }

    private func query(_ ref: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
    }

    public func secret(forRef ref: String) -> String? {
        var lookup = query(ref)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String?, forRef ref: String) throws {
        let existing = query(ref)
        guard let secret else {
            let status = SecItemDelete(existing as CFDictionary)
            // Deleting something that was never there is the caller's
            // intended end state, not a failure.
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.keychain(.delete, status)
            }
            return
        }
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(existing as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = existing
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialError.keychain(.save, addStatus) }
            return
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(.save, status) }
    }
}
