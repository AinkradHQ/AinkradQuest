import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("Snapshot store")
struct SnapshotStoreTests {
    private func makeOverlay() -> OverlayStore {
        OverlayStore(repository: InMemoryProjectRepository())
    }

    @Test("with no vault granted, snapshotting reports why rather than failing silently")
    func noGrant() {
        let overlay = makeOverlay()
        let documents = MemoryDocumentStore()
        let store = SnapshotStore(overlay: overlay, documents: documents, projectIDs: { [] })

        let wrote = store.snapshotNow(at: Date(timeIntervalSince1970: 1_756_000_000))

        #expect(wrote == false)
        // A backup that silently does nothing is the worst outcome in this
        // design — the user must be told it is off, not left assuming it works.
        let message = try? #require(store.lastError)
        #expect(message?.isEmpty == false)
        #expect(store.lastSnapshotAt == nil)
    }

    @Test("the grant state is reported for display without acquiring access")
    func grantState() {
        let store = SnapshotStore(
            overlay: makeOverlay(), documents: MemoryDocumentStore(),
            projectIDs: { [] })
        #expect(store.vaultGrant() == .notGranted)
    }

    @Test("a built payload carries every project's overlay and the markers")
    func payloadContents() {
        let overlay = makeOverlay()
        let a = UUID()
        let b = UUID()
        _ = overlay.update(projectID: a) { $0.notes = "alpha" }
        _ = overlay.update(projectID: b) { $0.notes = "beta" }
        overlay.updateHubConfig {
            $0.markReposMigrated(a)
            $0.bind(b, to: ProjectBinding(connectionID: UUID(), remoteProjectKey: "B"))
        }
        let store = SnapshotStore(
            overlay: overlay, documents: MemoryDocumentStore(),
            projectIDs: { [a, b] })

        let snapshot = store.buildSnapshot(at: Date(timeIntervalSince1970: 1_756_000_000))

        #expect(snapshot.overlays.count == 2)
        #expect(snapshot.migratedRepoProjects.contains(a.uuidString))
        #expect(snapshot.version == OverlaySnapshot.currentVersion)
    }

    @Test("bindings are NOT in the payload")
    func bindingsExcluded() throws {
        let overlay = makeOverlay()
        let projectID = UUID()
        overlay.updateHubConfig {
            $0.bind(projectID, to: ProjectBinding(connectionID: UUID(), remoteProjectKey: "SECRET"))
        }
        let store = SnapshotStore(
            overlay: overlay, documents: MemoryDocumentStore(),
            projectIDs: { [projectID] })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store.buildSnapshot(at: Date(timeIntervalSince1970: 1)))
        let text = try #require(String(data: data, encoding: .utf8))

