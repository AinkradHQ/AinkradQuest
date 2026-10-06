import Foundation

public struct BoardColumn: Sendable, Identifiable {
    public var id: String { status.id }
    public let status: Status
    public let items: [WorkItem]
}

public enum BoardGrouping {
    /// One column per status in scheme order, empty columns included — a board
    /// whose columns appear and disappear with their contents is unusable as a
    /// drop target.
    ///
    /// Epics are excluded: they are containers whose status is derived from
    /// their children, and putting them on the board invites moving a whole
    /// epic by dragging one card.
    public static func columns(
        items: [WorkItem], scheme: StatusScheme,
        filter: ItemFilter
    ) -> [BoardColumn] {
        let visible = ItemQuery.apply(
            filter, sort: .manual,
            to: items.filter { $0.type != .epic }, scheme: scheme)
        return scheme.statuses.map { status in
            BoardColumn(status: status, items: visible.filter { $0.statusID == status.id })
        }
    }
}

public struct BoardGroup: Sendable, Identifiable {
    public var id: UUID { epic.id }
    public let epic: WorkItem
    public let columns: [BoardColumn]
    /// True for the synthetic trailing group that catches live items whose
    /// owning epic could not be resolved (see `groupedByEpic`). `epic` in
    /// that case is a placeholder, not a stored item.
    public let isOrphanGroup: Bool

    public init(epic: WorkItem, columns: [BoardColumn], isOrphanGroup: Bool = false) {
        self.epic = epic
        self.columns = columns
        self.isOrphanGroup = isOrphanGroup
    }
}

extension BoardGrouping {
    /// One group per live epic, each carrying the FULL column set for the
    /// scheme — same reasoning as `columns(items:scheme:filter:)`: a column that
    /// vanishes with its contents is useless as a drop target.
    ///
    /// Grouping is by owning EPIC, not by direct parent, so a subtask appears
    /// beside its sibling item rather than in a group of its own. Epics
    /// themselves are still excluded from the columns; they are the group
    /// headers here.
    ///
    /// INVARIANT this relies on: a live item is expected to always have a live
    /// owning epic, because `ProjectStore.deleteItem` cascades soft-delete onto
    /// all live descendants and `ProjectStore.restoreItem` walks ancestors back
    /// to live. `HierarchyRules.validate` now also refuses filing or reparenting
    /// work under a soft-deleted parent, via `createItem`, `updateItem` and
    /// `moveItem` — so this state should be unreachable through the store.
    /// The orphan group remains anyway as a backstop for documents written
    /// before that guard existed, and for any future path that bypasses it:
    /// any live non-epic item not reachable from a live epic is surfaced in a
    /// trailing "No epic" group instead of silently vanishing.
    public static func groupedByEpic(
        items: [WorkItem], scheme: StatusScheme,
        filter: ItemFilter
    ) -> [BoardGroup] {
        let epics = items.filter { $0.type == .epic && !$0.isDeleted }
            .sorted { $0.orderIndex < $1.orderIndex }

        var covered = Set<UUID>()
        let groups = epics.map { epic -> BoardGroup in
            let descendants = HierarchyRules.descendants(of: epic.id, in: items)
            covered.formUnion(descendants.map(\.id))
            return BoardGroup(
                epic: epic,
                columns: columns(
                    items: descendants, scheme: scheme,
                    filter: filter))
        }

        let orphans = items.filter { !$0.isDeleted && $0.type != .epic && !covered.contains($0.id) }
        guard let firstOrphan = orphans.first else { return groups }

        // A placeholder, not a stored item — fixed id so its group keeps a
        // stable SwiftUI identity across recomputations.
        let placeholder = WorkItem(
            id: Self.orphanGroupID, projectID: firstOrphan.projectID,
            parentID: nil, type: .epic, title: "No epic",
            statusID: firstOrphan.statusID)
        let orphanGroup = BoardGroup(
            epic: placeholder,
            columns: columns(
                items: orphans, scheme: scheme,
                filter: filter),
            isOrphanGroup: true)
        return groups + [orphanGroup]
    }

    private static var orphanGroupID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    }
}
