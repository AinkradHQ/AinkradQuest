import Foundation

/// The native tracker as a provider. Its existence is the point of the seam:
/// an unlinked project is not a special case anywhere above this layer.
@MainActor
public final class LocalProvider: WorkProvider {
    public let kind: ProviderKind = .local
    private let store: ProjectStore

    public init(store: ProjectStore) {
        self.store = store
    }

    public func listProjects() async throws -> [RemoteProjectRef] {
        store.projects.map { RemoteProjectRef(key: $0.id.uuidString, name: $0.name) }
    }

    public func statuses(forProjectKey key: String) async throws -> [ProviderStatus] {
        let project = try resolve(key)
        return project.statusScheme.statuses.map {
            ProviderStatus(id: $0.id, label: $0.name, isDone: $0.category == .done)
        }
    }

    public func changes(forProjectKey key: String, since cursor: String?) async throws
        -> (changes: [ProviderChange], cursor: String?)
    {
        // The local store mutates in-process and publishes through
        // `ProjectStore.revision`; nothing polls it. Conforming with an empty
        // result is honest, and keeps every caller provider-agnostic.
        ([], cursor)
    }

    public func write(field: ProviderField, itemKey: String) async throws {
        // Local writes go through `ProjectStore` directly, which is the single
        // mutation point and logs activity. Routing them back through the
        // provider would bypass that, so this is deliberately unimplemented.
        throw QuestError.localWriteMustUseStore
    }

    private func resolve(_ key: String) throws -> Project {
        guard let id = UUID(uuidString: key) else {
            throw QuestError.malformedProjectKey(key)
        }
        guard let project = store.openProject(id)?.project else {
            throw QuestError.projectNotFound(id)
        }
        return project
    }
}
