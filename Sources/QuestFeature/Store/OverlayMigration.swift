import Foundation

/// Moves pre-M2 data out of `ProjectDocument` and into the overlay and hub
/// config, once per project, on first load after upgrading.
///
/// Idempotent by construction: each half checks its OWN persisted marker in
/// `HubConfig` (`hasMigratedRepos`/`hasMigratedBinding`), not whether its
/// destination is currently empty. Checking emptiness would resurrect data a
/// user deliberately removed after migrating — unbind a project, or detach
/// all its repos, and the legacy fields (never cleared, by design) would look
/// exactly like "not migrated yet" on the next launch. The marker means "this
/// half has run", independent of what the user did to the result afterward.
/// A crash between the halves leaves one marker set and one not, so the
/// unfinished half resumes on the next launch rather than duplicating or
/// getting stuck.
public enum OverlayMigration {
    /// What one `migrateIfNeeded` call did, so a caller can log or count.
    public enum Outcome: Equatable {
        /// Neither half had anything left to do.
        case nothingToDo
        /// At least one half moved data and marked itself done.
        case moved
        /// At least one half had data to move but could not: the project's
        /// overlay is unreadable, so `OverlayStore` would silently swallow
        /// the write. Nothing was marked done for that half, so it retries
        /// on the next launch once the overlay is restored or removed.
        case blocked
        /// The repos half attempted its overlay write — the overlay was
        /// readable, so this is NOT `blocked` — but the write did not
        /// durably persist (a genuine save failure, surfaced separately via
        /// `OverlayStore.persistenceFailure`). The marker was deliberately
        /// left unset, so the move retries on the next launch rather than
        /// being recorded as done for data that never reached disk.
        case incomplete
    }

    /// Returns what happened, so a caller can log or count — `moved`,
    /// `nothingToDo`, or `blocked` (see `Outcome`).
    @MainActor
    @discardableResult
    public static func migrateIfNeeded(
        projectID: UUID,
        repository: any ProjectRepository,
        overlay: OverlayStore
    ) -> Outcome {
        guard let document = repository.loadProject(projectID) else { return .nothingToDo }
        let project = document.project
        var moved = false
        var blocked = false
        var incomplete = false

        let config = overlay.hubConfig()
        if !project.legacyRepos.isEmpty, !config.hasMigratedRepos(projectID) {
            if overlay.isUnreadable(projectID) {
                // The write would be silently swallowed by `OverlayStore`'s
                // corrupt-overlay guard — do not mark this done, so it is
                // retried once the overlay is fixed. The legacy bytes are
                // untouched either way, so nothing is lost in the meantime.
                blocked = true
            } else {
                let persisted = overlay.update(projectID: projectID) { $0.repos = project.legacyRepos }
                if persisted {
                    // Only mark the repos half done once the overlay write is
                    // CONFIRMED durably saved. Setting the marker before this
                    // is exactly the bug this guards against: the hub-config
                    // write below is a SEPARATE document, so if the overlay
                    // write above failed but we marked anyway, the marker
                    // would forever claim repos that never reached disk.
                    overlay.updateHubConfig { $0.markReposMigrated(projectID) }
                    moved = true
                } else {
                    incomplete = true
                }
            }
        }

        if let connectionID = project.legacyConnectionID,
            let key = project.legacyRemoteProjectKey,
            !overlay.hubConfig().hasMigratedBinding(projectID)
        {
            overlay.updateHubConfig {
                $0.bind(
                    projectID,
                    to: ProjectBinding(
                        connectionID: connectionID,
                        remoteProjectKey: key))
                $0.markBindingMigrated(projectID)
            }
            moved = true
        }

        if blocked { return .blocked }
        if incomplete { return .incomplete }
        return moved ? .moved : .nothingToDo
    }
}
