import Foundation
import Testing

@testable import QuestFeature

/// Runs against the real keychain, but only under a throwaway service name —
/// never `com.ainkrad.quest`, which holds the user's connection tokens.
@Suite("Keychain credential store")
struct KeychainCredentialStoreTests {
    private static let ref = "quest.test.connection"

    /// Probes the keychain; nil when it is unavailable (headless runner,
    /// locked keychain), so the test skips with a reason instead of failing.
    private func makeStore(_ service: String) -> KeychainCredentialStore? {
        let store = KeychainCredentialStore(service: service)
        do {
            try store.setSecret("probe", forRef: Self.ref)
            return store
        } catch {
            Issue.record("keychain unavailable, skipping: \(error)", severity: .warning)
            return nil
        }
    }

    @Test("a secret round-trips, updates in place and deletes")
    func roundTrip() throws {
        let service = "com.ainkrad.quest.tests.\(UUID().uuidString)"
        guard let store = makeStore(service) else { return }
        defer { try? store.setSecret(nil, forRef: Self.ref) }

        try store.setSecret("token-abc", forRef: Self.ref)
        #expect(store.secret(forRef: Self.ref) == "token-abc")

        try store.setSecret("token-def", forRef: Self.ref)
        #expect(store.secret(forRef: Self.ref) == "token-def")

        try store.setSecret(nil, forRef: Self.ref)
        #expect(store.secret(forRef: Self.ref) == nil)
        // Deleting what is already gone is not an error.
        try store.setSecret(nil, forRef: Self.ref)
    }

    @Test("services are isolated from one another")
    func serviceIsolation() throws {
        let id = UUID().uuidString
        guard let a = makeStore("com.ainkrad.quest.tests.\(id).a") else { return }
        defer { try? a.setSecret(nil, forRef: Self.ref) }
        let b = KeychainCredentialStore(service: "com.ainkrad.quest.tests.\(id).b")
        #expect(b.secret(forRef: Self.ref) == nil)
    }
}
