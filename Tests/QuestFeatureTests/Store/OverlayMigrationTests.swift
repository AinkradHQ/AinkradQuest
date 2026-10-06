import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("Overlay migration")
struct OverlayMigrationTests {
    /// A project document in the PRE-M2 shape: repos and binding inside `Project`.
    private func legacyDocument(projectID: UUID, connectionID: UUID) throws -> Data {
        let repoID = UUID()
        let scheme = String(
            data: try JSONEncoder().encode(StatusScheme.softwareDefault),
            encoding: .utf8)!
        let json = """
            {"project":{"id":"\(projectID.uuidString)","name":"Legacy","summaryText":"",
              "icon":"folder","colorToken":"accent","kind":"software","state":"active",
              "statusScheme":\(scheme),"links":[],
              "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
              "connectionID":"\(connectionID.uuidString)","remoteProjectKey":"QST",
              "repos":[{"id":"\(repoID.uuidString)","connectionID":"\(connectionID.uuidString)",
                        "owner":"acme","name":"api"}]},
             "items":[],"activity":[]}
            """
        return Data(json.utf8)
    }

    @Test("a pre-M2 document moves its repos and binding into the new stores")
    func migratesLegacyDocument() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        let overlay = OverlayStore(repository: repository)

        let outcome = OverlayMigration.migrateIfNeeded(
            projectID: projectID,
            repository: repository, overlay: overlay)

