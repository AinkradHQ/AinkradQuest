import Foundation

// MARK: - work items

extension ProjectStore {
    /// Live items only. Soft-deleted items are excluded from every surface.
    public func items(in projectID: UUID) -> [WorkItem] {
        (openProject(projectID)?.items ?? []).filter { !$0.isDeleted }
    }

    /// Including trashed ones — the trash view and restore path need these.
    public func allItems(in projectID: UUID) -> [WorkItem] {
        openProject(projectID)?.items ?? []
    }

    @discardableResult
    public func createItem(
        projectID: UUID, parentID: UUID?, type: WorkItemType,
        title: String, statusID: String,
        actor: ActivityActor,
        role: WorkItemRole? = nil
    ) throws -> WorkItem {
        guard var document = openProject(projectID) else {
            throw QuestError.projectNotFound(projectID)
        }
        guard document.project.statusScheme.status(id: statusID) != nil else {
            throw QuestError.unknownStatus(statusID)
        }
        try HierarchyRules.validate(
            parentID: parentID, type: type,
            movingItemID: nil, in: document.items)

        // Includes soft-deleted siblings — one still holding a high orderIndex
        // would otherwise collide with the new item once it's restored.
        let siblingOrderIndexes = document.items
            .filter { $0.parentID == parentID }
            .map(\.orderIndex)
        let item = WorkItem(
            id: UUID(), projectID: projectID, parentID: parentID,
            type: type, title: title, statusID: statusID,
            orderIndex: (siblingOrderIndexes.max() ?? -1) + 1,
            role: role)
        document.items.append(item)
        document.activity.append(
            ActivityEvent(
                projectID: projectID, itemID: item.id,
                actor: actor, kind: .itemCreated,
                summary: "created \(type.rawValue) \(title)"))
        commit(document)
        return item
    }

    public func updateItem(_ item: WorkItem, actor: ActivityActor) throws {
        guard var document = openProject(item.projectID) else {
            throw QuestError.projectNotFound(item.projectID)
        }
        guard let position = document.items.firstIndex(where: { $0.id == item.id }) else {
            throw QuestError.itemNotFound(item.id)
        }
        guard document.project.statusScheme.status(id: item.statusID) != nil else {
            throw QuestError.unknownStatus(item.statusID)
        }
        let stored = document.items[position]
        // parentID/type are mutable on WorkItem, so a caller could otherwise
        // reparent or retype through updateItem and skip the depth/cycle/
        // epic-at-root rules that createItem and moveItem enforce.
        if item.parentID != stored.parentID || item.type != stored.type {
            try HierarchyRules.validate(
                parentID: item.parentID, type: item.type,
                movingItemID: item.id, in: document.items)
        }
        var updated = item
        updated.updatedAt = Date()
        document.items[position] = updated
        document.activity.append(
            ActivityEvent(
                projectID: item.projectID, itemID: item.id,
                actor: actor, kind: .itemUpdated,
                summary: "updated \(item.title)"))
        commit(document)
    }

    public func setStatus(_ id: UUID, statusID: String, actor: ActivityActor) throws {
        guard let projectID = projectID(owning: id),
            var document = openProject(projectID),
            let position = document.items.firstIndex(where: { $0.id == id })
        else { throw QuestError.itemNotFound(id) }
        guard document.project.statusScheme.status(id: statusID) != nil else {
            throw QuestError.unknownStatus(statusID)
        }
        document.items[position].statusID = statusID
        document.items[position].updatedAt = Date()
        // closedAt follows the CATEGORY, not the status name, so a custom
        // "Shipped" status marked `.done` closes an item exactly like "Done".
        document.items[position].closedAt =
            document.project.statusScheme.isDone(statusID) ? Date() : nil
        document.activity.append(
            ActivityEvent(
                projectID: projectID, itemID: id, actor: actor,
                kind: .itemStatusChanged,
                summary: "\(document.items[position].title) → \(statusID)"))
        commit(document)
    }

    public func moveItem(
        _ id: UUID, toParent parentID: UUID?, orderIndex: Int,
        actor: ActivityActor
    ) throws {
        guard let projectID = projectID(owning: id),
            var document = openProject(projectID),
            let position = document.items.firstIndex(where: { $0.id == id })
        else { throw QuestError.itemNotFound(id) }

        try HierarchyRules.validate(
            parentID: parentID, type: document.items[position].type,
            movingItemID: id, in: document.items)
        document.items[position].parentID = parentID
        document.items[position].orderIndex = orderIndex
        document.items[position].updatedAt = Date()
        document.activity.append(
            ActivityEvent(
                projectID: projectID, itemID: id, actor: actor,
                kind: .itemMoved,
                summary: "moved \(document.items[position].title)"))
        commit(document)
    }

    /// Soft, and it takes descendants with it — a hidden epic whose children
    /// still appeared on the board would be worse than either outcome.
    public func deleteItem(_ id: UUID, actor: ActivityActor) throws {
        guard let projectID = projectID(owning: id), var document = openProject(projectID) else {
            throw QuestError.itemNotFound(id)
        }
        // Only cascade onto descendants that are currently live — one already
        // in the trash for its own reason keeps its own deletedAt, which is
        // how restore later tells "deleted by this cascade" apart from
        // "independently deleted".
        let descendantIDs = HierarchyRules.descendants(of: id, in: document.items)
            .filter { !$0.isDeleted }
            .map(\.id)
        let affected = Set([id] + descendantIDs)
        let stamp = Date()
        for position in document.items.indices where affected.contains(document.items[position].id) {
            document.items[position].deletedAt = stamp
        }
        document.activity.append(
            ActivityEvent(
                projectID: projectID, itemID: id, actor: actor,
                kind: .itemDeleted,
                summary: "moved \(affected.count) item(s) to trash"))
        commit(document)
    }

