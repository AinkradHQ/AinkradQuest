import AinkradAppKit
import Foundation

/// One JSON document per project plus one index document.
///
/// Leyline persists everything as a single document, which is right for a
/// handful of connections and wrong here: the sidebar and Today/Inbox would
/// have to decode every work item ever written just to draw a list of project
/// names. The index carries exactly what those surfaces need.
final class DocumentProjectRepository: ProjectRepository {
    private let documents: PluginDocumentStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Keys whose corrupt bytes could not be verified aside. Their originals
    /// are the only copy of the user's data, so the matching save throws
    /// `QuestError.documentCorrupt` rather than overwriting them.
    private var blockedKeys: Set<String> = []

    static let indexKey = "project-index"
    static func projectKey(_ id: UUID) -> String { "project-\(id.uuidString)" }

    init(documents: PluginDocumentStore) {
        self.documents = documents
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadIndex() -> [ProjectSummary] {
        let loaded = loadDocument(
            [ProjectSummary].self, key: Self.indexKey, from: documents, decoder: decoder, app: "quest")
        noteBlocked(loaded.canSave, key: Self.indexKey)
        return loaded.value ?? []
    }

    func saveIndex(_ summaries: [ProjectSummary]) throws {
        try throwIfBlocked(Self.indexKey)
        let data = try encoder.encode(summaries)
        documents.setData(data, forKey: Self.indexKey)
    }

    func loadProject(_ id: UUID) -> ProjectDocument? {
        let key = Self.projectKey(id)
        let loaded = loadDocument(
            ProjectDocument.self, key: key, from: documents, decoder: decoder, app: "quest")
        noteBlocked(loaded.canSave, key: key)
        return loaded.value
    }

    func saveProject(_ document: ProjectDocument) throws {
        let key = Self.projectKey(document.project.id)
        try throwIfBlocked(key)
        let data = try encoder.encode(document)
        documents.setData(data, forKey: key)
    }

    func removeProject(_ id: UUID) {
        documents.setData(nil, forKey: Self.projectKey(id))
    }

    static let connectionsKey = "connection-index"

    func loadConnections() -> [Connection] {
        let loaded = loadDocument(
            [Connection].self, key: Self.connectionsKey, from: documents, decoder: decoder, app: "quest")
        noteBlocked(loaded.canSave, key: Self.connectionsKey)
        return loaded.value ?? []
    }

    func saveConnections(_ connections: [Connection]) throws {
        try throwIfBlocked(Self.connectionsKey)
        let data = try encoder.encode(connections)
        documents.setData(data, forKey: Self.connectionsKey)
    }

    static func overlayKey(_ id: UUID) -> String { "overlay-project-\(id.uuidString)" }
    static let linkMapKey = "link-map"
    static let hubConfigKey = "hub-config"

    func loadOverlay(_ projectID: UUID) throws -> ProjectOverlay? {
        guard let data = documents.data(forKey: Self.overlayKey(projectID)) else { return nil }
        guard let overlay = try? decoder.decode(ProjectOverlay.self, from: data) else {
            throw QuestError.overlayCorrupt(projectID)
        }
        return overlay
    }

    func saveOverlay(_ overlay: ProjectOverlay) throws {
        let data = try encoder.encode(overlay)
        documents.setData(data, forKey: Self.overlayKey(overlay.projectID))
    }

    func removeOverlay(_ projectID: UUID) {
        documents.setData(nil, forKey: Self.overlayKey(projectID))
    }

    func loadLinkMap() -> LinkMap {
        let loaded = loadDocument(
            LinkMap.self, key: Self.linkMapKey, from: documents, decoder: decoder, app: "quest")
        noteBlocked(loaded.canSave, key: Self.linkMapKey)
        return loaded.value ?? LinkMap()
    }

    func saveLinkMap(_ map: LinkMap) throws {
        try throwIfBlocked(Self.linkMapKey)
        documents.setData(try encoder.encode(map), forKey: Self.linkMapKey)
    }

    func loadHubConfig() -> HubConfig {
        let loaded = loadDocument(
            HubConfig.self, key: Self.hubConfigKey, from: documents, decoder: decoder, app: "quest")
        noteBlocked(loaded.canSave, key: Self.hubConfigKey)
        return loaded.value ?? HubConfig()
    }

    func saveHubConfig(_ config: HubConfig) throws {
        try throwIfBlocked(Self.hubConfigKey)
        documents.setData(try encoder.encode(config), forKey: Self.hubConfigKey)
    }

    private func noteBlocked(_ canSave: Bool, key: String) {
        if !canSave { blockedKeys.insert(key) }
    }

    private func throwIfBlocked(_ key: String) throws {
        if blockedKeys.contains(key) { throw QuestError.documentCorrupt(key) }
    }
}
