import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("Overlay health")
struct OverlayHealthTests {
    @Test("a fresh store is healthy and not read-only")
    func healthy() {
        let store = OverlayStore(repository: InMemoryProjectRepository())
        #expect(store.health == .healthy)
        #expect(store.health.isReadOnly == false)
        #expect(store.health.message == nil)
    }

    @Test("a corrupt overlay reports unreadable and read-only for that project")
    func unreadable() {
        let documents = MemoryDocumentStore()
        let projectID = UUID()
        documents.setData(
            Data("{not json".utf8),
            forKey: DocumentProjectRepository.overlayKey(projectID))
        let store = OverlayStore(repository: DocumentProjectRepository(documents: documents))

        _ = store.overlay(for: projectID)

        #expect(store.health == .unreadable([projectID]))
        // The cockpit must be able to disable editing without parsing a string.
        #expect(store.health.isReadOnly)
        #expect(store.health.isReadOnly(projectID))
        #expect(store.health.message?.isEmpty == false)
    }

    @Test("two corrupt projects are BOTH tracked, not just the most recent")
    func twoUnreadableProjectsBothTracked() {
        let documents = MemoryDocumentStore()
        let first = UUID()
        let second = UUID()
        documents.setData(
            Data("{not json".utf8),
            forKey: DocumentProjectRepository.overlayKey(first))
        documents.setData(
            Data("{not json".utf8),
            forKey: DocumentProjectRepository.overlayKey(second))
        let store = OverlayStore(repository: DocumentProjectRepository(documents: documents))

        _ = store.overlay(for: first)
        _ = store.overlay(for: second)

        // Before this fix, the second corrupt project overwrote the first's
        // entry, so a cockpit could not answer "is `first` still read-only?".
        #expect(store.health.isReadOnly(first))
        #expect(store.health.isReadOnly(second))
        #expect(store.health == .unreadable([first, second]))
    }

    @Test("an ordinary write failure is a different state from an unreadable overlay")
    func writeFailure() {
        let store = OverlayStore(repository: FailingSaveProjectRepository())

        _ = store.update(projectID: UUID()) { $0.notes = "kept in memory" }

        guard case .writeFailed = store.health else {
            Issue.record("expected .writeFailed, got \(store.health)")
            return
        }
        // A failed save is retryable; an unreadable overlay is not. Collapsing
        // them into one string is what this type exists to prevent.
        #expect(store.health.isReadOnly == false)
    }

    @Test("a successful write does not clear an unresolved unreadable state")
    func successDoesNotMaskUnreadable() {
        let documents = MemoryDocumentStore()
        let corrupt = UUID()
        let healthy = UUID()
        documents.setData(
            Data("{not json".utf8),
            forKey: DocumentProjectRepository.overlayKey(corrupt))
        let store = OverlayStore(repository: DocumentProjectRepository(documents: documents))
        _ = store.overlay(for: corrupt)

        _ = store.update(projectID: healthy) { $0.notes = "unrelated success" }

        // The old `persistenceFailure` was cleared by any later successful
        // write, so a warning could vanish before the user acted on it.
        #expect(store.health == .unreadable([corrupt]))
    }

    @Test("a successful write does not mask an unresolved write-blocked state")
    func successDoesNotMaskWriteBlocked() {
        let documents = MemoryDocumentStore()
        let blocked = UUID()
        let healthy = UUID()
        documents.setData(
            Data("{not json".utf8),
            forKey: DocumentProjectRepository.overlayKey(blocked))
        let store = OverlayStore(repository: DocumentProjectRepository(documents: documents))
        _ = store.overlay(for: blocked)

        _ = store.update(projectID: blocked) { $0.notes = "blocked write" }
        #expect(store.health == .writeBlocked([blocked]))
        #expect(store.health.isReadOnly)

        _ = store.update(projectID: healthy) { $0.notes = "unrelated success" }

        // The unrelated success must not mask the unresolved write-blocked
        // state, same as `.unreadable`.
        #expect(store.health == .writeBlocked([blocked]))
    }
}
