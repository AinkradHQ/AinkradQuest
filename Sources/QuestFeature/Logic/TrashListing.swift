import Foundation

/// A trashed item to show, with a label that already accounts for whether its
/// parent project is itself trashed — an item's reachability must not depend
/// on the order the user restores things in.
struct TrashedItemEntry: Identifiable {
    let id: UUID
    let label: String
}

/// Pure so it can be pinned by a test without SwiftUI: the item collection
/// for the trash view must cover items whose project is live AND items whose
/// project is also trashed, or a doubly-deleted item becomes unreachable
/// until its project is restored first.
enum TrashListing {
    static func itemEntries(
        projects: [ProjectSummary], trashedProjects: [ProjectSummary],
        allItems: (UUID) -> [WorkItem]
    ) -> [TrashedItemEntry] {
        (projects + trashedProjects).flatMap { project in
            allItems(project.id).filter(\.isDeleted).map { item in
                let label =
                    project.isTrashed
                    ? "\(project.name) (trashed): \(item.title)"
                    : "\(project.name): \(item.title)"
                return TrashedItemEntry(id: item.id, label: label)
            }
        }
    }
}