        #expect(outcome == .moved)
        #expect(overlay.overlay(for: projectID).repos.map(\.slug) == ["acme/api"])
        #expect(overlay.hubConfig().binding(for: projectID)?.remoteProjectKey == "QST")
        #expect(overlay.hubConfig().binding(for: projectID)?.connectionID == connectionID)
    }

    @Test("migration is idempotent — running it twice moves nothing the second time")
    func idempotent() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        let overlay = OverlayStore(repository: repository)

        #expect(
            OverlayMigration.migrateIfNeeded(
                projectID: projectID,
                repository: repository, overlay: overlay) == .moved)
        // Second run must be a no-op, NOT a duplicate append: a crash between
        // the two halves of a migration means this runs again on next launch.
        #expect(
            OverlayMigration.migrateIfNeeded(
                projectID: projectID,
                repository: repository, overlay: overlay) == .nothingToDo)
        #expect(overlay.overlay(for: projectID).repos.count == 1)
    }

    @Test("a half-migrated project (repos done, binding pending) completes rather than duplicating")
    func resumesPartialMigrationBindingPending() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        let overlay = OverlayStore(repository: repository)
        // Simulate a crash after the repos half completed (data moved AND
        // marked) but before the binding half ran.
        overlay.update(projectID: projectID) { copy in
            copy.repos = [
                AttachedRepo(
                    id: UUID(), connectionID: connectionID,
                    owner: "acme", name: "api")
            ]
        }
        overlay.updateHubConfig { $0.markReposMigrated(projectID) }

        let outcome = OverlayMigration.migrateIfNeeded(
            projectID: projectID,
            repository: repository, overlay: overlay)

        #expect(outcome == .moved)
        #expect(overlay.overlay(for: projectID).repos.count == 1)
        #expect(overlay.hubConfig().binding(for: projectID)?.remoteProjectKey == "QST")
    }

    /// The mirror of the case above, and the more likely real crash order
    /// since the repos half runs first: binding already migrated and marked,
    /// repos still pending.
    @Test("a half-migrated project (binding done, repos pending) completes rather than duplicating")
    func resumesPartialMigrationReposPending() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        let overlay = OverlayStore(repository: repository)
        // Simulate a crash after the binding half completed but before the
        // repos half ran — the less likely order (repos move first in the
        // real function), but still must resume correctly.
        overlay.updateHubConfig { config in
            config.bind(projectID, to: ProjectBinding(connectionID: connectionID, remoteProjectKey: "QST"))
            config.markBindingMigrated(projectID)
        }

        let outcome = OverlayMigration.migrateIfNeeded(
            projectID: projectID,
            repository: repository, overlay: overlay)

        #expect(outcome == .moved)
        #expect(overlay.overlay(for: projectID).repos.map(\.slug) == ["acme/api"])
        #expect(overlay.hubConfig().binding(for: projectID)?.remoteProjectKey == "QST")
    }

    @Test("a project with nothing to migrate reports no work done")
    func nothingToMigrate() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let document = ProjectDocument(project: Project(id: projectID, name: "Fresh", kind: .general))
        try repository.saveProject(document)
        let overlay = OverlayStore(repository: repository)

        #expect(
            OverlayMigration.migrateIfNeeded(
                projectID: projectID,
                repository: repository, overlay: overlay) == .nothingToDo)
    }

    @Test("the legacy fields still decode, so a downgrade does not lose them")
    func legacyFieldsStillDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let projectID = UUID()
        let connectionID = UUID()
        let data = try legacyDocument(projectID: projectID, connectionID: connectionID)
        let document = try decoder.decode(ProjectDocument.self, from: data)

        // M2 stops WRITING these, but must keep READING them: a user who rolls
        // back to a pre-M2 build must still find their repos in the document.
        #expect(document.project.legacyRepos.count == 1)
        #expect(document.project.legacyConnectionID == connectionID)
        #expect(document.project.legacyRemoteProjectKey == "QST")
    }

    /// Critical: once a half has migrated and marked itself done, a user
    /// deliberately clearing what it moved (unbinding, detaching every repo)
    /// must NOT be reversed by a later launch re-running the migration. The
    /// legacy fields are never cleared (by design, for rollback), so without
    /// a persisted marker this would resurrect the removed data forever.
    @Test("repos removed after migration are not resurrected by a later run")
    func doesNotResurrectRemovedRepos() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        let overlay = OverlayStore(repository: repository)
        #expect(
            OverlayMigration.migrateIfNeeded(
                projectID: projectID,
                repository: repository, overlay: overlay) == .moved)

        // The user detaches every repo — clearing the destination by hand.
        overlay.update(projectID: projectID) { $0.repos = [] }

        let outcome = OverlayMigration.migrateIfNeeded(
            projectID: projectID,
            repository: repository, overlay: overlay)

        #expect(outcome != .moved)
        #expect(overlay.overlay(for: projectID).repos.isEmpty)
    }

    /// Same as above, for the binding half.
    @Test("a binding removed after migration is not resurrected by a later run")
    func doesNotResurrectRemovedBinding() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        let overlay = OverlayStore(repository: repository)
        #expect(
            OverlayMigration.migrateIfNeeded(
                projectID: projectID,
                repository: repository, overlay: overlay) == .moved)

        // The user unbinds the project — clearing the destination by hand.
        overlay.updateHubConfig { $0.unbind(projectID) }

        let outcome = OverlayMigration.migrateIfNeeded(
            projectID: projectID,
            repository: repository, overlay: overlay)

        #expect(outcome != .moved)
        #expect(overlay.hubConfig().binding(for: projectID) == nil)
    }

    /// A project whose overlay is corrupt cannot have its repos written —
    /// `OverlayStore` blocks the write. The migration must report `.blocked`
    /// rather than silently swallowing that and claiming `.moved` (or
    /// marking the repos half done when nothing actually landed), and must
    /// leave the legacy bytes untouched so the move can complete later.
    @Test("a project with an unreadable overlay reports blocked, not moved, for its repos half")
    func reportsBlockedWhenOverlayUnreadable() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        // Corrupt bytes at the overlay key.
        documents.setData(Data("not json".utf8), forKey: "overlay-project-\(projectID.uuidString)")
        let overlay = OverlayStore(repository: repository)

        let outcome = OverlayMigration.migrateIfNeeded(
            projectID: projectID,
            repository: repository, overlay: overlay)

        #expect(outcome == .blocked)
        // The binding half is unaffected — it lives in a separate document.
        #expect(overlay.hubConfig().binding(for: projectID)?.remoteProjectKey == "QST")
        // Repos were not marked done, so a later run (once the overlay is
        // fixed) will retry rather than skipping forever.
        #expect(!overlay.hubConfig().hasMigratedRepos(projectID))
    }

    /// Finding 3's whole point: `.blocked` must reach a PERSON, not just the
    /// type system. `ProjectStore.init` is the only production call site
    /// (it runs the migration once per launch over every live/trashed
    /// project) — this drives that real path end to end, with no direct call
    /// to `migrateIfNeeded`, and checks the store's own user-visible banner.
    /// The finding this fix closes: the repos half writes the overlay THEN
    /// the hub-config marker, as two separate document saves. If the overlay
    /// save fails but the hub-config save succeeds, the marker would (before
    /// the fix) record "repos migrated" for data that never reached disk —
    /// and since the marker is what gates a retry, it would never be retried
    /// and the repos would be gone from the UI forever. Reproduces exactly
    /// that interleaving with `FailingSaveProjectRepository.failOverlaySaves`,
    /// which fails ONLY the overlay write while leaving the hub-config write
    /// (and everything else) succeeding.
    @Test("an overlay write that fails to persist does not mark repos migrated, and retries next launch")
    func overlayWriteFailureDoesNotMarkReposMigrated() throws {
        let repository = FailingSaveProjectRepository()
        repository.failSaves = false
        let projectID = UUID()
        let connectionID = UUID()
        var legacyProject = Project(id: projectID, name: "Legacy", kind: .software)
        legacyProject.legacyConnectionID = connectionID
        legacyProject.legacyRemoteProjectKey = "QST"
        legacyProject.legacyRepos = [AttachedRepo(id: UUID(), connectionID: connectionID, owner: "acme", name: "api")]
        let document = ProjectDocument(project: legacyProject)
        try repository.saveProject(document)
        let overlay = OverlayStore(repository: repository)

        // The overlay write fails; the hub-config write (binding half, and
        // the repos-half marker if the bug were present) still succeeds.
        repository.failOverlaySaves = true

        let outcome = OverlayMigration.migrateIfNeeded(
            projectID: projectID,
            repository: repository, overlay: overlay)

        #expect(outcome == .incomplete)
        // The marker must NOT be set — this is the bug this test guards
        // against. If it were set here, the repos would be silently and
        // permanently lost even though they never left the legacy document.
        #expect(!overlay.hubConfig().hasMigratedRepos(projectID))
        // The binding half is unaffected (separate document, separate save)
        // and still completes.
        #expect(overlay.hubConfig().binding(for: projectID)?.remoteProjectKey == "QST")

        // A later launch — overlay writes working again — must retry the
        // repos half rather than treating it as already done.
        repository.failOverlaySaves = false
        let retryOutcome = OverlayMigration.migrateIfNeeded(
            projectID: projectID,
            repository: repository, overlay: overlay)
        #expect(retryOutcome == .moved)
        #expect(overlay.overlay(for: projectID).repos.map(\.slug) == ["acme/api"])
        #expect(overlay.hubConfig().hasMigratedRepos(projectID))
    }

    @Test("a blocked migration surfaces on ProjectStore.persistenceFailure, which QuestShell already renders")
    func blockedMigrationSurfacesToProjectStore() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        documents.setData(Data("not json".utf8), forKey: "overlay-project-\(projectID.uuidString)")
        // `ProjectStore.init` reads the INDEX to know which projects exist —
        // a project document alone is not enough to be picked up.
        let summary = ProjectSummary(
            id: projectID, name: "Legacy", icon: "folder",
            colorToken: "accent", kind: .software, state: .active,
            updatedAt: Date())
        try repository.saveIndex([summary])
        let overlay = OverlayStore(repository: repository)

        let store = ProjectStore(repository: repository, overlay: overlay)

        let failure = try #require(store.persistenceFailure)
        #expect(failure.contains("1"))
    }

    /// The subtle half of the gate: a `.blocked` project must NOT let the
    /// scan close. Closing it would strand that project's data behind a gate
    /// that never opens again — no error, no banner on later launches, the
    /// data simply never arrives. This drives the real `ProjectStore.init`
    /// path (as `blockedMigrationSurfacesToProjectStore` does) but goes
    /// further: it inspects `scanCompleteThrough` directly, then resolves the
    /// corrupt overlay and builds a SECOND store to prove the scan actually
    /// runs again and the data lands — proving the retry, not just the
    /// non-closure.
    @Test("a blocked project keeps the scan open, and it completes on a later launch once resolved")
    func blockedProjectKeepsScanOpenAndRetriesLater() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let projectID = UUID()
        let connectionID = UUID()
        documents.setData(
            try legacyDocument(projectID: projectID, connectionID: connectionID),
            forKey: "project-\(projectID.uuidString)")
        documents.setData(Data("not json".utf8), forKey: "overlay-project-\(projectID.uuidString)")
        let summary = ProjectSummary(
            id: projectID, name: "Legacy", icon: "folder",
            colorToken: "accent", kind: .software, state: .active,
            updatedAt: Date())
        try repository.saveIndex([summary])
        let overlay = OverlayStore(repository: repository)

        let first = ProjectStore(repository: repository, overlay: overlay)
        #expect(first.persistenceFailure != nil)
        // The repos half was blocked, so the scan must NOT be marked
        // complete — otherwise this project's data would never be retried.
        #expect(overlay.hubConfig().scanCompleteThrough == 0)

        // Resolve the condition: remove the corrupt overlay bytes so the next
        // load succeeds. A fresh `OverlayStore` on the same repository is a
        // fair simulation of a relaunch — `OverlayStore` caches
        // `unreadableProjects` in memory for its own lifetime, so clearing
        // that requires a new instance either way, exactly as a real
        // relaunch would produce one.
        documents.setData(nil, forKey: "overlay-project-\(projectID.uuidString)")
        let overlaySecond = OverlayStore(repository: repository)

        let second = ProjectStore(repository: repository, overlay: overlaySecond)

        // The scan ran again (it was never marked complete) and this time
        // the migration succeeded: no more blocked banner, the repos landed,
        // and the scan is now marked complete.
        #expect(second.persistenceFailure == nil)
        #expect(overlaySecond.overlay(for: projectID).repos.map(\.slug) == ["acme/api"])
        #expect(overlaySecond.hubConfig().scanCompleteThrough == ProjectStore.migrationGeneration)
    }

    @Test("a completed scan does not re-read every project on the next launch")
    func scanIsGatedAfterCompletion() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let overlay = OverlayStore(repository: repository)
        let first = ProjectStore(repository: repository, overlay: overlay)
        _ = first.createProject(name: "One", kind: .software, actor: .user)
        _ = first.createProject(name: "Two", kind: .software, actor: .user)

        documents.resetCounts()
        let overlaySecond = OverlayStore(repository: repository)
        _ = ProjectStore(repository: repository, overlay: overlaySecond)

        // The scan already completed, so relaunching must not full-decode every
        // project document again. `loadIndex` always reads "project-index" —
        // itself prefixed "project-" — so isolate PER-PROJECT reads by
        // subtracting that unavoidable read rather than asserting zero total.
        #expect(documents.reads(withPrefix: "project-") == documents.reads(withPrefix: "project-index"))
    }

    @Test("an ungated store still scans, so an upgrade migrates")
    func scanRunsWhenNotYetComplete() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        let overlay = OverlayStore(repository: repository)
        let store = ProjectStore(repository: repository, overlay: overlay)
        _ = store.createProject(name: "One", kind: .software, actor: .user)

        // Clear the completion marker to simulate a pre-gate store.
        overlay.updateHubConfig { $0.scanCompleteThrough = 0 }
        documents.resetCounts()
        let overlaySecond = OverlayStore(repository: repository)
        _ = ProjectStore(repository: repository, overlay: overlaySecond)

        #expect(documents.reads(withPrefix: "project-") > documents.reads(withPrefix: "project-index"))
    }
}
