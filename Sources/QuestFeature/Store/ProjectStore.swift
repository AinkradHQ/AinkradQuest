import Foundation
import Observation

/// The single mutation point. Views and MCP operations both go through it, so
/// activity logging and persistence cannot be bypassed by either.
@MainActor
@Observable
public final class ProjectStore {
    /// Live, non-deleted project summaries — what the sidebar renders.
    public private(set) var projects: [ProjectSummary] = []
    /// Soft-deleted projects, restorable from the trash.
    public private(set) var trashedProjects: [ProjectSummary] = []
    /// Set when a write to the repository could not be completed. Views show a
    /// persistent banner while this is non-nil; the in-memory change is kept.
    public private(set) var persistenceFailure: String?
    /// Bumped once per mutation that passed validation and was applied in
    /// memory. Exists so a view can memoize derived cross-project work instead
    /// of recomputing it on every body pass — see `TodaySurface`. A rejected
    /// mutation (one that throws before reaching `commit`/`createProject`)
    /// never bumps it. A mutation whose PERSIST failed still bumps it: the
    /// in-memory change is kept authoritative behind the `persistenceFailure`
    /// banner (see `persist(_:)`), so a derived-work cache must invalidate to
    /// reflect it too. Treat this counter as "in-memory state changed," not as
    /// "durably saved."
    public private(set) var revision: Int = 0

    private let repository: any ProjectRepository
    /// Where binding/repo data now lives, since M2A moved it out of the
    /// project document. Injected rather than built here: this store must
    /// never construct its own — a second instance over the same repository
    /// would be a second in-memory cache and a second `HubConfig` copy, with
    /// writes through one invisible to the other until reload. `internal`
    /// (not `public`): callers that used to read `Project.connectionID`/
    /// `.repos` directly reach it through `ProjectStore`'s own methods and
    /// the in-module views/extensions below, not by taking `update`/
    /// `updateHubConfig`/`removeOverlay` access on the raw store.
    let overlay: OverlayStore
    /// Raised when a future migration needs every project re-scanned. See
    /// `HubConfig.scanCompleteThrough`.
    static let migrationGeneration = 1
    /// Open documents, cached so repeated reads do not re-decode.
    /// `internal` (not `private`) so Task 7's item API, added as an
    /// `extension ProjectStore` in another file in this module, can reach it.
    var documents: [UUID: ProjectDocument] = [:]
    /// `internal` for the same reason as `documents`.
    var deletedProjectIDs: Set<UUID> = []

    /// An item opened from BASIC mode, waiting for advanced to land on it.
    ///
    /// Basic shows Today and has no list to open an item in, so it escalates.
    /// Without this the escalation LOST the target: `QuestShell` is built fresh
    /// on the mode switch, so `surface` starts `.landing` and `selectedProject`
    /// starts nil — you tapped an item and arrived nowhere near it.
    ///
    /// Lives on the store because the store is the one thing both modes share;
    /// the two root views do not outlive each other.
    public var pendingOpenItem: WorkItem?

    /// Takes and clears the pending item, if any. Consumed exactly once, by
    /// whichever shell mounts next.
    public func takePendingOpenItem() -> WorkItem? {
        defer { pendingOpenItem = nil }
        return pendingOpenItem
    }

