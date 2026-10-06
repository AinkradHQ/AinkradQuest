import AinkradAppKit
import Foundation
import Testing

@testable import QuestFeature

@Suite("DocumentProjectRepository")
struct DocumentProjectRepositoryTests {
    @Test("a saved project reloads with its items")
    func roundTrip() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let project = Project(id: UUID(), name: "Quest", kind: .software)
        let item = WorkItem(
            id: UUID(), projectID: project.id, parentID: nil,
            type: .epic, title: "M1", statusID: "todo")

        try repository.saveProject(ProjectDocument(project: project, items: [item]))

        let reloaded = repository.loadProject(project.id)
        #expect(reloaded?.project.name == "Quest")
        #expect(reloaded?.items.first?.title == "M1")
    }

    @Test("each project is its own document, keyed by id")
    func perProjectDocuments() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let a = Project(id: UUID(), name: "A", kind: .software)
        let b = Project(id: UUID(), name: "B", kind: .general)

        try repository.saveProject(ProjectDocument(project: a))
        try repository.saveProject(ProjectDocument(project: b))

        #expect(documents.keys.contains("project-\(a.id.uuidString)"))
        #expect(documents.keys.contains("project-\(b.id.uuidString)"))
    }

    @Test("the index survives a round trip and is readable without project documents")
    func index() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let project = Project(id: UUID(), name: "Ainkrad", kind: .software)

        try repository.saveIndex([project.summary])

        #expect(repository.loadIndex().map(\.name) == ["Ainkrad"])
        #expect(repository.loadProject(project.id) == nil)
    }

    @Test("an empty store yields an empty index rather than failing")
    func emptyStore() {
        #expect(DocumentProjectRepository(documents: MemoryDocumentStore()).loadIndex().isEmpty)
    }

    @Test("removing a project deletes its document")
    func remove() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let project = Project(id: UUID(), name: "Gone", kind: .general)
        try repository.saveProject(ProjectDocument(project: project))

        repository.removeProject(project.id)

        #expect(repository.loadProject(project.id) == nil)
    }

    @Test(
        "a corrupt document is set aside, not overwritten",
        arguments: [
            "project-index", "connection-index", "link-map", "hub-config",
        ])
    func corruptDocumentIsSetAsideNotOverwritten(key: String) throws {
        let seed = Data("{not json".utf8)
        let documents = MemoryDocumentStore()
        documents.setData(seed, forKey: key)
        let repository = DocumentProjectRepository(documents: documents)

        try loadAndSaveEmpty(repository, key: key)

        let backups = documents.keys.filter { $0.hasPrefix("\(key).corrupt-") }
        #expect(backups.count == 1, "corrupt bytes were not set aside")
        #expect(documents.data(forKey: backups.first ?? "") == seed, "backup does not hold the seed bytes")
    }

    @Test("a corrupt project document is set aside, not overwritten")
    func corruptProjectDocumentIsSetAsideNotOverwritten() throws {
        let id = UUID()
        let key = "project-\(id.uuidString)"
        let seed = Data("{not json".utf8)
        let documents = MemoryDocumentStore()
        documents.setData(seed, forKey: key)
        let repository = DocumentProjectRepository(documents: documents)

        #expect(repository.loadProject(id) == nil)
        try repository.saveProject(ProjectDocument(project: Project(id: id, name: "Back", kind: .general)))

        let backups = documents.keys.filter { $0.hasPrefix("\(key).corrupt-") }
        #expect(backups.count == 1, "corrupt bytes were not set aside")
        #expect(documents.data(forKey: backups.first ?? "") == seed, "backup does not hold the seed bytes")
    }

    @Test(
        "an unverifiable set-aside blocks the save and keeps the original",
        arguments: [
            "project-index", "connection-index", "link-map", "hub-config",
        ])
    func unverifiableSetAsideKeepsOriginalAndStopsSaving(key: String) {
        let seed = Data("{not json".utf8)
        let documents = RejectingCorruptDocs()
        documents.setData(seed, forKey: key)
        let repository = DocumentProjectRepository(documents: documents)

        #expect(throws: QuestError.documentCorrupt(key)) {
            try loadAndSaveEmpty(repository, key: key)
        }
        #expect(documents.data(forKey: key) == seed, "the only copy of the user's data was overwritten")
    }

    @Test("an unverifiable project set-aside blocks the save and keeps the original")
    func unverifiableProjectSetAsideKeepsOriginalAndStopsSaving() {
        let id = UUID()
        let key = "project-\(id.uuidString)"
        let seed = Data("{not json".utf8)
        let documents = RejectingCorruptDocs()
        documents.setData(seed, forKey: key)
        let repository = DocumentProjectRepository(documents: documents)

        #expect(repository.loadProject(id) == nil)
        #expect(throws: QuestError.documentCorrupt(key)) {
            try repository.saveProject(ProjectDocument(project: Project(id: id, name: "Back", kind: .general)))
        }
        #expect(documents.data(forKey: key) == seed, "the only copy of the user's data was overwritten")
    }
}

/// Loads the document at `key`, then saves its empty value — the edit that
/// would overwrite corrupt bytes before strict load.
private func loadAndSaveEmpty(_ repository: DocumentProjectRepository, key: String) throws {
    switch key {
    case "project-index":
        _ = repository.loadIndex()
        try repository.saveIndex([])
    case "connection-index":
        _ = repository.loadConnections()
        try repository.saveConnections([])
    case "link-map":
        _ = repository.loadLinkMap()
        try repository.saveLinkMap(LinkMap())
    case "hub-config":
        _ = repository.loadHubConfig()
        try repository.saveHubConfig(HubConfig())
    default:
        Issue.record("unexpected document key \(key)")
    }
}

/// An in-memory `PluginDocumentStore` whose `setData` ignores backup keys,
/// simulating a failed verification read-back after the set-aside write.
private final class RejectingCorruptDocs: PluginDocumentStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) {
        if key.contains(".corrupt-") { return }
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }
}
