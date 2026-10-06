import AinkradAppKit
import Foundation

@testable import QuestFeature

/// Builds a `ProjectStore` and the `OverlayStore` it needs, both bound to the
/// SAME repository — the shape `QuestApp` uses in production, now that
/// `ProjectStore` no longer builds its own `OverlayStore` internally (a
/// second instance over the same repository would be a second in-memory
/// cache, invisible to the first until reload). Centralized here so every
/// test gets that pairing right without repeating it at each call site.
@MainActor
func makeProjectStore(_ repository: any ProjectRepository) -> ProjectStore {
    ProjectStore(repository: repository, overlay: OverlayStore(repository: repository))
}

/// The MCP operations under test and the store they write through, shared by
/// the three `QuestMCP…OperationsTests` suites.
@MainActor
func makeSubject() -> (QuestMCPOperations, ProjectStore) {
    let store = makeProjectStore(InMemoryProjectRepository())
    return (QuestMCPOperations(store: store), store)
}

/// An in-memory `PluginDocumentStore`, so repository tests exercise the real
/// encode/decode path without a host.
final class MemoryDocumentStore: PluginDocumentStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) {
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }
    var keys: [String] { Array(storage.keys) }
}

/// A `MemoryDocumentStore` that counts reads, so a test can prove work was
/// SKIPPED rather than merely that its result was the same.
final class CountingDocumentStore: PluginDocumentStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private var readCounts: [String: Int] = [:]

    func data(forKey key: String) -> Data? {
        readCounts[key, default: 0] += 1
        return storage[key]
    }

    func setData(_ data: Data?, forKey key: String) {
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }

    func resetCounts() { readCounts.removeAll() }

    func reads(withPrefix prefix: String) -> Int {
        readCounts.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
    }
}

/// A `ProjectRepository` whose `saveProject` REPORTS a failed write by
/// throwing, so tests can verify `ProjectStore.persistenceFailure` without
/// touching disk. `loadIndex`/`saveIndex` still work normally; only project
/// persistence fails until `failSaves` is turned off.
struct SaveFailure: Error {}

final class FailingSaveProjectRepository: ProjectRepository {
    private var index: [ProjectSummary] = []
    private var documents: [UUID: ProjectDocument] = [:]
    private var connections: [Connection] = []
    private var overlays: [UUID: ProjectOverlay] = [:]
    private var linkMap = LinkMap()
    private var hubConfig = HubConfig()
    var failSaves = true
    /// Fails ONLY `saveOverlay`, independent of `failSaves` — lets a test set
    /// up the exact interleaving where the overlay write fails but the
    /// hub-config write (used right after it, e.g. by `OverlayMigration`)
    /// still succeeds.
    var failOverlaySaves = false

    func loadIndex() -> [ProjectSummary] { index }
    func saveIndex(_ summaries: [ProjectSummary]) { index = summaries }
    func loadProject(_ id: UUID) -> ProjectDocument? { documents[id] }
    func saveProject(_ document: ProjectDocument) throws {
        guard !failSaves else { throw SaveFailure() }
        documents[document.project.id] = document
    }
    func removeProject(_ id: UUID) { documents.removeValue(forKey: id) }
    func loadConnections() -> [Connection] { connections }
    func saveConnections(_ connections: [Connection]) throws {
        guard !failSaves else { throw SaveFailure() }
        self.connections = connections
    }

    func loadOverlay(_ projectID: UUID) throws -> ProjectOverlay? { overlays[projectID] }
    func saveOverlay(_ overlay: ProjectOverlay) throws {
        guard !failSaves, !failOverlaySaves else { throw SaveFailure() }
        overlays[overlay.projectID] = overlay
    }
    func removeOverlay(_ projectID: UUID) { overlays.removeValue(forKey: projectID) }
    func loadLinkMap() -> LinkMap { linkMap }
    func saveLinkMap(_ map: LinkMap) throws {
        guard !failSaves else { throw SaveFailure() }
        linkMap = map
    }
    func loadHubConfig() -> HubConfig { hubConfig }
    func saveHubConfig(_ config: HubConfig) throws {
        guard !failSaves else { throw SaveFailure() }
        hubConfig = config
    }
}

/// A `CredentialStore` whose `setSecret` throws on every deletion (a `nil`
/// secret), so tests can verify a failed Keychain delete surfaces rather than
/// being swallowed. Non-deletion writes still succeed, matching
/// `FailingSaveProjectRepository`'s "only the write under test fails" shape.
final class DeleteFailingCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    func secret(forRef ref: String) -> String? { storage[ref] }
    func setSecret(_ secret: String?, forRef ref: String) throws {
        guard let secret else { throw CredentialError.keychain(.delete, errSecIO) }
        storage[ref] = secret
    }
}