    /// `overlay` must be the ONE instance the rest of the app shares for this
    /// repository — `QuestApp` builds it once per host and passes it here.
    public init(repository: any ProjectRepository, overlay: OverlayStore) {
        self.repository = repository
        self.overlay = overlay
        let index = repository.loadIndex()
        let live = index.filter { !$0.isTrashed }.map { summary -> ProjectSummary in
            var summary = summary
            summary.isTrashed = false
            return summary
        }
        let trashed = index.filter { $0.isTrashed }.map { summary -> ProjectSummary in
            var summary = summary
            summary.isTrashed = true
            return summary
        }
        self.projects = live.filter { $0.state != .archived }
            + live.filter { $0.state == .archived }
        self.deletedProjectIDs = Set(trashed.map(\.id))
        self.trashedProjects = trashed
        // Once-per-launch, here rather than on the project-open path (which
        // runs on every open, on the UI hot path). Trashed projects matter
        // too: `severBindings` reaches them, so their bindings must exist to
        // be severed even if they are never opened again before that happens.
        //
        // `.blocked` outcomes are collected rather than discarded: a corrupt
        // overlay means a project's repos silently never arrive, and that
        // must reach a person, not just the type system. Reused
        // `persistenceFailure` (rather than a distinct property) because it
        // is already the store's one user-visible "something needs your
        // attention" banner, already rendered by `QuestShell` — a second,
        // migration-specific property would just be a second place a view
        // has to remember to check.
        if overlay.hubConfig().needsScan(Self.migrationGeneration) {
            var sawUnfinished = false
            let blockedCount = (live + trashed)
                .map(\.id)
                .reduce(into: 0) { count, id in
                    let outcome = OverlayMigration.migrateIfNeeded(projectID: id, repository: repository,
                                                                   overlay: overlay)
                    if outcome == .blocked { count += 1 }
                    if outcome == .blocked || outcome == .incomplete { sawUnfinished = true }
                }
            if blockedCount > 0 {
                let plural = blockedCount == 1 ? "project's" : "projects'"
                persistenceFailure = "\(blockedCount) \(plural) repos could not finish migrating: "
                    + "their overlay could not be read. Restore or remove the corrupt overlay to complete the move."
            }
            // Only mark the scan complete once the loop finishes AND nothing
            // was left unfinished — a `.blocked`/`.incomplete` project's data
            // did not move, and needs another attempt on the next launch.
            // Marking the scan complete anyway would strand it permanently.
            if !sawUnfinished {
                overlay.updateHubConfig { $0.markScanComplete(Self.migrationGeneration) }
            }
        }
    }

    public var activeProjects: [ProjectSummary] { projects.filter { $0.state == .active } }

    public func projects(inState state: ProjectState) -> [ProjectSummary] {
        projects.filter { $0.state == state }
    }

    public var pausedProjects: [ProjectSummary] { projects(inState: .paused) }
    public var archivedProjects: [ProjectSummary] { projects(inState: .archived) }

    // MARK: reading

    public func openProject(_ id: UUID) -> ProjectDocument? {
        if let cached = documents[id] { return cached }
        guard let loaded = repository.loadProject(id) else { return nil }
        documents[id] = loaded
        return loaded
    }

    public func activity(for id: UUID) -> [ActivityEvent] {
        openProject(id)?.activity ?? []
    }

    // MARK: writing

    @discardableResult
    public func createProject(name: String, kind: ProjectKind,
                              actor: ActivityActor) -> Project {
        let project = Project(id: UUID(), name: name, kind: kind)
        var document = ProjectDocument(project: project)
        document.activity.append(ActivityEvent(projectID: project.id, actor: actor,
                                               kind: .projectCreated,
                                               summary: "created project \(name)"))
        documents[project.id] = document
        persist(document)
        projects.append(project.summary)
        saveIndex()
        bumpRevision()
        return project
    }

    /// `kind`/`summary` let a caller that knows WHAT it changed say so in the
    /// feed — "added link foo" reads better than a generic "updated project".
    public func updateProject(_ project: Project, actor: ActivityActor,
                              kind: ActivityKind = .projectUpdated,
                              summary: String? = nil) throws {
        guard var document = openProject(project.id) else {
            throw QuestError.projectNotFound(project.id)
        }
        var updated = project
        updated.updatedAt = Date()
        document.project = updated
        document.activity.append(ActivityEvent(projectID: updated.id, actor: actor,
                                               kind: kind,
                                               summary: summary ?? "updated project \(updated.name)"))
        commit(document)
    }

    public func archiveProject(_ id: UUID, actor: ActivityActor) throws {
        try setState(id, state: .archived, actor: actor, summary: "archived project")
    }

