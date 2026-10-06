import AinkradAppKit
import Foundation

/// Dispatches one MCP call onto the store.
///
/// The store is the only thing this type touches, so every guarantee the store
/// enforces — depth cap, status validity, activity logging, soft delete —
/// applies identically whether a call came from the assistant or from a view.
/// Nothing here reimplements a rule.
@MainActor
public final class QuestMCPOperations {
    private let store: ProjectStore

    public init(store: ProjectStore) { self.store = store }

    public func run(operation: String, arguments: String) async -> AgentActionResult {
        guard let data = arguments.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return failure("\(operation): arguments must be a JSON object")
        }
        do {
            return switch operation {
            case "listProjects": listProjects()
            case "getProject": try getProject(json)
            case "searchItems": searchItems(json)
            case "getItem": try getItem(json)
            case "createProject": createProject(json)
            case "updateProject": try updateProject(json)
            case "createItem": try createItem(json)
            case "updateItem": try updateItem(json)
            case "moveItem": try moveItem(json)
            case "setStatus": try setStatus(json)
            case "deleteItem": try deleteItem(json)
            case "deleteProject": try deleteProject(json)
            case "addLink": try addLink(json)
            case "removeLink": try removeLink(json)
            case "updateStatusScheme": try updateStatusScheme(json)
            default: failure("Unknown operation \(operation)")
            }
        } catch let error as ArgumentError {
            return failure(error.message)
        } catch let error as ValidationError {
            return failure(error.message)
        } catch let error as QuestError {
            return failure(error.message)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    // MARK: reads

    private func listProjects() -> AgentActionResult {
        let lines = store.projects.map { "\($0.id.uuidString)  \($0.name)  [\($0.state.rawValue)]" }
        return success(lines.isEmpty ? "No projects." : lines.joined(separator: "\n"))
    }

    private func getProject(_ json: [String: Any]) throws -> AgentActionResult {
        let id = try uuid(json, "projectID", operation: "getProject")
        let located = try locateProject(id)
        let document = located.document
        let statuses = document.project.statusScheme.statuses.map(\.id).joined(separator: ", ")
        let items = document.items.filter { !$0.isDeleted }
            .map { describe($0, scheme: document.project.statusScheme) }
        // Consistent with getItem: a read of a trashed thing is answered, but
        // never answered as if it were live.
        let trashNote =
            located.isTrashed
            ? "\nIN TRASH: this project is in the trash\n"
            : ""
        return success(
            """
            \(document.project.name) [\(document.project.kind.rawValue)]\(trashNote)
            statuses: \(statuses)
            links: \(document.project.links.map(\.label).joined(separator: ", "))
            items:
            \(items.joined(separator: "\n"))
            """)
    }

    private func searchItems(_ json: [String: Any]) -> AgentActionResult {
        var filter = ItemFilter()
        filter.text = json["query"] as? String ?? ""
        if let raw = json["statusID"] as? String { filter.statusIDs = [raw] }
        let projectIDs =
            (json["projectID"] as? String).flatMap(UUID.init(uuidString:))
            .map { [$0] } ?? store.projects.map(\.id)

        var lines: [String] = []
        for projectID in projectIDs {
            guard let document = store.openProject(projectID) else { continue }
            let matched = ItemQuery.apply(
                filter, sort: .updated, to: document.items,
                scheme: document.project.statusScheme)
            lines += matched.map { "\(document.project.name): " + describe($0, scheme: document.project.statusScheme) }
        }
        return success(lines.isEmpty ? "No matching items." : lines.joined(separator: "\n"))
    }

    private func getItem(_ json: [String: Any]) throws -> AgentActionResult {
        let id = try uuid(json, "itemID", operation: "getItem")
        let located = try locate(id)
        let item = located.item
        // The store deliberately keeps soft-deleted items reachable by id so
        // they can be restored. Every UI surface hides them; the assistant
        // gets told instead, because silently answering about a trashed item
        // as if it were live is how an agent reports work that no longer exists.
        let trashNote = located.trashDescription.map { "\nIN TRASH: \($0)\n" } ?? ""
        return success(
            """
            \(item.title)\(trashNote)
            id: \(item.id.uuidString)
            type: \(item.type.rawValue)  status: \(item.statusID)  priority: \(item.priority)
            labels: \(item.labels.joined(separator: ", "))
            due: \(item.dueDate.map(String.init(describing:)) ?? "none")
            body:
            \(item.body)
            """)
    }

    // MARK: writes — every one of them records `actor: .agent`

    private func createProject(_ json: [String: Any]) -> AgentActionResult {
        let name = json["name"] as? String ?? "Untitled"
        let kind = ProjectKind(rawValue: json["kind"] as? String ?? "software") ?? .software
        let project = store.createProject(name: name, kind: kind, actor: .agent)
        return success("Created project \(project.name) (\(project.id.uuidString))")
    }

    private func updateProject(_ json: [String: Any]) throws -> AgentActionResult {
        let id = try uuid(json, "projectID", operation: "updateProject")
        var document = try locateProjectForMutation(id, operation: "updateProject").document
        if let name = json["name"] as? String { document.project.name = name }
        if let summary = json["summary"] as? String { document.project.summaryText = summary }
        try store.updateProject(document.project, actor: .agent)
        return success("Updated project \(document.project.name)")
    }

    private func createItem(_ json: [String: Any]) throws -> AgentActionResult {
        let projectID = try uuid(json, "projectID", operation: "createItem")
        let parentID = (json["parentID"] as? String).flatMap(UUID.init(uuidString:))
        let type = WorkItemType(rawValue: json["type"] as? String ?? "task") ?? .task
        let title = json["title"] as? String ?? "Untitled"
        let statusID = json["statusID"] as? String ?? "todo"
        let located = try locateProjectForMutation(projectID, operation: "createItem")
        // A live child under a soft-deleted parent is exactly the orphan the
        // restore-ancestors fix was raised to prevent: ListSurface renders
        // epic → descendants, so it would show on no list and count towards
        // no rollup. The store allows it (the parent still exists); the
        // assistant must not ask for it.
        if let parentID,
            let parent = located.document.items.first(where: { $0.id == parentID }),
            parent.isDeleted
        {
            throw ArgumentError(
                message:
                    "createItem: the parent item \(parent.title) is in the trash. "
                    + "Restore it from Quest's Trash before filing work under it.")
        }
        let item = try store.createItem(
            projectID: projectID, parentID: parentID, type: type,
            title: title, statusID: statusID, actor: .agent)
        return success("Created \(type.rawValue) \(item.title) (\(item.id.uuidString))")
    }

    private func updateItem(_ json: [String: Any]) throws -> AgentActionResult {
        let id = try uuid(json, "itemID", operation: "updateItem")
        var item = try locateForMutation(id, operation: "updateItem").item
        if let title = json["title"] as? String { item.title = title }
        if let body = json["body"] as? String { item.body = body }
        if let labels = json["labels"] as? [String] { item.labels = labels }
        if let raw = json["priority"] as? Int, let priority = Priority(rawValue: raw) {
            item.priority = priority
        }
        try store.updateItem(item, actor: .agent)
        return success("Updated \(item.title)")
    }

    private func moveItem(_ json: [String: Any]) throws -> AgentActionResult {
        let id = try uuid(json, "itemID", operation: "moveItem")
        let parentID = (json["parentID"] as? String).flatMap(UUID.init(uuidString:))
        let orderIndex = json["orderIndex"] as? Int ?? 0
        _ = try locateForMutation(id, operation: "moveItem")
        try store.moveItem(id, toParent: parentID, orderIndex: orderIndex, actor: .agent)
        return success("Moved item \(id.uuidString)")
    }

    private func setStatus(_ json: [String: Any]) throws -> AgentActionResult {
        let id = try uuid(json, "itemID", operation: "setStatus")
        guard let statusID = json["statusID"] as? String else {
            throw ArgumentError(message: "setStatus: missing or invalid argument 'statusID'")
        }
        _ = try locateForMutation(id, operation: "setStatus")
        try store.setStatus(id, statusID: statusID, actor: .agent)
        return success("Set \(id.uuidString) to \(statusID)")
    }

    private func deleteItem(_ json: [String: Any]) throws -> AgentActionResult {
        let id = try uuid(json, "itemID", operation: "deleteItem")
        try store.deleteItem(id, actor: .agent)
        return success("Moved item \(id.uuidString) to trash. It can be restored from Quest.")
    }

    private func deleteProject(_ json: [String: Any]) throws -> AgentActionResult {
        let id = try uuid(json, "projectID", operation: "deleteProject")
        try store.deleteProject(id, actor: .agent)
        return success("Moved project \(id.uuidString) to trash. It can be restored from Quest.")
    }

    // The assistant reads these messages verbatim, so they must name the TOOL it
    // called (`add_link`), not the internal operation it routes to.
    private func addLink(_ json: [String: Any]) throws -> AgentActionResult {
        let target = try linkTarget(json, operation: "add_link")
        let link = try link(from: json, operation: "add_link")
        try store.addLink(to: target, link: link, actor: .agent)
        return success("Added \(link.scheme.rawValue) link \(link.label).")
    }

    private func removeLink(_ json: [String: Any]) throws -> AgentActionResult {
        let target = try linkTarget(json, operation: "remove_link")
        let link = try link(from: json, operation: "remove_link")
        try store.removeLink(from: target, link: link, actor: .agent)
        return success("Removed \(link.scheme.rawValue) link \(link.label).")
    }

    /// Plans first, and mutates nothing when the plan is invalid — the
    /// property that makes this tool safe to hand an assistant, since it can
    /// retry a corrected submission without worrying it partially landed.
    private func updateStatusScheme(_ json: [String: Any]) throws -> AgentActionResult {
        let projectID = try uuid(json, "projectID", operation: "update_status_scheme")
        let located = try locateProjectForMutation(projectID, operation: "update_status_scheme")

        guard let rawStatuses = json["statuses"] as? [[String: Any]], !rawStatuses.isEmpty else {
            throw ArgumentError(
                message:
                    "update_status_scheme: 'statuses' must be a non-empty array of "
                    + "{id, name, category, colorToken} objects, in board column order.")
        }

        var statuses: [Status] = []
        for raw in rawStatuses {
            guard let id = raw["id"] as? String, !id.isEmpty,
                let name = raw["name"] as? String,
                let rawCategory = raw["category"] as? String,
                let category = StatusCategory(rawValue: rawCategory)
            else {
                throw ArgumentError(
                    message:
                        "update_status_scheme: each status needs id, name and category "
                        + "(todo, active or done).")
            }
            // The colour vocabulary is a closed set, and it has to be closed on
            // BOTH write paths. An unknown token persists, renders as a
            // fallback, and is silently rewritten to `accentPrimary` the next
            // time the editor opens — which the next plan then reports as a
            // recolour the user never made.
            let rawColor = raw["colorToken"] as? String ?? ProjectColorToken.accentPrimary.rawValue
            guard ProjectColorToken(rawValue: rawColor) != nil else {
                throw ArgumentError(
                    message:
                        "update_status_scheme: '\(rawColor)' is not a valid colorToken. "
                        + "Valid values: \(ProjectColorToken.validNames).")
            }
            statuses.append(
                Status(
                    id: id, name: name, category: category,
                    colorToken: rawColor))
        }

        let reassignments = json["reassignments"] as? [String: String] ?? [:]
        let items = store.allItems(in: projectID)

        switch SchemePlan.plan(
            current: located.document.project.statusScheme,
            proposed: StatusScheme(statuses: statuses),
            reassignments: reassignments, items: items)
        {
        case .invalid(let message):
            return failure("update_status_scheme: \(message)")
        case .valid(let plan) where plan.changesNothing:
            // Say so plainly instead of committing an edit that edits nothing
            // and logging it as a scheme update.
            return success(
                "\(located.document.project.name)'s statuses already match "
                    + "what you sent; nothing changed.")
        case .valid(let plan):
            do {
                try store.applyScheme(plan, to: projectID, actor: .agent)
            } catch QuestError.schemeChangedUnderneath {
                return failure(
                    "update_status_scheme: this project's statuses changed since you "
                        + "read them. Call get_project again and re-submit the complete "
                        + "status list based on what it returns.")
            }
            return success("Updated \(located.document.project.name)'s statuses: \(plan.summary).")
        }
    }

    // MARK: helpers

    /// Resolves the project-or-item target, refusing trashed things through the
    /// same guards the other mutations use.
    ///
    /// `itemID` wins when both are given (documented in the tool descriptions).
    /// A present-but-unparseable id is an ARGUMENT error, not "absent": falling
    /// through to `projectID` would silently attach the link to the project
    /// while the assistant believed it had attached it to the item.
    private func linkTarget(_ json: [String: Any], operation: String) throws -> LinkTarget {
        if let raw = json["itemID"] as? String {
            guard let id = UUID(uuidString: raw) else {
                throw ArgumentError(message: "\(operation): invalid argument 'itemID'")
            }
            _ = try locateForMutation(id, operation: operation)
            return .item(id)
        }
        if let raw = json["projectID"] as? String {
            guard let id = UUID(uuidString: raw) else {
                throw ArgumentError(message: "\(operation): invalid argument 'projectID'")
            }
            _ = try locateProjectForMutation(id, operation: operation)
            return .project(id)
        }
        throw ArgumentError(message: "\(operation): missing or invalid argument 'projectID or itemID'")
    }

    /// Builds the link through the SAME validator the UI uses, so the repo rule
    /// has one definition.
    private func link(from json: [String: Any], operation: String) throws -> Link {
        guard let rawScheme = json["scheme"] as? String,
            let scheme = LinkScheme(rawValue: rawScheme), scheme != .unknown
        else {
            throw ArgumentError(message: "\(operation): missing or invalid argument 'scheme'")
        }
        guard let identifier = json["identifier"] as? String else {
            throw ArgumentError(message: "\(operation): missing or invalid argument 'identifier'")
        }
        switch LinkValidation.normalize(
            scheme: scheme, identifier: identifier,
            label: json["label"] as? String ?? "",
            repo: json["repo"] as? String)
        {
        case .valid(let link): return link
        case .invalid(let message): throw ValidationError(message: message)
        }
    }

    private struct LocatedProject {
        let document: ProjectDocument
        let isTrashed: Bool
    }

    /// The project-level counterpart of `locate`. `store.openProject` answers
    /// for trashed projects too — it has to, so the trash view can render them
    /// — which makes it this boundary's job to notice.
    private func locateProject(_ id: UUID) throws -> LocatedProject {
        guard let document = store.openProject(id) else { throw QuestError.projectNotFound(id) }
        return LocatedProject(
            document: document,
            isTrashed: store.trashedProjects.contains { $0.id == id })
    }

    /// Refuses a write aimed at a trashed project. Creating or editing inside
    /// one lands work where the user cannot see it, which is the same
    /// invisible-orphan failure as mutating a soft-deleted item.
    private func locateProjectForMutation(_ id: UUID, operation: String) throws -> LocatedProject {
        let located = try locateProject(id)
        if located.isTrashed {
            throw ArgumentError(
                message:
                    "\(operation): project \(located.document.project.name) is in the trash. "
                    + "Restore it from Quest's Trash before modifying it.")
        }
        return located
    }

    private struct LocatedItem {
        let projectID: UUID
        let item: WorkItem
        let projectIsTrashed: Bool

        /// nil when the item is fully live; otherwise why it is in the trash.
        var trashDescription: String? {
            switch (item.isDeleted, projectIsTrashed) {
            case (true, true): "this item and its project are both in the trash"
            case (true, false): "this item is in the trash"
            case (false, true): "this item's project is in the trash"
            case (false, false): nil
            }
        }
    }

    /// `store.projectID(owning:)` intentionally searches trashed projects too,
    /// so restore paths can find things. That makes it the assistant's job —
    /// and therefore this boundary's job — not to treat a trashed item as live.
    private func locate(_ id: UUID) throws -> LocatedItem {
        guard let projectID = store.projectID(owning: id),
            let document = store.openProject(projectID),
            let item = document.items.first(where: { $0.id == id })
        else { throw QuestError.itemNotFound(id) }
        return LocatedItem(
            projectID: projectID, item: item,
            projectIsTrashed: store.trashedProjects.contains { $0.id == projectID })
    }

    /// Same lookup, but refuses anything in the trash. Mutating a soft-deleted
    /// item would edit something the user cannot see and did not expect to
    /// still be writable; restoring first is the explicit step.
    private func locateForMutation(_ id: UUID, operation: String) throws -> LocatedItem {
        let located = try locate(id)
        if let reason = located.trashDescription {
            throw ArgumentError(
                message:
                    "\(operation): \(reason). Restore it from Quest's Trash before modifying it.")
        }
        return located
    }

    /// A missing or unparseable id argument is the caller's mistake, not "no
    /// such item" — reporting it as `itemNotFound` would hand the assistant a
    /// fabricated random id and mislabel "you forgot an argument" as "that
    /// item does not exist", which it cannot act on. This throws a distinct
    /// error naming the operation and the key instead. A well-formed id that
    /// simply doesn't resolve to anything is still reported by the caller as
    /// `QuestError.itemNotFound`/`projectNotFound`.
    private func uuid(_ json: [String: Any], _ key: String, operation: String) throws -> UUID {
        guard let raw = json[key] as? String, let id = UUID(uuidString: raw) else {
            throw ArgumentError(message: "\(operation): missing or invalid argument '\(key)'")
        }
        return id
    }

    /// Renders the status's display name (from the project's own scheme)
    /// rather than its raw id, which is what the assistant needs to reason
    /// about the item without a second lookup.
    private func describe(_ item: WorkItem, scheme: StatusScheme) -> String {
        let statusName = scheme.status(id: item.statusID)?.name ?? item.statusID
        return "\(item.id.uuidString)  [\(item.type.rawValue)/\(statusName)]  \(item.title)"
    }

    private func success(_ text: String) -> AgentActionResult {
        AgentActionResult(text: text, isError: false)
    }

    private func failure(_ text: String) -> AgentActionResult {
        AgentActionResult(text: text, isError: true)
    }
}

/// A malformed or missing call argument — distinct from `QuestError`, which
/// reports domain state (e.g. "no such item") the store already knows about.
private struct ArgumentError: Error {
    let message: String
}

/// A well-formed call whose values fail domain validation — e.g. a repo-scoped
/// link with no repo. Distinct from `ArgumentError` (an argument is missing or
/// the wrong shape) so the two failure modes stay readable at the call site.
private struct ValidationError: Error {
    let message: String
}
