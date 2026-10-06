import Foundation

/// The depth cap and the epic-at-root rule, enforced here rather than by
/// convention. Boards, rollups and timeline lanes all assume a bounded tree; a
/// `parentID` that would break that assumption is refused before it is stored.
public enum HierarchyRules {
    /// epic → item → subtask.
    public static let maxDepth = 3

    /// Depth of the node identified by `id`: 0 for "no parent", 1 for an epic.
    public static func depth(of id: UUID?, in items: [WorkItem]) -> Int {
        guard let id else { return 0 }
        var depth = 0
        var cursor: UUID? = id
        // Bounded by maxDepth + 1 so a corrupt cycle in stored data cannot hang.
        while let current = cursor, depth <= maxDepth + 1 {
            guard let item = items.first(where: { $0.id == current }) else { return depth }
            depth += 1
            cursor = item.parentID
        }
        return depth
    }

    public static func descendants(of id: UUID, in items: [WorkItem]) -> [WorkItem] {
        let direct = items.filter { $0.parentID == id }
        return direct + direct.flatMap { descendants(of: $0.id, in: items) }
    }

    /// Validates a placement. `movingItemID` is the item being reparented, or
    /// nil when creating — it exists only to catch the cycle case.
    public static func validate(
        parentID: UUID?, type: WorkItemType,
        movingItemID: UUID?, in items: [WorkItem]
    ) throws {
        if type == .epic {
            guard parentID == nil else { throw QuestError.epicMustBeRoot }
            return
        }
        guard let parentID else { throw QuestError.nonEpicMustHaveParent }
        guard let parent = items.first(where: { $0.id == parentID }) else {
            throw QuestError.parentNotFound(parentID)
        }
        // Existence is not enough: a soft-deleted parent is invisible on every
        // surface, so work filed under it would be invisible too. This is the
        // hole that let a live item end up with no live epic.
        guard !parent.isDeleted else { throw QuestError.parentIsDeleted(parentID) }
        if let movingItemID {
            if parentID == movingItemID
                || descendants(of: movingItemID, in: items).contains(where: { $0.id == parentID })
            {
                throw QuestError.cyclicParent
            }
        }
        let resulting = depth(of: parentID, in: items) + 1
        guard resulting <= maxDepth else {
            throw QuestError.depthExceeded(attempted: resulting, maximum: maxDepth)
        }
    }
}
