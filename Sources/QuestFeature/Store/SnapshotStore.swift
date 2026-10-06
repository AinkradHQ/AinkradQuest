import AinkradAppKit
import Foundation
import Observation

/// One snapshot on disk, as the restore list needs to show it.
public struct SnapshotFile: Identifiable, Sendable, Equatable {
    public let url: URL
    public let takenAt: Date
    public let projectCount: Int
    public var id: URL { url }

    public init(url: URL, takenAt: Date, projectCount: Int) {
        self.url = url
        self.takenAt = takenAt
        self.projectCount = projectCount
    }
}

/// One entry in the restore list: a snapshot file that decoded cleanly, or
/// one that is present but unreadable.
///
/// `listSnapshots()` used to silently drop a file it could not decode — which
/// is exactly wrong here: the user reaches this list precisely because
/// something has already gone wrong, and a backup they believe exists
/// vanishing from the UI with no trace is its own failure mode. A damaged
/// entry carries only what is knowable without decoding it (its filename) and
/// is never offerable to `restore(from:)`, which still takes a `SnapshotFile`.
public enum SnapshotEntry: Identifiable, Sendable, Equatable {
    case readable(SnapshotFile)
    /// `url` for identity/display, `filename` for the message — kept
    /// separate so a caller never has to re-derive the name from the URL.
    case damaged(url: URL, filename: String)

    public var id: URL {
        switch self {
        case .readable(let file): file.url
        case .damaged(let url, _): url
        }
    }
}

/// Builds, writes, lists and restores overlay snapshots.
///
/// Every filesystem call goes inside `FolderBookmark.withAccess`, which balances
/// each acquisition with a deferred release. There is deliberately no API here
/// that hands out a resolved, access-started URL.
@MainActor
@Observable
public final class SnapshotStore {
    /// When the last snapshot was successfully written, for the age indicator.
    /// A backup that silently stopped weeks ago is the worst outcome in this
    /// design, so this is surfaced rather than kept internal.
    public private(set) var lastSnapshotAt: Date?
    /// Why the last attempt failed, in `.message` form. Never `localizedDescription`.
    public private(set) var lastError: String?

    /// The age indicator's actual source of truth (BLOCKER 2). `lastSnapshotAt`
    /// is in-memory only, so on every relaunch it reads `nil` and the UI said
    /// "Never backed up" directly above a restore list showing five real
    /// dated snapshots — self-contradictory, and it defeats the one indicator
    /// this design relies on to catch a silently-stopped backup. This derives
    /// the DISPLAYED age from the newest `.readable` entry actually on disk,
    /// falling back to `lastSnapshotAt` so a backup just written this session
    /// (not yet re-listed) still reads as fresh even if listing lags.
    public func lastBackupAt() -> Date? {
        let onDisk = listSnapshots().compactMap { entry -> Date? in
            if case .readable(let file) = entry { return file.takenAt }
            return nil
        }.max()
        return [lastSnapshotAt, onDisk].compactMap { $0 }.max()
    }

    /// Internal, not private, so a test can drive a REAL mutation through
    /// `OverlayStore.update` — the only way to exercise
    /// `withObservationTracking`'s `onChange`.
    let overlay: OverlayStore
    private let documents: any PluginDocumentStore
    private let projectIDs: () -> [UUID]

    // MARK: - BLOCKER 1: automatic cadence

    /// How often `tick()` polls `overlay.revision`. Cheap (an integer
    /// comparison) on every tick that finds nothing changed, so a short
    /// interval costs nothing — it is NOT how often a snapshot is written;
    /// `SnapshotCadence.quietPeriod` governs that.
    static let pollInterval: TimeInterval = 30
    /// Lets macOS coalesce this wakeup into another timer's window instead of
    /// forcing a precise 30-second CPU wake. Half the interval is safe here:
    /// `tick()` is a revision comparison whose only consumer is a debounced
    /// snapshot, so firing anywhere in a 15-second window is indistinguishable.
    static let pollTolerance: TimeInterval = pollInterval * 0.5
    private var pollTimer: Timer?
    /// `overlay.revision` as observed by the most recent `tick()`.
    private(set) var observedRevision: Int?
    /// When `observedRevision` last actually changed.
    private var lastChangeAt: Date = .distantPast
    /// `overlay.revision` as of the last snapshot written — automatic OR
    /// manual, so a "Back up now" click also resets the debounce clock rather
    /// than leaving `tick()` thinking nothing has been backed up since.
    private var lastSnapshotRevision: Int?

    /// Starts the debounced cadence. Called once per `SnapshotStore` instance,
    /// from `QuestApp`. Safe to call again — it simply replaces the timer.
    public func startAutoBackup() {
        observedRevision = overlay.revision
        lastSnapshotRevision = overlay.revision
        lastChangeAt = .distantPast
        observeOverlay()
        // The quiet-period timer still exists, but is now ARMED BY A CHANGE
        // rather than run forever: with no edits, there is no wakeup at all.
        armQuietPeriodTimer()
    }