    /// The general form of `archiveProject`, which stays as a convenience.
    /// Pause exists in the model but had no way to be reached before this.
    public func setState(_ id: UUID, state: ProjectState, actor: ActivityActor,
                         summary: String? = nil) throws {
        guard var document = openProject(id) else { throw QuestError.projectNotFound(id) }
        document.project.state = state
        // archivedAt tracks the archived state rather than accumulating: a
        // project brought back out of the archive is not still archived.
        document.project.archivedAt = state == .archived ? Date() : nil
        document.activity.append(ActivityEvent(projectID: id, actor: actor,
                                               kind: .projectUpdated,
                                               summary: summary ?? "set project state to \(state.rawValue)"))
        commit(document)
    }

    /// Soft. The document stays on disk; only the index entry moves to trash,
    /// so a wrong agent call is one restore away.
    public func deleteProject(_ id: UUID, actor: ActivityActor) throws {
        guard var document = openProject(id) else { throw QuestError.projectNotFound(id) }
        document.activity.append(ActivityEvent(projectID: id, actor: actor,
                                               kind: .projectDeleted,
                                               summary: "moved project to trash"))
        deletedProjectIDs.insert(id)
        commit(document)
    }

    public func restoreProject(_ id: UUID, actor: ActivityActor) throws {
        guard var document = openProject(id) else { throw QuestError.projectNotFound(id) }
        document.activity.append(ActivityEvent(projectID: id, actor: actor,
                                               kind: .projectRestored,
                                               summary: "restored project from trash"))
        deletedProjectIDs.remove(id)
        commit(document)
    }

    /// Hard. The other half of `deleteProject`: drops the document from disk
    /// and the summary from the index, with no way back. Refuses anything not
    /// already in the trash, so the irreversible path can only ever be reached
    /// from something the user has already soft-deleted.
    ///
    /// Deliberately takes no `ActivityActor`: the activity feed lives INSIDE
    /// the document being destroyed, so there is nowhere left to log to.
    public func purgeProject(_ id: UUID) throws {
        guard deletedProjectIDs.contains(id) else { throw QuestError.projectNotInTrash(id) }
        // Read the items BEFORE anything is destroyed: link-map rows are keyed
        // by ITEM id, and once the document is gone there is no way to learn
        // which rows belonged to this project. They would leak forever.
        let itemIDs = allItems(in: id).map(\.id)

        deletedProjectIDs.remove(id)
        trashedProjects.removeAll { $0.id == id }
        documents.removeValue(forKey: id)
        // The index is written BEFORE the document is destroyed. If the index
        // write fails, the two failure modes are not symmetric: destroying the
        // document first leaves an index entry pointing at a project whose file
        // is gone — it shows up in the trash and then fails `restoreProject`
        // with `projectNotFound`, a dead row the user cannot clear. Saving
        // first leaves at most a stray file that nothing references.
        saveIndex()
        repository.removeProject(id)

        // Overlay state is cleaned up LAST, after the project is definitely
        // gone. The overlay is the irreplaceable store: clearing it first and
        // then failing to destroy the project would leave a live project whose
        // notes and time entries had already been deleted.
        overlay.removeOverlay(for: id)
        overlay.updateHubConfig {
            $0.unbind(id)
            $0.clearMigrationMarkers(id)
        }
        if !itemIDs.isEmpty {
            overlay.updateLinkMap { map in
                for itemID in itemIDs { map.unlink(localID: itemID) }
            }
        }

        bumpRevision()
    }

