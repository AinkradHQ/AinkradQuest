import Foundation
import Observation

/// The single mutation point for overlay data, mirroring `ProjectStore`'s shape
/// so the two feel the same to callers.
///
/// Deliberately separate from `ProjectStore`: this store holds what is YOURS
/// and irreplaceable, while `ProjectStore` holds what a provider would own and
/// what a re-sync could rebuild. Only this store's documents are backed up.
@MainActor
@Observable
final class OverlayStore {
    /// Set when a write could not be completed, OR when a project's overlay
    /// could not be decoded on load. Reused (rather than adding a second
    /// property) for the same reason `ProjectStore` has only one banner:
    /// both are "your overlay data is at risk, look now" conditions, and a
    /// caller that already watches this property for save failures gets the
    /// corrupt-load warning for free. The in-memory change from a normal
    /// write failure is KEPT, exactly as `ProjectStore.persistenceFailure`
    /// does; a corrupt-load failure has no in-memory change to keep.
    private(set) var persistenceFailure: String?
    /// Typed successor to `persistenceFailure`, kept alongside it rather than
    /// replacing it: three call sites still read the string, and migrating
    /// them is follow-on work, not this property's job. Unlike
    /// `persistenceFailure`, an unrelated successful write must NOT downgrade
    /// an unresolved `.unreadable` — only resolving that specific project's
    /// condition (a fixed load, or `removeOverlay`) clears it.
    private(set) var health: OverlayHealth = .healthy {
        didSet {
            // One hook on the property rather than one at each of the six
            // assignment sites: the rule is "when health changes", and six
            // call sites would be six chances to add a seventh without it.
            guard health != oldValue else { return }
            onHealthChanged?(health, oldValue)
        }
    }

    /// Called when `health` actually changes value. Set by `QuestApp` so the
    /// store does not have to know what a notification is.
    ///
    /// Receives the OLD value too, because "became unreadable" is the event
    /// worth reporting and "was already unreadable" is not — without the
    /// previous value every re-evaluation would look like new news.
    var onHealthChanged: ((OverlayHealth, OverlayHealth) -> Void)?
    /// Bumped once per applied mutation, so a view can memoize derived work
    /// instead of recomputing on every body pass. Same contract as
    /// `ProjectStore.revision`: "in-memory state changed", not "durably saved".
    private(set) var revision: Int = 0

    private let repository: any ProjectRepository
    /// Loaded lazily per project and cached, so repeated reads do not re-decode.
    private var overlays: [UUID: ProjectOverlay] = [:]
    /// Projects whose on-disk overlay failed to decode. Writes for these are
    /// blocked outright: persisting the empty in-memory overlay would
    /// overwrite the corrupt bytes a human might still be able to salvage by
    /// hand. Cleared only by `removeOverlay`, which deliberately replaces
    /// the corrupt document with nothing, or by a later successful load
    /// after the underlying bytes are fixed out of band.
    private var unreadableProjects: Set<UUID> = []
    /// Projects whose most recent write was refused because they are
    /// unreadable. Tracked separately from `unreadableProjects` so
    /// `removeOverlay` can shrink each set independently rather than
    /// collapsing `.writeBlocked` straight to `.healthy` while another
    /// project is still unreadable.
    private var writeBlockedProjects: Set<UUID> = []
    private var map: LinkMap
    private var config: HubConfig

    init(repository: any ProjectRepository) {
        self.repository = repository
        self.map = repository.loadLinkMap()
        self.config = repository.loadHubConfig()
    }

    /// Never nil: a project with no overlay yet, OR one whose overlay could
    /// not be decoded, reads as an EMPTY overlay, so callers never branch on
    /// "has this project been touched before". A corrupt overlay's failure is
    /// surfaced separately via `persistenceFailure`, and further writes for
    /// that project are blocked — see `unreadableProjects`.
    func overlay(for projectID: UUID) -> ProjectOverlay {
        if let cached = overlays[projectID] { return cached }
        do {
            let loaded = try repository.loadOverlay(projectID) ?? ProjectOverlay(projectID: projectID)
            overlays[projectID] = loaded
            return loaded
        } catch {
            unreadableProjects.insert(projectID)
            persistenceFailure =
                "Your notes and priorities could not be read: "
                + ((error as? QuestError)?.message ?? String(describing: error))
            health = .unreadable(unreadableProjects)
            let empty = ProjectOverlay(projectID: projectID)
            overlays[projectID] = empty
            return empty
        }
    }

