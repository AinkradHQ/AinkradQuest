import AinkradAppKit
import Foundation

/// Publishes Quest's projects and work items to the host assistant.
///
/// Follows the declarative-table shape of `LoreMCPServer`, `GitMageMCPServer`
/// and `LeylineMCPServer`. Quest is the fifth adopter, and what it does
/// differently is the classification, which is worth stating plainly.
///
/// ## Destructive classification
///
/// `destructive` is what the host's Full-auto guard gates on.
///
/// - Reads (`list_projects`, `get_project`, `search_items`, `get_item`) are
///   `readOnly: true`. They read a store the plugin already holds.
/// - **Creates and updates are NOT destructive**, which is the deliberate call.
///   Quest exists so the assistant can file and move real work; gating every
///   `create_item` behind approval would make the app's whole reason for
///   existing require a click. Every one of them is logged with `actor: .agent`
///   and every one is editable afterwards.
/// - `delete_item` and `delete_project` are **`destructive: true`** even though
///   both are SOFT — nothing is erased and both are restorable. They are gated
///   because removing a project or an epic from every surface is disruptive at
///   a scale a person should agree to first, and because the agent cannot judge
///   what a stale-looking item was for. Reversible is not the same as
///   consequence-free.
/// - **`add_link` and `remove_link` are mutating and NOT destructive**, for the
///   same reason creates and updates are not. Attaching or detaching a
///   reference is cheap, visible in the activity feed, and — unlike a delete —
///   trivially reversible by calling the other tool with the same arguments.
/// - `update_status_scheme` is **`destructive: true`**. Unlike every other
///   mutation, this one rewrites many existing items in a single call —
///   reassigning statuses and stamping or clearing `closedAt` — and the agent
///   has no way to judge what a workflow column meant to the people using it.
///   A rename is cheap to get wrong; silently moving a hundred items off a
///   column the agent decided to drop is not.
///
/// `requiresLiveApp` is false on all of them: the store is loaded from
/// `host.documents` and works with no Quest window open, which is what lets the
/// assistant file a task while you are in a terminal.
@MainActor
public enum QuestMCPServer {
    public struct Tool {
        public let name: String
        /// The operation token forwarded to `QuestMCPOperations`.
        public let operation: String
        public let summary: String
        public let destructive: Bool
        public let readOnly: Bool
        public let schemaJSON: String

        init(
            _ name: String, _ operation: String, _ summary: String,
            destructive: Bool = false, readOnly: Bool = false, schemaJSON: String
        ) {
            self.name = name
            self.operation = operation
            self.summary = summary
            self.destructive = destructive
            self.readOnly = readOnly
            self.schemaJSON = schemaJSON
        }
    }

    static func schema(
        _ properties: [(String, String, String)],
        required: [String] = []
    ) -> String {
        let fields = properties.map { name, type, description in
            "\"\(name)\":{\"type\":\"\(type)\",\"description\":\"\(description)\"}"
        }.joined(separator: ",")
        let requiredList = required.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"type\":\"object\",\"properties\":{\(fields)},\"required\":[\(requiredList)]}"
    }

