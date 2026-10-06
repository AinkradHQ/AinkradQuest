import Foundation

/// What "Empty trash" will destroy, worked out before anything is destroyed.
///
/// Order is the whole point of this type. Purging a project drops its entire
/// document, taking its trashed items with it — so items must be resolved
/// against the projects that will still exist afterwards, and the projects
/// purged last. Deriving that inside the loop that mutates is how a purge ends
/// up either double-counting or throwing `itemNotFound` halfway through.
struct TrashPurgePlan: Equatable, Sendable {
    /// Trashed items living in projects that are NOT themselves being purged.
    /// Items inside a purged project are deliberately absent: the project purge
    /// removes them, and listing them here would count each one twice in the
    /// summary the user is shown.
    let itemIDs: [UUID]
    /// Purged after the items, for the reason above.
    let projectIDs: [UUID]

    var isEmpty: Bool { itemIDs.isEmpty && projectIDs.isEmpty }

    init(itemIDs: [UUID], projectIDs: [UUID]) {
        self.itemIDs = itemIDs
        self.projectIDs = projectIDs
    }
}

/// What an "Empty trash" run actually managed to do.
///
/// Emptying the trash is many independent destructive writes, so it does NOT
/// throw on the first failure: aborting midway would leave the trash partly
/// emptied with no account of what survived, which is the one state a user
/// cannot reason about. Failures are collected and reported alongside the
/// successes.
struct TrashPurgeOutcome: Equatable, Sendable {
    let purgedItems: Int
    let purgedProjects: Int
    let failures: [String]

    init(purgedItems: Int, purgedProjects: Int, failures: [String]) {
        self.purgedItems = purgedItems
        self.purgedProjects = purgedProjects
        self.failures = failures
    }

    /// The sentence shown when the run finishes. Partial success leads with
    /// what was destroyed, because that is the irreversible half.
    var message: String {
        let done = [
            TrashPurge.count(purgedItems, "item", "items"),
            TrashPurge.count(purgedProjects, "project", "projects"),
        ]
        .compactMap { $0 }
        let deleted = done.isEmpty ? "Nothing was deleted" : "Deleted \(done.joined(separator: " and "))"
        guard !failures.isEmpty else { return "\(deleted)." }
        return "\(deleted). \(failures.count) could not be deleted: \(failures.joined(separator: "; "))"
    }
}

enum TrashPurge {
    /// - Parameters:
    ///   - liveProjectIDs: projects not in the trash; their trashed items are
    ///     purged individually because the project itself survives.
    ///   - trashedProjectIDs: projects in the trash; each is purged whole.
    ///   - trashedItemIDs: the trashed item ids in a given project.
    static func plan(
        liveProjectIDs: [UUID], trashedProjectIDs: [UUID],
        trashedItemIDs: (UUID) -> [UUID]
    ) -> TrashPurgePlan {
        TrashPurgePlan(
            itemIDs: liveProjectIDs.flatMap(trashedItemIDs),
            projectIDs: trashedProjectIDs)
    }

    /// Counts phrased for a confirm dialog. Written out rather than templated
    /// with a bare number because "1 items" in the one place the app is about
    /// to do something irreversible reads as carelessness.
    static func confirmMessage(_ plan: TrashPurgePlan) -> String {
        let parts = [
            count(plan.itemIDs.count, "item", "items"),
            count(plan.projectIDs.count, "project", "projects"),
        ]
        .compactMap { $0 }
        guard !parts.isEmpty else { return "The trash is already empty." }
        let subject = parts.joined(separator: " and ")
        // Projects carry everything inside them, so say so: a project row in
        // the trash looks the same size as an item row and is not.
        let scope = plan.projectIDs.isEmpty ? "" : ", including everything inside those projects"
        return "\(subject)\(scope) will be gone for good. This cannot be undone."
    }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String? {
        switch n {
        case 0: nil
        case 1: "1 \(singular)"
        default: "\(n) \(plural)"
        }
    }
}