    /// Whether writes to this project's overlay are blocked because its
    /// on-disk overlay failed to decode. Triggers the load first (as
    /// `overlay(for:)` does) so this is accurate even before anything else
    /// has touched this project this session — a caller like
    /// `OverlayMigration` that needs to know WHETHER a write would be
    /// swallowed, not just get the empty overlay back, reads this.
    func isUnreadable(_ projectID: UUID) -> Bool {
        _ = overlay(for: projectID)
        return unreadableProjects.contains(projectID)
    }

    /// Returns whether the mutation was durably persisted, so a caller that
    /// must not proceed on a half-landed write (like `OverlayMigration`,
    /// which sets a "this is done" marker in a SEPARATE document right after
    /// this call) can tell success from a swallowed failure. Most callers
    /// don't need this — `persistenceFailure` already surfaces it to the
    /// user — so the result is discardable.
    @discardableResult
    func update(projectID: UUID, _ mutate: (inout ProjectOverlay) -> Void) -> Bool {
        var overlay = overlay(for: projectID)
        mutate(&overlay)
        return commit(overlay)
    }

    func updateItem(
        _ itemID: UUID, in projectID: UUID,
        _ mutate: (inout ItemOverlay) -> Void
    ) {
        var overlay = overlay(for: projectID)
        var item = overlay.item(itemID) ?? ItemOverlay()
        mutate(&item)
        // Prune rather than leave a tombstone: this store is backed up, and
        // empty records would accumulate for every item ever glanced at.
        // `ItemOverlay.isEmpty` deliberately treats `personalOrder == 0` as
        // content, so the top-of-list item is never pruned.
        overlay.setItem(item.isEmpty ? nil : item, for: itemID)
        commit(overlay)
    }

    func removeOverlay(for projectID: UUID) {
        overlays.removeValue(forKey: projectID)
        unreadableProjects.remove(projectID)
        writeBlockedProjects.remove(projectID)
        repository.removeOverlay(projectID)
        switch health {
        case .unreadable:
            health = unreadableProjects.isEmpty ? .healthy : .unreadable(unreadableProjects)
        case .writeBlocked:
            health = writeBlockedProjects.isEmpty ? .healthy : .writeBlocked(writeBlockedProjects)
        case .healthy, .writeFailed:
            break
        }
        revision += 1
    }

    func linkMap() -> LinkMap { map }

    func updateLinkMap(_ mutate: (inout LinkMap) -> Void) {
        mutate(&map)
        persist { try repository.saveLinkMap(map) }
    }

    func hubConfig() -> HubConfig { config }

    func updateHubConfig(_ mutate: (inout HubConfig) -> Void) {
        mutate(&config)
        persist { try repository.saveHubConfig(config) }
    }

    /// A write for a project marked unreadable is a no-op: it must not
    /// silently look like a success, so it still bumps `revision` (in-memory
    /// state — the blocked attempt itself — did change) and raises
    /// `persistenceFailure`, but never reaches the repository.
    @discardableResult
    private func commit(_ overlay: ProjectOverlay) -> Bool {
        guard !unreadableProjects.contains(overlay.projectID) else {
            revision += 1
            persistenceFailure =
                "This project's overlay could not be read, so the change "
                + "was not saved. Restore or remove the corrupt overlay before editing it again."
            writeBlockedProjects.insert(overlay.projectID)
            health = .writeBlocked(writeBlockedProjects)
            return false
        }
        overlays[overlay.projectID] = overlay
        return persist { try repository.saveOverlay(overlay) }
    }

    @discardableResult
    private func persist(_ write: () throws -> Void) -> Bool {
        revision += 1
        do {
            try write()
            persistenceFailure = nil
            // An unresolved `.unreadable`/`.writeBlocked` for SOME project must
            // not be masked by an unrelated write's success elsewhere — only a
            // `.writeFailed` (this same kind of retryable condition) clears.
            if case .writeFailed = health {
                health = .healthy
            }
            return true
        } catch {
            persistenceFailure =
                "Your notes and priorities could not be saved: "
                + ((error as? QuestError)?.message ?? error.localizedDescription)
            health = .writeFailed((error as? QuestError)?.message ?? error.localizedDescription)
            return false
        }
    }
}
