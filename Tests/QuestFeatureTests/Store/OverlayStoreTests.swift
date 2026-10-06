import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("OverlayStore")
struct OverlayStoreTests {
    private func makeStore() -> OverlayStore {
        OverlayStore(repository: InMemoryProjectRepository())
    }

    @Test("a project with no overlay yet reads as empty, not nil")
    func emptyByDefault() {
        let store = makeStore()
        let overlay = store.overlay(for: UUID())
        #expect(overlay.isEmpty)
        #expect(overlay.notes.isEmpty)
    }

    @Test("updating a project overlay persists and bumps the revision")
    func updateProjectOverlay() {
        let store = makeStore()
        let projectID = UUID()
        let before = store.revision

        store.update(projectID: projectID) { $0.notes = "mine" }

        #expect(store.overlay(for: projectID).notes == "mine")
        #expect(store.revision > before)
    }

    @Test("an item overlay is reachable and mutable through its project")
    func updateItemOverlay() {
        let store = makeStore()
        let projectID = UUID()
        let itemID = UUID()

        store.updateItem(itemID, in: projectID) {
            $0.notes = "item scratch"
            $0.personalOrder = 2
        }

        let item = store.overlay(for: projectID).item(itemID)
        #expect(item?.notes == "item scratch")
        #expect(item?.personalOrder == 2)
    }

    @Test("overlays survive a relaunch")
    func reload() {
        let repository = InMemoryProjectRepository()
        let store = OverlayStore(repository: repository)
        let projectID = UUID()
        let itemID = UUID()
        store.update(projectID: projectID) { $0.notes = "project" }
        store.updateItem(itemID, in: projectID) { $0.notes = "item" }

        let reloaded = OverlayStore(repository: repository)
        #expect(reloaded.overlay(for: projectID).notes == "project")
        #expect(reloaded.overlay(for: projectID).item(itemID)?.notes == "item")
    }

    @Test("clearing the last content prunes the item record")
    func pruning() {
        let store = makeStore()
        let projectID = UUID()
        let itemID = UUID()
        store.updateItem(itemID, in: projectID) { $0.notes = "temp" }
        #expect(store.overlay(for: projectID).item(itemID) != nil)

        store.updateItem(itemID, in: projectID) { $0.notes = "" }

        // An emptied record is removed rather than left as a tombstone: the
        // overlay is the backed-up store, and empty rows accumulate forever.
        #expect(store.overlay(for: projectID).item(itemID) == nil)
    }

    @Test("a personal order of zero is kept, not pruned")
    func zeroOrderSurvives() {
        let store = makeStore()
        let projectID = UUID()
        let itemID = UUID()

        store.updateItem(itemID, in: projectID) { $0.personalOrder = 0 }

        // Top of the list is a real position. Pruning it would silently lose
        // the user's most important item.
        #expect(store.overlay(for: projectID).item(itemID)?.personalOrder == 0)
        #expect(store.overlay(for: projectID).item(itemID) != nil)
    }

    @Test("a failed persist raises the banner and keeps the in-memory change")
    func persistenceFailure() {
        let store = OverlayStore(repository: FailingSaveProjectRepository())
        let projectID = UUID()

        store.update(projectID: projectID) { $0.notes = "kept" }

        #expect(store.overlay(for: projectID).notes == "kept")
        #expect(store.persistenceFailure != nil)
    }

    @Test("the link map and hub config are reachable and persisted")
    func mapsAndConfig() {
        let repository = InMemoryProjectRepository()
        let store = OverlayStore(repository: repository)
        let ref = RemoteRef(connectionID: UUID(), remoteKey: "QST-7")
        let local = UUID()
        let projectID = UUID()

        store.updateLinkMap { $0.link(ref, to: local) }
        store.updateHubConfig {
            $0.bind(
                projectID,
                to: ProjectBinding(
                    connectionID: ref.connectionID,
                    remoteProjectKey: "QST"))
        }

        let reloaded = OverlayStore(repository: repository)
        #expect(reloaded.linkMap().localID(for: ref) == local)
        #expect(reloaded.hubConfig().binding(for: projectID)?.remoteProjectKey == "QST")
    }

    @Test("removing a project's overlay clears it")
    func removal() {
        let store = makeStore()
        let projectID = UUID()
        store.update(projectID: projectID) { $0.notes = "gone soon" }

        store.removeOverlay(for: projectID)

        #expect(store.overlay(for: projectID).isEmpty)
    }

    // MARK: corrupt-overlay handling

    @Test("a corrupt overlay reads as empty and raises the failure message")
    func corruptOverlayReadsEmptyAndRaisesFailure() {
        let documents = MemoryDocumentStore()
        let projectID = UUID()
        documents.setData(
            Data("not json".utf8),
            forKey: DocumentProjectRepository.overlayKey(projectID))
        let repository = DocumentProjectRepository(documents: documents)
        let store = OverlayStore(repository: repository)

        let overlay = store.overlay(for: projectID)

        #expect(overlay.isEmpty)
        #expect(store.persistenceFailure != nil)
    }

    @Test("a write against a corrupt overlay is blocked and does not touch the repository")
    func writeBlockedForCorruptOverlay() {
        let documents = MemoryDocumentStore()
        let projectID = UUID()
        let corruptBytes = Data("not json".utf8)
        documents.setData(corruptBytes, forKey: DocumentProjectRepository.overlayKey(projectID))
        let repository = DocumentProjectRepository(documents: documents)
        let store = OverlayStore(repository: repository)

        // Trigger the load so the store learns the project is unreadable.
        _ = store.overlay(for: projectID)

        store.update(projectID: projectID) { $0.notes = "should not persist" }

        // The stored bytes must be exactly what they were before: proof the
        // write never reached the repository, not just that the in-memory
        // read still looks empty.
        #expect(documents.data(forKey: DocumentProjectRepository.overlayKey(projectID)) == corruptBytes)
        #expect(store.persistenceFailure != nil)
    }

    @Test("a write against a corrupt item overlay is blocked and does not touch the repository")
    func itemWriteBlockedForCorruptOverlay() {
        let documents = MemoryDocumentStore()
        let projectID = UUID()
        let itemID = UUID()
        let corruptBytes = Data("not json".utf8)
        documents.setData(corruptBytes, forKey: DocumentProjectRepository.overlayKey(projectID))
        let repository = DocumentProjectRepository(documents: documents)
        let store = OverlayStore(repository: repository)

        _ = store.overlay(for: projectID)

        store.updateItem(itemID, in: projectID) { $0.notes = "should not persist" }

        #expect(documents.data(forKey: DocumentProjectRepository.overlayKey(projectID)) == corruptBytes)
    }

    @Test("a project whose overlay is simply missing behaves normally")
    func missingOverlayBehavesNormally() {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let store = OverlayStore(repository: repository)
        let projectID = UUID()

        let overlay = store.overlay(for: projectID)
        #expect(overlay.isEmpty)
        #expect(store.persistenceFailure == nil)

        store.update(projectID: projectID) { $0.notes = "fresh project" }

        #expect(store.overlay(for: projectID).notes == "fresh project")
        #expect(store.persistenceFailure == nil)
        #expect(documents.data(forKey: DocumentProjectRepository.overlayKey(projectID)) != nil)
    }
}
