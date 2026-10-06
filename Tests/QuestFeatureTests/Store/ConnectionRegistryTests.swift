import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("ConnectionRegistry")
struct ConnectionRegistryTests {
    private func makeRegistry() -> ConnectionRegistry {
        ConnectionRegistry(
            repository: InMemoryProjectRepository(),
            credentials: InMemoryCredentialStore())
    }

    @Test("adding a connection registers it and stores the secret out of band")
    func add() throws {
        let credentials = InMemoryCredentialStore()
        let registry = ConnectionRegistry(
            repository: InMemoryProjectRepository(),
            credentials: credentials)
        let connection = try registry.addConnection(
            provider: .jira, accountLabel: "Work",
            accountIdentifier: "ahmed@work.com",
            baseURL: URL(string: "https://work.atlassian.net"),
            secret: "token-abc")

        #expect(registry.connections.map(\.accountLabel) == ["Work"])
        #expect(credentials.secret(forRef: connection.credentialRef) == "token-abc")
        #expect(registry.secret(for: connection.id) == "token-abc")
    }

    @Test("two accounts at the same provider coexist")
    func multipleAccounts() throws {
        let registry = makeRegistry()
        _ = try registry.addConnection(
            provider: .jira, accountLabel: "Work",
            accountIdentifier: "ahmed@work.com",
            baseURL: nil, secret: "a")
        _ = try registry.addConnection(
            provider: .jira, accountLabel: "Client",
            accountIdentifier: "ahmed@client.com",
            baseURL: nil, secret: "b")
        #expect(registry.connections.count == 2)
    }

    @Test("the same account at the same provider is refused")
    func duplicate() throws {
        let registry = makeRegistry()
        _ = try registry.addConnection(
            provider: .jira, accountLabel: "Work",
            accountIdentifier: "ahmed@work.com",
            baseURL: nil, secret: "a")
        #expect(throws: QuestError.duplicateConnection("ahmed@work.com")) {
            try registry.addConnection(
                provider: .jira, accountLabel: "Same Again",
                accountIdentifier: "ahmed@work.com",
                baseURL: nil, secret: "b")
        }
        #expect(registry.connections.count == 1)
    }

    @Test("the same account identifier at a different provider is allowed")
    func sameIdentifierDifferentProvider() throws {
        let registry = makeRegistry()
        _ = try registry.addConnection(
            provider: .jira, accountLabel: "Jira",
            accountIdentifier: "ahmed", baseURL: nil, secret: "a")
        _ = try registry.addConnection(
            provider: .linear, accountLabel: "Linear",
            accountIdentifier: "ahmed", baseURL: nil, secret: "b")
        #expect(registry.connections.count == 2)
    }

    @Test("removing a connection that projects are bound to is refused")
    func removeInUse() throws {
        let registry = makeRegistry()
        let connection = try registry.addConnection(
            provider: .linear, accountLabel: "L",
            accountIdentifier: "l", baseURL: nil, secret: "s")
        #expect(throws: QuestError.connectionInUse(connection.id, 2)) {
            try registry.removeConnection(connection.id, boundProjectCount: 2)
        }
        #expect(registry.connections.count == 1)
    }

    @Test("removing an unused connection also deletes its secret")
    func remove() throws {
        let credentials = InMemoryCredentialStore()
        let registry = ConnectionRegistry(
            repository: InMemoryProjectRepository(),
            credentials: credentials)
        let connection = try registry.addConnection(
            provider: .linear, accountLabel: "L",
            accountIdentifier: "l", baseURL: nil, secret: "s")
        try registry.removeConnection(connection.id, boundProjectCount: 0)

        #expect(registry.connections.isEmpty)
        #expect(credentials.secret(forRef: connection.credentialRef) == nil)
    }

    @Test("connections survive a relaunch")
    func reload() throws {
        let repository = InMemoryProjectRepository()
        let credentials = InMemoryCredentialStore()
        let registry = ConnectionRegistry(repository: repository, credentials: credentials)
        _ = try registry.addConnection(
            provider: .githubProjects, accountLabel: "GH",
            accountIdentifier: "AhmedMElhalaby",
            baseURL: nil, secret: "gh-token")

        let reloaded = ConnectionRegistry(repository: repository, credentials: credentials)
        #expect(reloaded.connections.map(\.accountLabel) == ["GH"])
        #expect(reloaded.secret(for: reloaded.connections[0].id) == "gh-token")
    }

    @Test("a failed secret deletion still removes the connection, and surfaces via persistenceFailure")
    func removeSurfacesAFailedSecretDeletion() throws {
        let credentials = DeleteFailingCredentialStore()
        let registry = ConnectionRegistry(
            repository: InMemoryProjectRepository(),
            credentials: credentials)
        let connection = try registry.addConnection(
            provider: .linear, accountLabel: "L",
            accountIdentifier: "l", baseURL: nil, secret: "s")

        try registry.removeConnection(connection.id, boundProjectCount: 0)

        #expect(registry.connections.isEmpty)
        let failure = try #require(registry.persistenceFailure)
        #expect(failure.lowercased().contains("token"))
    }

    @Test("a failed persist raises the banner and keeps the in-memory change")
    func persistenceFailure() throws {
        let repository = FailingSaveProjectRepository()
        let registry = ConnectionRegistry(
            repository: repository,
            credentials: InMemoryCredentialStore())
        _ = try registry.addConnection(
            provider: .linear, accountLabel: "L",
            accountIdentifier: "l", baseURL: nil, secret: "s")
        #expect(registry.connections.count == 1)
        #expect(registry.persistenceFailure != nil)
    }
}