    /// The operation each tool's `operation` field routes to. Kept in sync
    /// with `QuestMCPOperations.run(operation:arguments:)`'s exact switch
    /// tokens by `QuestMCPServerTests.operationTokensMatchOperationsLayer`,
    /// so a typo here fails a test rather than silently producing a tool that
    /// always errors at runtime.
    public static let tools: [Tool] = [
        Tool(
            "list_projects", "listProjects",
            "List every project in Quest with its id, name and state. Start here: the "
                + "returned project id is what every other Quest tool takes.",
            readOnly: true, schemaJSON: schema([])),

        Tool(
            "get_project", "getProject",
            "Read one project in full: its status scheme, links, and every live work item "
                + "with id, type, status and title.",
            readOnly: true,
            schemaJSON: schema(
                [("projectID", "string", "The project's UUID.")],
                required: ["projectID"])),

        Tool(
            "search_items", "searchItems",
            "Search work items by text across one project or all of them. Matches title, "
                + "body and labels, case-insensitively.",
            readOnly: true,
            schemaJSON: schema([
                ("query", "string", "Text to match. Omit to list everything."),
                ("projectID", "string", "Optional project UUID to search within."),
                ("statusID", "string", "Optional status id to restrict to."),
            ])),

        Tool(
            "get_item", "getItem",
            "Read one work item in full, including its body, labels, dates and priority.",
            readOnly: true,
            schemaJSON: schema(
                [("itemID", "string", "The item's UUID.")],
                required: ["itemID"])),

        Tool(
            "create_project", "createProject",
            "Create a project. Kind 'software' gets the Backlog/Todo/In Progress/In Review/"
                + "Done scheme; 'general' gets the same without In Review.",
            schemaJSON: schema(
                [
                    ("name", "string", "Project name."),
                    ("kind", "string", "'software' or 'general'. Defaults to 'software'."),
                ], required: ["name"])),

        Tool(
            "update_project", "updateProject",
            "Rename a project or change its summary text.",
            schemaJSON: schema(
                [
                    ("projectID", "string", "The project's UUID."),
                    ("name", "string", "New name. Omit to leave unchanged."),
                    ("summary", "string", "New summary text. Omit to leave unchanged."),
                ], required: ["projectID"])),

        Tool(
            "create_item", "createItem",
            "Create a work item. Hierarchy is capped at three levels: an epic has no "
                + "parent, an item's parent is an epic, a subtask's parent is an item. Only "
                + "epics may sit at the top level.",
            schemaJSON: schema(
                [
                    ("projectID", "string", "The project's UUID."),
                    ("parentID", "string", "Parent item UUID. Omit only when type is 'epic'."),
                    ("type", "string", "epic, task, bug, story, chore or spike."),
                    ("title", "string", "The item's title."),
                    ("statusID", "string", "A status id from the project's scheme. Defaults to 'todo'."),
                ], required: ["projectID", "title"])),

        Tool(
            "update_item", "updateItem",
            "Change a work item's title, body, labels or priority.",
            schemaJSON: schema(
                [
                    ("itemID", "string", "The item's UUID."),
                    ("title", "string", "New title."),
                    ("body", "string", "New markdown body."),
                    ("labels", "array", "Replacement label list."),
                    ("priority", "integer", "0 none, 1 low, 2 medium, 3 high, 4 urgent."),
                ], required: ["itemID"])),

        Tool(
            "move_item", "moveItem",
            "Reparent a work item or change its manual order. Refused if it would exceed "
                + "three levels or place an item under its own descendant.",
            schemaJSON: schema(
                [
                    ("itemID", "string", "The item's UUID."),
                    ("parentID", "string", "New parent UUID. Omit to move to the top level (epics only)."),
                    ("orderIndex", "integer", "Position among siblings."),
                ], required: ["itemID"])),

        Tool(
            "set_status", "setStatus",
            "Move a work item to another status from its project's scheme. Moving to a "
                + "status in the 'done' category closes the item.",
            schemaJSON: schema(
                [
                    ("itemID", "string", "The item's UUID."),
                    ("statusID", "string", "A status id from the project's scheme."),
                ], required: ["itemID", "statusID"])),

        Tool(
            "delete_item", "deleteItem",
            "Move a work item and its descendants to the trash. This is a SOFT delete — "
                + "nothing is erased and the item can be restored from Quest — but it removes "
                + "the item from every board and list.",
            destructive: true,
            schemaJSON: schema(
                [("itemID", "string", "The item's UUID.")],
                required: ["itemID"])),

        Tool(
            "delete_project", "deleteProject",
            "Move a whole project to the trash. SOFT and restorable, but it removes the "
                + "project and all of its work from every surface.",
            destructive: true,
            schemaJSON: schema(
                [("projectID", "string", "The project's UUID.")],
                required: ["projectID"])),

        Tool(
            "add_link", "addLink",
            "Attach a link to a project or a work item. Give EITHER projectID or itemID; "
                + "if you give both, itemID wins and the link goes on the item. "
                + "Links are how Quest points at the rest of your world: repos, branches, PRs, "
                + "commits, folders, files and URLs. A branch, pr or commit link MUST also name "
                + "its repo, because a project routinely has several.",
            schemaJSON: schema(
                [
                    ("projectID", "string", "The project's UUID. Give this or itemID."),
                    ("itemID", "string", "The work item's UUID. Give this or projectID."),
                    ("scheme", "string", "repo, branch, pr, commit, folder, file or url."),
                    ("identifier", "string", "The path, URL, branch name, PR number or commit sha."),
                    ("label", "string", "Display label. Defaults to the identifier."),
                    ("repo", "string", "Which repo a branch/pr/commit belongs to. Required for those."),
                ], required: ["scheme", "identifier"])),

        Tool(
            "remove_link", "removeLink",
            "Remove a link from a project or a work item. Give EITHER projectID or itemID; "
                + "if you give both, itemID wins. Identify the link by the same scheme, "
                + "identifier AND repo it was added with — a branch link is identified by its "
                + "repo as well, so 'main' in one repo is not 'main' in another.",
            schemaJSON: schema(
                [
                    ("projectID", "string", "The project's UUID. Give this or itemID."),
                    ("itemID", "string", "The work item's UUID. Give this or projectID."),
                    ("scheme", "string", "The link's scheme."),
                    ("identifier", "string", "The link's identifier."),
                    ("repo", "string", "The link's repo, for branch/pr/commit links."),
                ], required: ["scheme", "identifier"])),

        Tool(
            "update_status_scheme", "updateStatusScheme",
            "Replace a project's status scheme. Send the COMPLETE ordered list of statuses "
                + "— board columns appear in this order — each with id, name, category (todo, "
                + "active or done) and colorToken. Ids are permanent: keep an existing status's "
                + "id to rename it, and use a new id only for a genuinely new status. "
                + "colorToken must be one of: accentPrimary, accentSecondary, success, "
                + "warning, danger, muted. A scheme must contain at least one 'done' status. "
                + "If you drop a status that still holds items, name where they go in "
                + "'reassignments' ({removedStatusID: destinationStatusID}), or the call is "
                + "refused and nothing changes. 'reassignments' may ONLY be keyed on statuses "
                + "you are removing — it is not a way to bulk-move items between statuses that "
                + "both remain; use set_status for that. Items moved by a reassignment "
                + "get closedAt stamped or cleared from the DESTINATION status's category.",
            destructive: true,
            schemaJSON: schema(
                [
                    ("projectID", "string", "The project's UUID."),
                    ("statuses", "array", "The complete ordered status list."),
                    (
                        "reassignments", "object",
                        "removedStatusID → destinationStatusID, for "
                            + "removed statuses that still hold items."
                    ),
                ], required: ["projectID", "statuses"])),
    ]

    /// Internal rather than private so tests can drive routing without a host.
    static func invoke(
        _ tool: Tool, arguments: String,
        perform: @MainActor @Sendable (String, String) async -> AgentActionResult
    )
        async -> AgentActionResult
    {
        await perform(tool.operation, arguments)
    }

    public static func make(
        appID: String,
        perform: @escaping @MainActor @Sendable (String, String) async -> AgentActionResult
    ) -> (server: MCPAppServer, failures: [String]) {
        let server = MCPAppServer(appID: appID)
        var failures: [String] = []
        for tool in tools {
            let added = server.addTool(
                MCPToolSpec(
                    name: tool.name,
                    description: tool.summary,
                    schemaJSON: tool.schemaJSON,
                    destructive: tool.destructive,
                    readOnly: tool.readOnly,
                    handler: { arguments in await invoke(tool, arguments: arguments, perform: perform) }))
            if !added { failures.append(tool.name) }
        }
        return (server, failures)
    }
}
