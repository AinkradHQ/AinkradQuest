import AinkradAppKit
import Foundation

@testable import QuestFeature

// Test doubles that used to ship in the production module.

/// Test double. Keeps store tests free of encoding concerns.
public final class InMemoryProjectRepository: ProjectRepository {
    private var index: [ProjectSummary] = []
    private var documents: [UUID: ProjectDocument] = [:]
    private var connections: [Connection] = []
    private var overlays: [UUID: ProjectOverlay] = [:]
    private var linkMap = LinkMap()
    private var hubConfig = HubConfig()

    public init() {}

    public func loadIndex() -> [ProjectSummary] { index }
    public func saveIndex(_ summaries: [ProjectSummary]) { index = summaries }
    public func loadProject(_ id: UUID) -> ProjectDocument? { documents[id] }
    public func saveProject(_ document: ProjectDocument) { documents[document.project.id] = document }
    public func removeProject(_ id: UUID) { documents.removeValue(forKey: id) }
    public func loadConnections() -> [Connection] { connections }
    public func saveConnections(_ connections: [Connection]) { self.connections = connections }

    public func loadOverlay(_ projectID: UUID) throws -> ProjectOverlay? { overlays[projectID] }
    public func saveOverlay(_ overlay: ProjectOverlay) { overlays[overlay.projectID] = overlay }
    public func removeOverlay(_ projectID: UUID) { overlays.removeValue(forKey: projectID) }
    public func loadLinkMap() -> LinkMap { linkMap }
    public func saveLinkMap(_ map: LinkMap) { linkMap = map }
    public func loadHubConfig() -> HubConfig { hubConfig }
    public func saveHubConfig(_ config: HubConfig) { hubConfig = config }
}

/// Test double. Keeps registry tests off the real Keychain, which would
/// otherwise prompt and pollute the developer's login keychain.
/// `@unchecked`: unlocked mutable state, safe because each test owns its
/// instance and drives it from that one test's task.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    public init() {}
    public func secret(forRef ref: String) -> String? { storage[ref] }
    public func setSecret(_ secret: String?, forRef ref: String) throws {
        if let secret { storage[ref] = secret } else { storage.removeValue(forKey: ref) }
    }
}

/// Test double. Keeps UI/view-model tests off a real `gh` subprocess, which
/// would otherwise make them environment-dependent and slow, exactly the
/// reason `InMemoryCredentialStore` exists for `CredentialStore`.
public final class InMemoryGitHubAccountSource: GitHubAccountSource, Sendable {
    private let configuredAccounts: [GitHubAccount]
    private let accountsError: Error?
    private let tokens: [String: String]
    private let tokenError: Error?

    public init(
        accounts: [GitHubAccount] = [],
        accountsError: Error? = nil,
        tokens: [String: String] = [:],
        tokenError: Error? = nil
    ) {
        self.configuredAccounts = accounts
        self.accountsError = accountsError
        self.tokens = tokens
        self.tokenError = tokenError
    }

    public func accounts() throws -> [GitHubAccount] {
        if let accountsError { throw accountsError }
        return configuredAccounts
    }

    public func token(for account: GitHubAccount) throws -> String {
        if let tokenError { throw tokenError }
        guard let token = tokens[account.id] else {
            throw GitHubCLIError.notLoggedIn
        }
        return token
    }
}

extension SnapshotStore {
    /// A minimally-wired store for exercising the observation cadence in
    /// isolation, without a caller needing to construct its own
    /// overlay/documents/projectIDs.
    static func makeForTesting() -> SnapshotStore {
        SnapshotStore(
            overlay: OverlayStore(repository: InMemoryProjectRepository()),
            documents: MemoryDocumentStore(), projectIDs: { [] })
    }
}