    /// Empties the trash: every trashed item, then every trashed project.
    ///
    /// The plan is computed BEFORE anything is destroyed (see `TrashPurge`),
    /// because purging a project takes its document — and so its trashed items
    /// — with it. Resolving items as it went would either count them twice or
    /// fail with `itemNotFound` partway through.
    ///
    /// Does not throw. Each purge is an independent write, and stopping at the
    /// first failure would leave the trash half-emptied with no report of what
    /// remains — the one outcome the user cannot make sense of afterwards.
    @discardableResult
    public func emptyTrash(actor: ActivityActor) -> TrashPurgeOutcome {
        let plan = TrashPurge.plan(
            liveProjectIDs: projects.map(\.id),
            trashedProjectIDs: trashedProjects.map(\.id),
            trashedItemIDs: { allItems(in: $0).filter(\.isDeleted).map(\.id) })

        var purgedItems = 0
        var purgedProjects = 0
        var failures: [String] = []
        for id in plan.itemIDs {
            do {
                try purgeItem(id, actor: actor)
                purgedItems += 1
            } catch {
                // A purge that cascaded onto this id already removed it, which
                // is success for the user's purposes, not a failure worth
                // reporting: an epic and its child are both listed in the trash.
                if case QuestError.itemNotFound = error { continue }
                failures.append((error as? QuestError)?.message ?? error.localizedDescription)
            }
        }
        for id in plan.projectIDs {
            do {
                try purgeProject(id)
                purgedProjects += 1
            } catch {
                failures.append((error as? QuestError)?.message ?? error.localizedDescription)
            }
        }
        return TrashPurgeOutcome(purgedItems: purgedItems, purgedProjects: purgedProjects,
                                 failures: failures)
    }

    // MARK: internals

    /// Writes the document and refreshes the index entry derived from it.
    /// `internal` so the item-level API in Task 7 reuses exactly this path.
    func commit(_ document: ProjectDocument) {
        documents[document.project.id] = document
        persist(document)
        rebuildIndexEntry(for: document.project)
        saveIndex()
        bumpRevision()
    }

    /// Advances `revision`. Called only from paths that have already reached
    /// their write — a domain-validation `throw` earlier in a mutating method
    /// never reaches here, so the counter cannot advertise a rejected write.
    func bumpRevision() { revision += 1 }

    /// Moves the project's summary into whichever of the two owned lists its
    /// trashed state calls for. `trashedProjects` is OWNED state, never derived
    /// from `documents`: after a relaunch no document is open, and rebuilding
    /// the trash from that cache silently dropped every trashed project out of
    /// the index on the next unrelated commit.
    private func rebuildIndexEntry(for project: Project) {
        var summary = project.summary
        summary.updatedAt = Date()
        if deletedProjectIDs.contains(project.id) {
            summary.isTrashed = true
            projects.removeAll { $0.id == project.id }
            if let position = trashedProjects.firstIndex(where: { $0.id == project.id }) {
                trashedProjects[position] = summary
            } else {
                trashedProjects.append(summary)
            }
        } else {
            summary.isTrashed = false
            trashedProjects.removeAll { $0.id == project.id }
            if let position = projects.firstIndex(where: { $0.id == project.id }) {
                projects[position] = summary
            } else {
                projects.append(summary)
            }
        }
    }

    /// Always writes BOTH lists: an entry missing from this array is an entry
    /// gone from disk.
    private func saveIndex() {
        let liveEntries = projects.map { summary -> ProjectSummary in
            var summary = summary
            summary.isTrashed = false
            return summary
        }
        let trashedEntries = trashedProjects.map { summary -> ProjectSummary in
            var summary = summary
            summary.isTrashed = true
            return summary
        }
        do {
            try repository.saveIndex(liveEntries + trashedEntries)
        } catch {
            persistenceFailure = "Could not save the project index. Changes are kept in memory."
        }
    }

    /// A failed write never drops the in-memory change: it is retried once and
    /// then surfaced, because silently losing a typed task is worse than a banner.
    ///
    /// The repository REPORTS failure by throwing. The previous check —
    /// "does `loadProject` still return nil?" — could only ever detect a lost
    /// first write of a brand-new project, because a dropped write to an
    /// existing project still loads the stale document. It also decoded every
    /// item in the project on every commit.
    private func persist(_ document: ProjectDocument) {
        do {
            try repository.saveProject(document)
        } catch {
            do {
                try repository.saveProject(document)
            } catch {
                persistenceFailure = "Could not save \(document.project.name). Changes are kept in memory."
                return
            }
        }
        persistenceFailure = nil
    }
}
