import Foundation

/// Which provider account a project talks to, and what the provider calls it.
public struct ProjectBinding: Codable, Sendable, Hashable {
    public var connectionID: UUID
    public var remoteProjectKey: String

    public init(connectionID: UUID, remoteProjectKey: String) {
        self.connectionID = connectionID
        self.remoteProjectKey = remoteProjectKey
    }
}

/// Routing, deliberately NOT overlay data.
///
/// A binding is not irreplaceable — re-link and it is back — and it is not
/// provider truth either. Keeping it out of the overlay means the backup file
/// carries no routing config, so restoring it on another machine cannot
/// resurrect bindings to connections that do not exist there.
public struct HubConfig: Codable, Sendable {
    /// Keyed by `uuidString`, not `UUID`: this file still gets opened by a
    /// person when something goes wrong — a project bound to the wrong
    /// account, a binding that outlived a delete — and a `[UUID: _]` encodes
    /// as a flat alternating array of keys and values, which is miserable to
    /// read. `ProjectOverlay.items` already keys by `uuidString` for the same
    /// reason; keeping one rule here instead of an exception three files away
    /// costs nothing now and would cost real confusion once this is persisted.
    public var bindings: [String: ProjectBinding]

    /// Per-project, per-half markers for `OverlayMigration`, keyed by
    /// `uuidString` for the same reason `bindings` is. Live HERE rather than
    /// in the overlay: a project whose overlay failed to decode has its
    /// overlay writes blocked (see `OverlayStore`), so a marker stored there
    /// could never be written for that project and would retry forever.
    /// `HubConfig` is a separate document, not gated by overlay corruption.
    ///
    /// Once set, a marker is NEVER cleared by ordinary use — including by
    /// `unbind`/detaching a repo. Without that, a user who migrates then
    /// deliberately unbinds a project (or detaches all its repos) would see
    /// the legacy fields (never cleared, by design) re-migrated on the next
    /// launch, silently resurrecting data they removed on purpose.
    public var migratedRepoProjects: Set<String>
    public var migratedBindingProjects: Set<String>

    /// How far the one-time migration scan has run.
    ///
    /// A GENERATION rather than a flag: if a future Quest needs to re-scan
    /// every project for a new migration, it raises
    /// `ProjectStore.migrationGeneration` and every store scans once more. A
    /// boolean would have to be cleared by hand, which nobody remembers to do.
    public var scanCompleteThrough: Int = 0

    public init() {
        bindings = [:]
        migratedRepoProjects = []
        migratedBindingProjects = []
    }

    public func binding(for projectID: UUID) -> ProjectBinding? {
        bindings[projectID.uuidString]
    }

    public mutating func bind(_ projectID: UUID, to binding: ProjectBinding) {
        bindings[projectID.uuidString] = binding
    }

    public mutating func unbind(_ projectID: UUID) {
        bindings.removeValue(forKey: projectID.uuidString)
    }

    /// Every project routed to this connection. Knows nothing about trash —
    /// this is routing, not state; the caller decides which ones count.
    /// A key that fails to parse as a `UUID` is skipped rather than crashing:
    /// a corrupt row should cost one binding, not the whole config.
    public func projectIDs(boundTo connectionID: UUID) -> [UUID] {
        bindings
            .filter { $0.value.connectionID == connectionID }
            .compactMap { UUID(uuidString: $0.key) }
    }

    public func hasMigratedRepos(_ projectID: UUID) -> Bool {
        migratedRepoProjects.contains(projectID.uuidString)
    }

    public mutating func markReposMigrated(_ projectID: UUID) {
        migratedRepoProjects.insert(projectID.uuidString)
    }

    public func hasMigratedBinding(_ projectID: UUID) -> Bool {
        migratedBindingProjects.contains(projectID.uuidString)
    }

    public mutating func markBindingMigrated(_ projectID: UUID) {
        migratedBindingProjects.insert(projectID.uuidString)
    }

    /// Clears both migration markers for a project.
    ///
    /// Called when a project is PURGED — the markers describe work done on a
    /// document that no longer exists, and a project restored later from a
    /// backup with its legacy fields intact must be migrated again rather than
    /// skipped by a marker nothing cleaned up.
    public mutating func clearMigrationMarkers(_ projectID: UUID) {
        migratedRepoProjects.remove(projectID.uuidString)
        migratedBindingProjects.remove(projectID.uuidString)
    }

    /// Whether the migration scan for `generation` still needs to run.
    public func needsScan(_ generation: Int) -> Bool { scanCompleteThrough < generation }

    /// Records that the scan for `generation` has completed. `max`, not a
    /// plain assignment: a store must never move this backward.
    public mutating func markScanComplete(_ generation: Int) {
        scanCompleteThrough = max(scanCompleteThrough, generation)
    }

    private enum CodingKeys: String, CodingKey {
        case bindings, migratedRepoProjects, migratedBindingProjects, scanCompleteThrough
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A `HubConfig` written before these markers existed still loads —
        // read leniently, defaulting to "nothing migrated yet under the
        // marker scheme", not to a decode failure.
        bindings = try container.decodeIfPresent([String: ProjectBinding].self, forKey: .bindings) ?? [:]
        migratedRepoProjects =
            try container.decodeIfPresent(
                Set<String>.self,
                forKey: .migratedRepoProjects) ?? []
        migratedBindingProjects =
            try container.decodeIfPresent(
                Set<String>.self,
                forKey: .migratedBindingProjects) ?? []
        // A document written before the gate existed still loads and — since
        // this defaults to 0 — correctly reports that it needs a scan.
        scanCompleteThrough = try container.decodeIfPresent(Int.self, forKey: .scanCompleteThrough) ?? 0
    }
}