        // Routing is machine-specific: restoring it elsewhere would resurrect
        // bindings to connections that do not exist on that machine.
        #expect(text.contains("SECRET") == false)
    }

    @Test("restoring replaces the live overlay with the snapshot's")
    func restoreReplaces() throws {
        let overlay = makeOverlay()
        let projectID = UUID()
        _ = overlay.update(projectID: projectID) { $0.notes = "current, about to be replaced" }
        let store = SnapshotStore(
            overlay: overlay, documents: MemoryDocumentStore(),
            projectIDs: { [projectID] })

        var restoredOverlay = ProjectOverlay(projectID: projectID)
        restoredOverlay.notes = "from the backup"
        let snapshot = OverlaySnapshot(
            takenAt: Date(timeIntervalSince1970: 1_756_000_000),
            overlays: [restoredOverlay], linkMap: LinkMap(),
            migratedRepoProjects: [], migratedBindingProjects: [])

        try store.apply(snapshot)

        #expect(overlay.overlay(for: projectID).notes == "from the backup")
    }

    @Test("restore is refused, not half-applied, when a project's live overlay is corrupt")
    func restoreBlockedByCorruptLiveOverlay() throws {
        let documents = MemoryDocumentStore()
        let corrupt = UUID()
        let healthy = UUID()
        documents.setData(
            Data("{not json".utf8),
            forKey: DocumentProjectRepository.overlayKey(corrupt))
        let overlay = OverlayStore(repository: DocumentProjectRepository(documents: documents))
        _ = overlay.overlay(for: corrupt)  // triggers the corrupt load
        _ = overlay.update(projectID: healthy) { $0.notes = "should survive untouched" }
        let store = SnapshotStore(
            overlay: overlay, documents: MemoryDocumentStore(),
            projectIDs: { [corrupt, healthy] })

        var restoredHealthy = ProjectOverlay(projectID: healthy)
        restoredHealthy.notes = "from the backup — must NOT land"
        var restoredCorrupt = ProjectOverlay(projectID: corrupt)
        restoredCorrupt.notes = "from the backup"
        let snapshot = OverlaySnapshot(
            takenAt: Date(timeIntervalSince1970: 1),
            overlays: [restoredCorrupt, restoredHealthy],
            linkMap: LinkMap(), migratedRepoProjects: [],
            migratedBindingProjects: [])

        #expect(throws: SnapshotError.restoreBlocked([corrupt])) {
            try store.apply(snapshot)
        }
        // BLOCKER 3/MAJOR 5: refusing must leave EVERY project exactly as it
        // was — not just the corrupt one — because the failure is detected
        // before the loop starts, so nothing is half-applied.
        #expect(overlay.overlay(for: healthy).notes == "should survive untouched")
    }

    @Test("discarding a corrupt overlay clears the block so a later restore can land")
    func discardThenRestoreSucceeds() throws {
        let documents = MemoryDocumentStore()
        let corrupt = UUID()
        documents.setData(
            Data("{not json".utf8),
            forKey: DocumentProjectRepository.overlayKey(corrupt))
        let overlay = OverlayStore(repository: DocumentProjectRepository(documents: documents))
        _ = overlay.overlay(for: corrupt)
        let store = SnapshotStore(
            overlay: overlay, documents: MemoryDocumentStore(),
            projectIDs: { [corrupt] })
        var restored = ProjectOverlay(projectID: corrupt)
        restored.notes = "from the backup"
        let snapshot = OverlaySnapshot(
            takenAt: Date(timeIntervalSince1970: 1),
            overlays: [restored], linkMap: LinkMap(),
            migratedRepoProjects: [], migratedBindingProjects: [])

        overlay.removeOverlay(for: corrupt)  // the discard action wired in QuestSettingsView
        try store.apply(snapshot)

        #expect(overlay.overlay(for: corrupt).notes == "from the backup")
    }

    @Test("restoring a snapshot from a newer Quest is refused, not half-applied")
    func refusesNewerVersion() {
        let overlay = makeOverlay()
        let projectID = UUID()
        _ = overlay.update(projectID: projectID) { $0.notes = "untouched" }
        let store = SnapshotStore(
            overlay: overlay, documents: MemoryDocumentStore(),
            projectIDs: { [projectID] })
        let future = OverlaySnapshot(
            version: OverlaySnapshot.currentVersion + 1,
            takenAt: Date(timeIntervalSince1970: 1),
            overlays: [], linkMap: LinkMap(),
            migratedRepoProjects: [], migratedBindingProjects: [])

        #expect(throws: SnapshotError.unsupportedVersion(OverlaySnapshot.currentVersion + 1)) {
            try store.apply(future)
        }
        // Refusing must leave the live overlay exactly as it was: a half-applied
        // restore destroys the very data the user was trying to recover.
        #expect(overlay.overlay(for: projectID).notes == "untouched")
    }

    @Test("restoring never writes bindings back")
    func restoreLeavesBindingsAlone() throws {
        let overlay = makeOverlay()
        let projectID = UUID()
        let connectionID = UUID()
        overlay.updateHubConfig {
            $0.bind(projectID, to: ProjectBinding(connectionID: connectionID, remoteProjectKey: "LIVE"))
        }
        let store = SnapshotStore(
            overlay: overlay, documents: MemoryDocumentStore(),
            projectIDs: { [projectID] })
        let snapshot = OverlaySnapshot(
            takenAt: Date(timeIntervalSince1970: 1),
            overlays: [], linkMap: LinkMap(),
            migratedRepoProjects: [projectID.uuidString],
            migratedBindingProjects: [])

        try store.apply(snapshot)

        // The machine's own routing survives a restore untouched.
        #expect(overlay.hubConfig().binding(for: projectID)?.remoteProjectKey == "LIVE")
        #expect(overlay.hubConfig().hasMigratedRepos(projectID))
    }

    @Test("tick() does not snapshot before startAutoBackup is called (BLOCKER 1)")
    func tickWithoutStartIsANoOp() throws {
        let documents = MemoryDocumentStore()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-snap-cadence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FolderBookmark.save(folder, forKey: FolderBookmark.vaultRootKey, in: documents)
        } catch {
            withKnownIssue(
                """
                Cannot exercise real security-scoped bookmarks in this test \
                environment: \(error).
                """
            ) { throw error }
            return
        }

        let overlay = makeOverlay()
        let projectID = UUID()
        _ = overlay.update(projectID: projectID) { $0.notes = "edited before startAutoBackup" }
        let store = SnapshotStore(overlay: overlay, documents: documents, projectIDs: { [projectID] })

        // Without `startAutoBackup()`, `observedRevision`/`lastSnapshotRevision`
        // were never seeded, so `tick()` must not write anything.
        store.tick(now: Date(timeIntervalSince1970: 1_756_000_000 + SnapshotCadence.quietPeriod))

        #expect(store.lastSnapshotAt == nil)
    }

    @Test("after startAutoBackup, an overlay change debounces into exactly one snapshot (BLOCKER 1)")
    func autoBackupDebouncesAChange() throws {
        let documents = MemoryDocumentStore()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-snap-cadence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FolderBookmark.save(folder, forKey: FolderBookmark.vaultRootKey, in: documents)
        } catch {
            withKnownIssue(
                """
                Cannot exercise real security-scoped bookmarks in this test \
                environment: \(error).
                """
            ) { throw error }
            return
        }

        let overlay = makeOverlay()
        let projectID = UUID()
        let store = SnapshotStore(overlay: overlay, documents: documents, projectIDs: { [projectID] })
        store.startAutoBackup()
        let start = Date(timeIntervalSince1970: 1_756_000_000)

        // No change yet: ticking must not write.
        store.tick(now: start.addingTimeInterval(SnapshotCadence.quietPeriod))
        #expect(store.lastSnapshotAt == nil)

        _ = overlay.update(projectID: projectID) { $0.notes = "edited" }

        // Still inside the quiet period after the edit: must not write yet.
        store.tick(now: start.addingTimeInterval(SnapshotCadence.quietPeriod + 60))
        #expect(store.lastSnapshotAt == nil)

        // A burst of further edits, each observed by a tick before the
        // quiet period elapses, must not produce multiple snapshots.
        _ = overlay.update(projectID: projectID) { $0.notes = "edited again" }
        store.tick(now: start.addingTimeInterval(SnapshotCadence.quietPeriod + 90))
        #expect(store.lastSnapshotAt == nil)

        // Now the overlay sits quiet for the full period: exactly one write.
        let fireTime = start.addingTimeInterval(SnapshotCadence.quietPeriod + 90 + SnapshotCadence.quietPeriod)
        store.tick(now: fireTime)
        #expect(store.lastSnapshotAt == fireTime)

        // A further tick with nothing changed must NOT write again — a
        // second identical snapshot would rotate away real history.
        store.tick(now: fireTime.addingTimeInterval(SnapshotCadence.quietPeriod))
        #expect(store.lastSnapshotAt == fireTime)
    }

    @Test("flushOnTeardown writes a final snapshot only if something changed since the last one (BLOCKER 1)")
    func flushOnTeardownWritesOnlyIfChanged() throws {
        let documents = MemoryDocumentStore()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-snap-teardown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FolderBookmark.save(folder, forKey: FolderBookmark.vaultRootKey, in: documents)
        } catch {
            withKnownIssue(
                """
                Cannot exercise real security-scoped bookmarks in this test \
                environment: \(error).
                """
            ) { throw error }
            return
        }

        let overlay = makeOverlay()
        let projectID = UUID()
        let store = SnapshotStore(overlay: overlay, documents: documents, projectIDs: { [projectID] })
        store.startAutoBackup()

        // Nothing changed since start: teardown must not write.
        store.flushOnTeardown(now: Date(timeIntervalSince1970: 1))
        #expect(store.lastSnapshotAt == nil)

        // Restart the cadence (flushOnTeardown stops the timer) and make a
        // change — teardown must now write even though the quiet period has
        // not elapsed, since the app is going away regardless.
        store.startAutoBackup()
        _ = overlay.update(projectID: projectID) { $0.notes = "changed right before quitting" }
        let now = Date(timeIntervalSince1970: 2)
        store.flushOnTeardown(now: now)

        #expect(store.lastSnapshotAt == now)
    }

    @Test("a backwards clock that would rotate away the just-written snapshot is reported as failure (MINOR 7)")
    func rotatedAwayImmediatelyIsReported() throws {
        let documents = MemoryDocumentStore()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-snap-clock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            try FolderBookmark.save(folder, forKey: FolderBookmark.vaultRootKey, in: documents)
        } catch {
            withKnownIssue(
                """
                Cannot exercise real security-scoped bookmarks in this test \
                environment: \(error).
                """
            ) {
                throw error
            }
            return
        }

        let snapshotsDir = folder.appendingPathComponent(SnapshotWriter.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        // Five snapshots dated far in the FUTURE relative to the write below —
        // simulating a clock that was set forward and is now corrected
        // backward for the new write.
        for offset in 0..<5 {
            let future = Date(timeIntervalSince1970: 2_000_000_000 + Double(offset))
            try SnapshotWriter.write(
                OverlaySnapshot(
                    takenAt: future, overlays: [], linkMap: LinkMap(),
                    migratedRepoProjects: [], migratedBindingProjects: []),
                into: snapshotsDir)
        }

        let store = SnapshotStore(overlay: makeOverlay(), documents: documents, projectIDs: { [] })
        // Sorts oldest by filename among the six on disk and is deleted by
        // `rotate` (keep = 5) the moment after `snapshotNow` writes it.
        let wrote = store.snapshotNow(at: Date(timeIntervalSince1970: 1_000_000_000))

        #expect(wrote == false)
        #expect(store.lastError?.isEmpty == false)
    }

    @Test("a fresh store with snapshots already on disk reports an age, not never (BLOCKER 2)")
    func lastBackupAtReadsFromDisk() throws {
        let documents = MemoryDocumentStore()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-snap-age-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            try FolderBookmark.save(folder, forKey: FolderBookmark.vaultRootKey, in: documents)
        } catch {
            withKnownIssue(
                """
                Cannot exercise real security-scoped bookmarks in this test \
                environment: \(error).
                """
            ) {
                throw error
            }
            return
        }

        let snapshotsDir = folder.appendingPathComponent(SnapshotWriter.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let taken = Date(timeIntervalSince1970: 1_756_000_000)
        try SnapshotWriter.write(
            OverlaySnapshot(
                takenAt: taken, overlays: [], linkMap: LinkMap(),
                migratedRepoProjects: [], migratedBindingProjects: []),
            into: snapshotsDir)

        // A FRESH store: `lastSnapshotAt` was never set in-memory this
        // session, which is exactly the post-relaunch state that used to
        // render "Never backed up" above a restore list showing real dated
        // snapshots.
        let store = SnapshotStore(overlay: makeOverlay(), documents: documents, projectIDs: { [] })

        #expect(store.lastSnapshotAt == nil)
        #expect(store.lastBackupAt() == taken)
    }

    @Test("a directory with one good snapshot and one garbage file lists both, one restorable one damaged")
    func listingSurfacesDamagedSnapshots() throws {
        let documents = MemoryDocumentStore()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-snap-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            try FolderBookmark.save(folder, forKey: FolderBookmark.vaultRootKey, in: documents)
        } catch {
            // Same sandbox caveat as `FolderBookmarkTests.roundTrip`.
            withKnownIssue(
                """
                Cannot exercise real security-scoped bookmarks in this test \
                environment: \(error).
                """
            ) {
                throw error
            }
            return
        }

        let snapshotsDir = folder.appendingPathComponent(SnapshotWriter.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)

        let good = OverlaySnapshot(
            takenAt: Date(timeIntervalSince1970: 1_756_000_000),
            overlays: [], linkMap: LinkMap(),
            migratedRepoProjects: [], migratedBindingProjects: [])
        try SnapshotWriter.write(good, into: snapshotsDir)

        let garbageName = "quest-overlay-2026-01-01-000000-zzzz.json"
        try Data("not valid json at all".utf8)
            .write(to: snapshotsDir.appendingPathComponent(garbageName))

        let store = SnapshotStore(overlay: makeOverlay(), documents: documents, projectIDs: { [] })
        let entries = store.listSnapshots()

        #expect(entries.count == 2)
        let readable = entries.compactMap { entry -> SnapshotFile? in
            if case .readable(let file) = entry { return file }
            return nil
        }
        let damaged = entries.compactMap { entry -> String? in
            if case .damaged(_, let filename) = entry { return filename }
            return nil
        }
        #expect(readable.count == 1)
        #expect(damaged == [garbageName])
    }
}