    public func restoreItem(_ id: UUID, actor: ActivityActor) throws {
        guard let projectID = projectID(owning: id), var document = openProject(projectID) else {
            throw QuestError.itemNotFound(id)
        }
        guard let targetDeletedAt = document.items.first(where: { $0.id == id })?.deletedAt else {
            throw QuestError.itemNotFound(id)
        }
        // Only restore descendants deleted by the SAME cascade (matching
        // deletedAt) — one deleted independently, earlier or later, stays
        // in the trash.
        let descendantIDs = HierarchyRules.descendants(of: id, in: document.items)
            .filter { $0.deletedAt == targetDeletedAt }
            .map(\.id)
        // Ancestors too. Restoring a child while its epic is still trashed
        // would leave a live item whose parent is deleted: every surface
        // renders epic → descendants, so it would appear on no list and count
        // towards no rollup — live, invisible and unreachable.
        var ancestorIDs: [UUID] = []
        var cursor = document.items.first(where: { $0.id == id })?.parentID
        var hops = 0
        while let current = cursor, hops <= HierarchyRules.maxDepth {
            guard let ancestor = document.items.first(where: { $0.id == current }) else { break }
            if ancestor.isDeleted { ancestorIDs.append(ancestor.id) }
            cursor = ancestor.parentID
            hops += 1
        }
        let affected = Set([id] + descendantIDs + ancestorIDs)
        for position in document.items.indices where affected.contains(document.items[position].id) {
            document.items[position].deletedAt = nil
        }
        let ancestorNote =
            ancestorIDs.isEmpty
            ? ""
            : " (including \(ancestorIDs.count) parent item(s), so it is reachable again)"
        document.activity.append(
            ActivityEvent(
                projectID: projectID, itemID: id, actor: actor,
                kind: .itemRestored,
                summary: "restored \(affected.count) item(s)\(ancestorNote)"))
        commit(document)
    }

    /// Stamps a role onto an existing item. Its only caller today is Inbox
    /// adoption: an epic written before `WorkItemRole` existed is recognised by
    /// title once, then marked, so it survives being renamed thereafter.
    ///
    /// Not routed through `updateItem`, which would require the caller to hold
    /// and round-trip a whole `WorkItem` — and would log an `itemUpdated` event
    /// for something the user did not do. Adoption is bookkeeping, so it is
    /// deliberately silent in the activity feed.
    public func setRole(_ role: WorkItemRole?, on id: UUID) throws {
        guard let projectID = projectID(owning: id), var document = openProject(projectID) else {
            throw QuestError.itemNotFound(id)
        }
        guard let position = document.items.firstIndex(where: { $0.id == id }) else {
            throw QuestError.itemNotFound(id)
        }
        document.items[position].role = role
        commit(document)
    }

    /// Hard. The other half of `deleteItem`, and the counterpart to
    /// `purgeProject`: the item is removed from the document outright.
    ///
    /// Descendants go too, in ANY state — including one trashed separately and
    /// one still live (which cannot happen through `deleteItem`'s cascade, but
    /// can through a direct MCP call). Leaving one behind gives it a `parentID`
    /// pointing at nothing, and `restoreItem` already documents what that
    /// produces: every surface renders epic → descendants, so the survivor
    /// would be live, invisible, and unreachable. A dangling child is a worse
    /// outcome than deleting a little more than was asked for, and the parent
    /// was in the trash either way.
    ///
    /// Links need no cleanup: they are stored ON the item (`WorkItem.links`)
    /// and leave with it.
    public func purgeItem(_ id: UUID, actor: ActivityActor) throws {
        guard let projectID = projectID(owning: id), var document = openProject(projectID) else {
            throw QuestError.itemNotFound(id)
        }
        guard let item = document.items.first(where: { $0.id == id }), item.isDeleted else {
            throw QuestError.itemNotInTrash(id)
        }
        let descendantIDs = HierarchyRules.descendants(of: id, in: document.items).map(\.id)
        let affected = Set([id] + descendantIDs)
        document.items.removeAll { affected.contains($0.id) }
        // The activity event outlives the item it names, so it carries the
        // title: `itemID` now resolves to nothing, and "deleted an item" with
        // no name makes the feed useless exactly where it matters most.
        document.activity.append(
            ActivityEvent(
                projectID: projectID, itemID: id, actor: actor,
                kind: .itemDeleted,
                summary: "permanently deleted \(item.title)"
                    + (descendantIDs.isEmpty
                        ? ""
                        : " and \(descendantIDs.count) item(s) under it")))
        commit(document)
    }

    /// Which project holds `itemID`. Checks open documents first, then the index.
    func projectID(owning itemID: UUID) -> UUID? {
        for summary in projects + trashedProjects {
            if let document = openProject(summary.id),
                document.items.contains(where: { $0.id == itemID })
            {
                return summary.id
            }
        }
        return nil
    }
}
