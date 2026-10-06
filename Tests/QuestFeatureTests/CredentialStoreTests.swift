import Foundation
import Testing

@testable import QuestFeature

@Suite("Credential store")
struct CredentialStoreTests {
    @Test("a stored secret reads back by ref")
    func roundTrip() throws {
        let store = InMemoryCredentialStore()
        try store.setSecret("token-abc", forRef: "quest.connection.A")
        #expect(store.secret(forRef: "quest.connection.A") == "token-abc")
    }

    @Test("a nil secret deletes the entry")
    func delete() throws {
        let store = InMemoryCredentialStore()
        try store.setSecret("token-abc", forRef: "quest.connection.A")
        try store.setSecret(nil, forRef: "quest.connection.A")
        #expect(store.secret(forRef: "quest.connection.A") == nil)
    }

    @Test("a keychain failure's message is not Foundation's generic localizedDescription string")
    func keychainErrorHasAReadableMessage() {
        let error = CredentialError.keychain(.save, -25291)  // errSecNotAvailable
        #expect(error.message.contains("-25291"))
        #expect(!error.message.contains("couldn't be completed"))
        #expect((error as any Error).localizedDescription == error.message)
    }

    @Test("a save failure's message says save, not delete")
    func saveFailureMessageSaysSave() {
        let error = CredentialError.keychain(.save, -25291)
        #expect(error.message.contains("save"))
        #expect(!error.message.contains("delete"))
    }

    @Test("a delete failure's message says delete, not save")
    func deleteFailureMessageSaysDelete() {
        let error = CredentialError.keychain(.delete, -25291)
        #expect(error.message.contains("delete"))
        #expect(!error.message.contains("save"))
    }

    @MainActor
    @Test("removeConnection's composed message on a failed Keychain delete does not say save")
    func removeConnectionComposedMessageDoesNotSaySave() throws {
        let repository = FailingSaveProjectRepository()
        repository.failSaves = false
        let credentials = DeleteFailingCredentialStore()
        let registry = ConnectionRegistry(repository: repository, credentials: credentials)
        let connection = try registry.addConnection(
            provider: .jira, accountLabel: "Acme",
            accountIdentifier: "acme@example.com",
            baseURL: nil, secret: "token")
        try registry.removeConnection(connection.id, boundProjectCount: 0)
        let message = try #require(registry.persistenceFailure)
        #expect(message.contains("could not be deleted"))
        // Not a plain `contains("save")`: the surrounding sentence legitimately
        // says "saved token" — it's the CredentialError's own verb that must
        // not say "save" on a delete failure.
        #expect(!message.contains("Could not save"))
    }

    @Test("refs are isolated from one another")
    func isolation() throws {
        let store = InMemoryCredentialStore()
        try store.setSecret("a", forRef: "quest.connection.A")
        try store.setSecret("b", forRef: "quest.connection.B")
        #expect(store.secret(forRef: "quest.connection.A") == "a")
        #expect(store.secret(forRef: "quest.connection.B") == "b")
    }
}