    /// Re-arms itself on every change — `withObservationTracking` fires once.
    private func observeOverlay() {
        withObservationTracking {
            _ = overlay.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.overlayDidChange(revision: self.overlay.revision, at: Date())
                self.observeOverlay()
            }
        }
    }

    /// Called when `withObservationTracking` reports `overlay.revision` may
    /// have changed. Internal (not `public`) — the real caller is
    /// `observeOverlay()`; tests call it directly to simulate a change
    /// without waiting on Observation's runloop-driven notification.
    func overlayDidChange(revision: Int, at now: Date) {
        if observedRevision != revision {
            observedRevision = revision
            lastChangeAt = now
        }
        armQuietPeriodTimer()
    }

    /// One-shot, replacing any pending one: fires once the quiet period could
    /// have elapsed, then `tick()` decides whether to actually write.
    private func armQuietPeriodTimer() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: SnapshotCadence.quietPeriod,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = Self.pollTolerance
        pollTimer = timer
    }

    /// Stops the timer without writing anything. Called from
    /// `flushOnTeardown()` before its own final check, so the timer never
    /// fires again after the instance is torn down.
    public func stopAutoBackup() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Polls for an overlay change and, once the quiet period has elapsed
    /// with nothing further changing, writes a debounced snapshot. Pure
    /// decision logic lives in `SnapshotCadence`; this just supplies the
    /// current revision/time and acts on the answer.
    func tick(now: Date = Date()) {
        if observedRevision != overlay.revision {
            observedRevision = overlay.revision
            lastChangeAt = now
        }
        guard
            SnapshotCadence.shouldSnapshot(
                currentRevision: overlay.revision,
                lastSnapshotRevision: lastSnapshotRevision,
                lastChangeAt: lastChangeAt, now: now)
        else { return }
        _ = snapshotNow(at: now)
    }

    /// Called from `QuestApp.teardown(instance:)` — see that call site for
    /// whether a genuine app-termination hook exists (it does not; this is
    /// per-instance teardown, the closest hook available). Writes one final
    /// snapshot if anything changed since the last one, so a session that
    /// closes inside the five-minute quiet window is not silently lost.
    public func flushOnTeardown(now: Date = Date()) {
        stopAutoBackup()
        guard
            SnapshotCadence.shouldSnapshotOnTeardown(
                currentRevision: overlay.revision,
                lastSnapshotRevision: lastSnapshotRevision)
        else { return }
        _ = snapshotNow(at: now)
    }

    public init(
        overlay: OverlayStore, documents: any PluginDocumentStore,
        projectIDs: @escaping () -> [UUID]
    ) {
        self.overlay = overlay
        self.documents = documents
        self.projectIDs = projectIDs
    }

    /// Deliberately NOT `public`: `FolderBookmark` is an internal type, and a
    /// public method cannot expose it. Every consumer — the settings view — is
    /// in this module, so internal is sufficient and honest.
    func vaultGrant() -> FolderBookmark.Grant {
        FolderBookmark.grant(forKey: FolderBookmark.vaultRootKey, in: documents)
    }

    /// Collects every project's overlay plus the link map and the migration
    /// markers. Bindings are deliberately excluded — see `OverlaySnapshot`.
    func buildSnapshot(at date: Date) -> OverlaySnapshot {
        let config = overlay.hubConfig()
        let overlays = projectIDs()
            .map { overlay.overlay(for: $0) }
            .filter { !$0.isEmpty }
        return OverlaySnapshot(
            takenAt: date, overlays: overlays, linkMap: overlay.linkMap(),
            migratedRepoProjects: config.migratedRepoProjects,
            migratedBindingProjects: config.migratedBindingProjects)
    }

    /// Writes one snapshot now. Returns whether it was written.
    @discardableResult
    public func snapshotNow(at date: Date = Date()) -> Bool {
        switch vaultGrant() {
        case .notGranted:
            lastError = SnapshotError.vaultNotGranted.message
            return false
        case .unresolvable(let path):
            lastError = SnapshotError.vaultUnresolvable(path).message
            return false
        case .granted:
            break
        }

        let snapshot = buildSnapshot(at: date)
        // MINOR 8: tracks whether the closure ran at all, so the branch below
        // can tell "access itself was lost between vaultGrant() and here" —
        // for which `lastError` must be set to the CURRENT reason,
        // unconditionally — apart from "the closure ran and already set a
        // more specific `lastError` itself."
        var accessAttempted = false
        let written = FolderBookmark.withAccess(
            forKey: FolderBookmark.vaultRootKey,
            in: documents
        ) { root -> Bool in
            accessAttempted = true
            do {
                let directory = root.appendingPathComponent(
                    SnapshotWriter.directoryName,
                    isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true)
                let writtenURL = try SnapshotWriter.write(snapshot, into: directory)
                // Rotation runs only AFTER a successful write, so a failed
                // write never costs the user an existing backup.
                try SnapshotWriter.rotate(in: directory)
                // MINOR 7: rotation sorts by filename (wall-clock at write
                // time). A backwards clock adjustment can make the file just
                // written sort oldest and be deleted by this very rotate —
                // confirm it still exists rather than report success for a
                // backup that is already gone.
                guard FileManager.default.fileExists(atPath: writtenURL.path) else {
                    throw SnapshotError.rotatedAwayImmediately
                }
                return true
            } catch {
                lastError = (error as? SnapshotError ?? .writeFailed(error.localizedDescription)).message
                return false
            }
        }

        guard written == true else {
            // MINOR 8: if the closure never even ran, access was lost between
            // `vaultGrant()` above and this call — set the CURRENT reason
            // unconditionally. The old code only set `lastError` "if it was
            // still nil", so a previous attempt's stale message stayed
            // displayed instead of the real, current one.
            if !accessAttempted {
                lastError = SnapshotError.vaultUnresolvable(nil).message
            }
            return false
        }
        lastSnapshotAt = date
        lastError = nil
        // Resets the debounce clock (BLOCKER 1) for BOTH the automatic
        // cadence and a manual "Back up now" click — either way, the overlay
        // as of this revision is now backed up, so `tick()` must not fire
        // again until something changes past this point.
        lastSnapshotRevision = overlay.revision
        return true
    }

    public func listSnapshots() -> [SnapshotEntry] {
        FolderBookmark.withAccess(
            forKey: FolderBookmark.vaultRootKey,
            in: documents
        ) { root -> [SnapshotEntry] in
            let directory = root.appendingPathComponent(
                SnapshotWriter.directoryName,
                isDirectory: true)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let entries: [(entry: SnapshotEntry, sortKey: Date)] =
                names
                .filter { $0.hasPrefix("quest-overlay-") && $0.hasSuffix(".json") }
                .map { name -> (SnapshotEntry, Date) in
                    let url = directory.appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: url),
                        let snapshot = try? decoder.decode(OverlaySnapshot.self, from: data)
                    else {
                        // No `takenAt` to sort by — a damaged file's mtime is
                        // the best available proxy, so it still lands roughly
                        // in place rather than always sorting to one end.
                        let modified =
                            ((try? FileManager.default
                                .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
                            ?? Date.distantPast
                        return (.damaged(url: url, filename: name), modified)
                    }
                    let file = SnapshotFile(
                        url: url, takenAt: snapshot.takenAt,
                        projectCount: snapshot.overlays.count)
                    return (.readable(file), snapshot.takenAt)
                }
            return entries.sorted { $0.sortKey > $1.sortKey }.map(\.entry)
        } ?? []
    }

    public func restore(from file: SnapshotFile) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: OverlaySnapshot? =
            FolderBookmark.withAccess(
                forKey: FolderBookmark.vaultRootKey, in: documents
            ) { _ in
                guard let data = try? Data(contentsOf: file.url) else { return nil }
                return try? decoder.decode(OverlaySnapshot.self, from: data)
            } ?? nil
        guard let snapshot else { throw SnapshotError.unreadable(file.url.lastPathComponent) }
        try apply(snapshot)
    }

    /// Replaces the live overlay with the snapshot's.
    ///
    /// Two guards run FIRST and throw before anything is written, so a
    /// restore never half-applies:
    /// - the version check (a snapshot from a newer Quest is refused outright)
    /// - a scan for any project in the snapshot whose LIVE overlay is
    ///   currently unreadable — writing over corrupt bytes would destroy them,
    ///   and `OverlayStore.update` already refuses that write and returns
    ///   `false`, which used to be silently discarded here (BLOCKER 3):
    ///   `apply` returned normally, the caller reported success, and the
    ///   corrupt project was left exactly as corrupt as before.
    ///
    /// Because every failure is detected before the loop starts, the loop
    /// itself cannot fail partway through — there is no rollback to write
    /// because there is nothing to roll back.
    ///
    /// Bindings are never written back — routing belongs to this machine, not
    /// to the backup.
    func apply(_ snapshot: OverlaySnapshot) throws {
        guard snapshot.version <= OverlaySnapshot.currentVersion else {
            throw SnapshotError.unsupportedVersion(snapshot.version)
        }
        let blocked = snapshot.overlays.map(\.projectID).filter { overlay.isUnreadable($0) }
        guard blocked.isEmpty else {
            throw SnapshotError.restoreBlocked(blocked)
        }
        for overlayDocument in snapshot.overlays {
            overlay.update(projectID: overlayDocument.projectID) { current in
                current = overlayDocument
            }
        }
        overlay.updateLinkMap { $0 = snapshot.linkMap }
        overlay.updateHubConfig { config in
            config.migratedRepoProjects = snapshot.migratedRepoProjects
            config.migratedBindingProjects = snapshot.migratedBindingProjects
        }
    }
}
