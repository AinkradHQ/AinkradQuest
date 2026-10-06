import Foundation

extension ProjectStore {
    /// Attaches a link to a project or a work item.
    ///
    /// Both targets share this path so the activity log and the trashed-target
    /// refusal cannot diverge. Validation of the link itself belongs to
    /// `LinkValidation` at the input boundary; by the time a `Link` exists it is
    /// well-formed.
    ///
    /// A link already on the target is refused rather than appended. Two rows
    /// with the same identity are not useful to anyone, and they reintroduce the
    /// ambiguity the repo-qualified `Link.id` exists to remove.
    public func addLink(to target: LinkTarget, link: Link, actor: ActivityActor) throws {
        try mutateLinks(
            target, actor: actor, kind: .linkAdded,
            verb: "added"
        ) { links in
            guard !links.contains(where: { $0.id == link.id }) else {
                throw QuestError.linkAlreadyExists(link.id)
            }
            links.append(link)
        }
    }

    public func removeLink(
        from target: LinkTarget, link: Link,
        actor: ActivityActor
    ) throws {
        try mutateLinks(
            target, actor: actor, kind: .linkRemoved,
            verb: "removed"
        ) { links in
            guard let position = links.firstIndex(where: { $0.id == link.id }) else {
                throw QuestError.linkNotFound(link.id)
            }
            links.remove(at: position)
        }
    }

    private func mutateLinks(
        _ target: LinkTarget, actor: ActivityActor,
        kind: ActivityKind, verb: String,
        _ change: (inout [Link]) throws -> Void
    ) throws {
        // Trashed-target refusal lives HERE, on both branches, rather than only
        // at the MCP boundary: a link attached to something in the trash is
        // invisible on every surface, and a second caller (a view, a future
        // importer) would otherwise bypass the rule entirely. The MCP layer
        // keeps its own guards for their assistant-specific wording; this is the
        // backstop. `openProject` and `projectID(owning:)` both answer for
        // trashed things deliberately, so neither one can be that backstop.
        switch target {
        case .project(let projectID):
            guard var document = openProject(projectID),
                !isTrashed(projectID)
            else { throw QuestError.projectNotFound(projectID) }
            try change(&document.project.links)
            document.project.updatedAt = Date()
            document.activity.append(
                ActivityEvent(
                    projectID: projectID, actor: actor, kind: kind,
                    summary: "\(verb) a link on \(document.project.name)"))
            commit(document)

        case .item(let itemID):
            guard let projectID = projectID(owning: itemID),
                var document = openProject(projectID),
                // An item whose PROJECT is trashed is just as invisible as a
                // soft-deleted item; both hide the link.
                !isTrashed(projectID),
                let position = document.items.firstIndex(where: { $0.id == itemID }),
                // A trashed item is invisible on every surface; attaching work
                // to it would hide the link too.
                !document.items[position].isDeleted
            else { throw QuestError.itemNotFound(itemID) }

            try change(&document.items[position].links)
            document.items[position].updatedAt = Date()
            document.activity.append(
                ActivityEvent(
                    projectID: projectID, itemID: itemID, actor: actor,
                    kind: kind,
                    summary: "\(verb) a link on \(document.items[position].title)"))
            commit(document)
        }
    }

    /// Reads the store's OWNED trash set rather than deriving it, matching how
    /// `rebuildIndexEntry` maintains it.
    func isTrashed(_ projectID: UUID) -> Bool {
        deletedProjectIDs.contains(projectID)
    }
}
