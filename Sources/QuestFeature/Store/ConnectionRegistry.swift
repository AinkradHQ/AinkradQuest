import Foundation
import Observation

/// The single mutation point for connections, mirroring `ProjectStore`'s shape
/// so the two feel the same to callers. Secrets go to the credential store and
/// never into `connections`, which is persisted in the clear.
@MainActor
@Observable
public final class ConnectionRegistry {
    public private(set) var connections: [Connection] = []
    /// Set when a write to the repository could not be completed. The
    /// in-memory change is kept, exactly as `ProjectStore` does.
    public private(set) var persistenceFailure: String?

    private let repository: any ProjectRepository
    private let credentials: any CredentialStore

    public init(repository: any ProjectRepository, credentials: any CredentialStore) {
        self.repository = repository
        self.credentials = credentials
        self.connections = repository.loadConnections()
    }

    public func connection(_ id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    public func connections(for provider: ProviderKind) -> [Connection] {
        connections.filter { $0.provider == provider }
    }

    public func secret(for id: UUID) -> String? {
        guard let connection = connection(id) else { return nil }
        return credentials.secret(forRef: connection.credentialRef)
    }

    @discardableResult
    public func addConnection(
        provider: ProviderKind, accountLabel: String,
        accountIdentifier: String, baseURL: URL?,
        secret: String, tokenProvenance: TokenProvenance = .manual
    ) throws -> Connection {
        // Same account, same provider is a duplicate. The SAME identifier at a
        // DIFFERENT provider is not — one person's email is their login
        // everywhere.
        let clash = connections.contains {
            $0.provider == provider && $0.accountIdentifier == accountIdentifier
        }
        guard !clash else { throw QuestError.duplicateConnection(accountIdentifier) }

        let connection = Connection(
            id: UUID(), provider: provider,
            accountLabel: accountLabel,
            accountIdentifier: accountIdentifier,
            baseURL: baseURL,
            tokenProvenance: tokenProvenance)
        // The secret is written FIRST: a connection whose credential write
        // failed must not be registered, or the UI shows an account that can
        // never authenticate.
        try credentials.setSecret(secret, forRef: connection.credentialRef)
        connections.append(connection)
        persist()
        return connection
    }

    public func updateConnection(_ connection: Connection) throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else {
            throw QuestError.connectionNotFound(connection.id)
        }
        connections[index] = connection
        persist()
    }

    /// `boundProjectCount` is passed in rather than read, because the registry
    /// deliberately knows nothing about projects — the caller (the settings
    /// view, which holds both) counts them.
    public func removeConnection(_ id: UUID, boundProjectCount: Int) throws {
        guard let index = connections.firstIndex(where: { $0.id == id }) else {
            throw QuestError.connectionNotFound(id)
        }
        guard boundProjectCount == 0 else {
            throw QuestError.connectionInUse(id, boundProjectCount)
        }
        let connection = connections[index]
        connections.remove(at: index)
        // The connection is gone from the registry either way — a failed
        // secret deletion must not block removal, only be reported. Silently
        // swallowing it was deliberate before Task 7's confirm dialog, which
        // now promises the user "its saved token will be deleted"
        // (`ConnectionsSettings.swift`): a swallowed failure would make the
        // app assert a destruction that did not happen, while the token sits
        // in the login keychain.
        var secretDeletionFailure: String?
        do {
            try credentials.setSecret(nil, forRef: connection.credentialRef)
        } catch {
            let message = (error as? CredentialError)?.message ?? error.localizedDescription
            secretDeletionFailure =
                "\(connection.accountLabel) was removed, but its saved token "
                + "could not be deleted from the Keychain: \(message)"
        }
        persist()
        // `persist()` may have just cleared `persistenceFailure` on a
        // successful save, which would otherwise clobber the token-deletion
        // failure above — surface that one whenever the save itself succeeded.
        if let secretDeletionFailure, persistenceFailure == nil {
            persistenceFailure = secretDeletionFailure
        }
    }

    private func persist() {
        do {
            try repository.saveConnections(connections)
            persistenceFailure = nil
        } catch {
            let message =
                (error as? QuestError)?.message
                ?? (error as? CredentialError)?.message
                ?? error.localizedDescription
            persistenceFailure = "Connections could not be saved: \(message)"
        }
    }
}
