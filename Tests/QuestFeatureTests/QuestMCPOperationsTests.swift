import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("QuestMCPOperations")
struct QuestMCPOperationsTests {
    private func makeSubject() -> (QuestMCPOperations, ProjectStore) {
        let store = makeProjectStore(InMemoryProjectRepository())
        return (QuestMCPOperations(store: store), store)
    }

    @Test("create_project creates a project and reports its id")
    func createProject() async {
        let (operations, store) = makeSubject()
        let result = await operations.run(
            operation: "createProject",
            arguments: #"{"name":"Optimus","kind":"software"}"#)
        #expect(!result.isError)
        #expect(store.projects.map(\.name) == ["Optimus"])
        #expect(result.text.contains(store.projects[0].id.uuidString))
    }

    @Test("every agent mutation is logged as the agent, not the user")
    func actorIsAgent() async {
        let (operations, store) = makeSubject()
        _ = await operations.run(operation: "createProject", arguments: #"{"name":"A","kind":"general"}"#)
        #expect(store.activity(for: store.projects[0].id).allSatisfy { $0.actor == .agent })
    }

    @Test("create_item refuses a fourth hierarchy level with the typed message")
    func depthRefused() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try! store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        let item = try! store.createItem(
            projectID: project.id, parentID: epic.id, type: .task,
            title: "I", statusID: "todo", actor: .user)
        let subtask = try! store.createItem(
            projectID: project.id, parentID: item.id, type: .task,
            title: "S", statusID: "todo", actor: .user)

        let result = await operations.run(
            operation: "createItem",
            arguments:
                #"{"projectID":"\#(project.id.uuidString)","parentID":"\#(subtask.id.uuidString)","type":"task","title":"X","statusID":"todo"}"#
        )

        #expect(result.isError)
        #expect(result.text.contains("capped at 3 levels"))
    }

    @Test("malformed arguments are an error, not a crash")
    func malformed() async {
        let (operations, _) = makeSubject()
        let result = await operations.run(operation: "createProject", arguments: "not json")
        #expect(result.isError)
    }

    @Test("an unknown operation is refused by name")
    func unknownOperation() async {
        let (operations, _) = makeSubject()
        let result = await operations.run(operation: "launchMissiles", arguments: "{}")
        #expect(result.isError)
        #expect(result.text.contains("launchMissiles"))
    }

    @Test("search_items matches across projects and returns titles")
    func search() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try! store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "Auth epic", statusID: "todo", actor: .user)
        _ = try! store.createItem(
            projectID: project.id, parentID: epic.id, type: .bug,
            title: "Refresh token loops", statusID: "todo", actor: .user)

        let result = await operations.run(operation: "searchItems", arguments: #"{"query":"refresh"}"#)
        #expect(!result.isError)
        #expect(result.text.contains("Refresh token loops"))
        #expect(!result.text.contains("Auth epic"))
    }

    @Test("delete_item is soft — the item is recoverable afterwards")
    func softDelete() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try! store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)

        _ = await operations.run(
            operation: "deleteItem",
            arguments: #"{"itemID":"\#(epic.id.uuidString)"}"#)

        #expect(store.items(in: project.id).isEmpty)
        #expect(store.allItems(in: project.id).count == 1)
    }

    @Test("get_item says so when the item is in the trash")
    func getItemReportsTrash() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try! store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        let live = await operations.run(
            operation: "getItem",
            arguments: #"{"itemID":"\#(epic.id.uuidString)"}"#)
        #expect(!live.text.contains("IN TRASH"))

        try! store.deleteItem(epic.id, actor: .user)
        let trashed = await operations.run(
            operation: "getItem",
            arguments: #"{"itemID":"\#(epic.id.uuidString)"}"#)
        #expect(!trashed.isError)
        #expect(trashed.text.contains("IN TRASH"))
    }

    @Test("mutations refuse a soft-deleted item and say it must be restored first")
    func mutationsRefuseTrashedItem() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try! store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        try! store.deleteItem(epic.id, actor: .user)
        let id = epic.id.uuidString

        for (operation, arguments) in [
            ("updateItem", #"{"itemID":"\#(id)","title":"Edited"}"#),
            ("setStatus", #"{"itemID":"\#(id)","statusID":"done"}"#),
            ("moveItem", #"{"itemID":"\#(id)","orderIndex":3}"#),
        ] {
            let result = await operations.run(operation: operation, arguments: arguments)
            #expect(result.isError, "\(operation) should refuse a trashed item")
            #expect(result.text.lowercased().contains("trash"))
            #expect(result.text.contains("Restore"))
        }
        #expect(store.allItems(in: project.id)[0].title == "E")
        #expect(store.allItems(in: project.id)[0].statusID == "todo")
    }

    @Test("mutations refuse an item inside a trashed project")
    func mutationsRefuseItemInTrashedProject() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try! store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        try! store.deleteProject(project.id, actor: .user)

        let result = await operations.run(
            operation: "setStatus",
            arguments: #"{"itemID":"\#(epic.id.uuidString)","statusID":"done"}"#)
        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
        #expect(store.allItems(in: project.id)[0].statusID == "todo")
    }

    @Test("create_item refuses a trashed parent — no live item under a deleted parent")
    func createItemRefusesTrashedParent() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try! store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        try! store.deleteItem(epic.id, actor: .user)

        let result = await operations.run(
            operation: "createItem",
            arguments:
                #"{"projectID":"\#(project.id.uuidString)","parentID":"\#(epic.id.uuidString)","type":"task","title":"Orphan"}"#
        )

        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
        #expect(result.text.contains("Restore"))
        // Nothing was created: only the trashed epic exists.
        #expect(store.allItems(in: project.id).map(\.title) == ["E"])
    }

    @Test("create_item refuses a trashed project — work cannot land where the user cannot see it")
    func createItemRefusesTrashedProject() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        try! store.deleteProject(project.id, actor: .user)

        let result = await operations.run(
            operation: "createItem",
            arguments: #"{"projectID":"\#(project.id.uuidString)","type":"epic","title":"Hidden"}"#)

        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
        #expect(result.text.contains("Restore"))
        #expect(store.allItems(in: project.id).isEmpty)
    }

    @Test("update_project refuses a trashed project rather than succeeding silently")
    func updateProjectRefusesTrashedProject() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        try! store.deleteProject(project.id, actor: .user)

        let result = await operations.run(
            operation: "updateProject",
            arguments: #"{"projectID":"\#(project.id.uuidString)","name":"Renamed"}"#)

        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
        #expect(result.text.contains("Restore"))
        #expect(store.trashedProjects.map(\.name) == ["P"])
    }

    @Test("get_project says so when the project is in the trash")
    func getProjectReportsTrash() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        let live = await operations.run(
            operation: "getProject",
            arguments: #"{"projectID":"\#(project.id.uuidString)"}"#)
        #expect(!live.isError)
        #expect(!live.text.contains("IN TRASH"))

        try! store.deleteProject(project.id, actor: .user)
        let trashed = await operations.run(
            operation: "getProject",
            arguments: #"{"projectID":"\#(project.id.uuidString)"}"#)
        #expect(!trashed.isError)
        #expect(trashed.text.contains("IN TRASH"))
    }

    @Test("a missing required argument reports the argument name, not a fabricated item id")
    func missingArgumentIsNotMisreportedAsItemNotFound() async {
        let (operations, _) = makeSubject()
        let result = await operations.run(operation: "getItem", arguments: "{}")
        #expect(result.isError)
        #expect(result.text.contains("itemID"))
        #expect(result.text.contains("getItem"))
    }

    @Test("add_link attaches to a project and reports it")
    func addProjectLink() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        let result = await operations.run(
            operation: "addLink",
            arguments:
                #"{"projectID":"\#(project.id.uuidString)","scheme":"repo","identifier":"~/Projects/p","label":"p"}"#)

        #expect(!result.isError)
        #expect(store.openProject(project.id)?.project.links.count == 1)
    }

    @Test("add_link enforces the repo rule for repo-scoped schemes")
    func repoRuleEnforced() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        let result = await operations.run(
            operation: "addLink",
            arguments:
                #"{"projectID":"\#(project.id.uuidString)","scheme":"branch","identifier":"main","label":"main"}"#)

        #expect(result.isError)
        #expect(result.text.contains("repo"))
        #expect(store.openProject(project.id)?.project.links.isEmpty == true)
    }

    @Test("add_link refuses a trashed project")
    func refusesTrashedProject() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        try store.deleteProject(project.id, actor: .user)

        let result = await operations.run(
            operation: "addLink",
            arguments:
                #"{"projectID":"\#(project.id.uuidString)","scheme":"url","identifier":"https://x.dev","label":"x"}"#)

        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
    }

    @Test("add_link attaches to an item and records the agent as actor")
    func addItemLink() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)

        let result = await operations.run(
            operation: "addLink",
            arguments:
                #"{"itemID":"\#(epic.id.uuidString)","scheme":"pr","identifier":"42","label":"PR 42","repo":"quest"}"#)

        #expect(!result.isError)
        #expect(store.items(in: project.id).first?.links.first?.repo == "quest")
        #expect(store.activity(for: project.id).last?.actor == .agent)
    }

    @Test("a call naming neither a project nor an item is refused")
    func requiresATarget() async {
        let (operations, _) = makeSubject()
        let result = await operations.run(
            operation: "addLink",
            arguments: #"{"scheme":"url","identifier":"https://x.dev"}"#)
        #expect(result.isError)
    }

    @Test("remove_link removes a link previously added")
    func removeLink() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        _ = await operations.run(
            operation: "addLink",
            arguments: #"{"projectID":"\#(project.id.uuidString)","scheme":"repo","identifier":"~/p","label":"p"}"#)

        let result = await operations.run(
            operation: "removeLink",
            arguments: #"{"projectID":"\#(project.id.uuidString)","scheme":"repo","identifier":"~/p"}"#)

        #expect(!result.isError)
        #expect(store.openProject(project.id)?.project.links.isEmpty == true)
    }

    @Test("remove_link removes the named repo's link, not another repo's")
    func removeLinkDiscriminatesByRepo() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        for repo in ["alpha", "beta"] {
            let added = await operations.run(
                operation: "addLink",
                arguments:
                    #"{"projectID":"\#(project.id.uuidString)","scheme":"branch","identifier":"main","label":"main","repo":"\#(repo)"}"#
            )
            #expect(!added.isError)
        }

        let result = await operations.run(
            operation: "removeLink",
            arguments: #"{"projectID":"\#(project.id.uuidString)","scheme":"branch","identifier":"main","repo":"beta"}"#
        )

        #expect(!result.isError)
        // The `repo` argument the tool advertises is now actually honoured when
        // matching; before, it was accepted and ignored and "alpha" was deleted.
        #expect(store.openProject(project.id)?.project.links.map(\.repo) == ["alpha"])
    }

    @Test("link tool errors name the tool the assistant called, not the internal operation")
    func errorNamesTheTool() async {
        let (operations, _) = makeSubject()
        let result = await operations.run(
            operation: "addLink",
            arguments: #"{"scheme":"url","identifier":"https://x.dev"}"#)

        #expect(result.isError)
        #expect(result.text.contains("add_link"))
        #expect(!result.text.contains("addLink"))
    }

    @Test("an unparseable itemID is an argument error, not a silent fall-through to projectID")
    func unparseableItemIDIsRefused() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        let result = await operations.run(
            operation: "addLink",
            arguments:
                #"{"itemID":"not-a-uuid","projectID":"\#(project.id.uuidString)","scheme":"url","identifier":"https://x.dev"}"#
        )

        #expect(result.isError)
        #expect(result.text.contains("itemID"))
        // The link must NOT have quietly landed on the project instead.
        #expect(store.openProject(project.id)?.project.links.isEmpty == true)
    }

    @Test("itemID wins when both ids are supplied, as the tool description promises")
    func itemIDTakesPrecedence() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)

        let result = await operations.run(
            operation: "addLink",
            arguments:
                #"{"itemID":"\#(epic.id.uuidString)","projectID":"\#(project.id.uuidString)","scheme":"url","identifier":"https://x.dev"}"#
        )

        #expect(!result.isError)
        #expect(store.items(in: project.id).first?.links.count == 1)
        #expect(store.openProject(project.id)?.project.links.isEmpty == true)
    }

    @Test("add_link refuses a duplicate rather than attaching the same link twice")
    func duplicateLinkRefused() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let arguments = #"{"projectID":"\#(project.id.uuidString)","scheme":"repo","identifier":"~/p","label":"p"}"#

        _ = await operations.run(operation: "addLink", arguments: arguments)
        let result = await operations.run(operation: "addLink", arguments: arguments)

        #expect(result.isError)
        #expect(store.openProject(project.id)?.project.links.count == 1)
    }

    @Test("update_status_scheme replaces the scheme and reassigns items")
    func updateScheme() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"""
                {"projectID":"\#(project.id.uuidString)",
                 "statuses":[{"id":"todo","name":"Todo","category":"todo","colorToken":"accentPrimary"},
                             {"id":"done","name":"Done","category":"done","colorToken":"success"}],
                 "reassignments":{"in_review":"todo","backlog":"todo","in_progress":"todo"}}
                """#)

        #expect(!result.isError)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.statusID == "todo")
        #expect(result.text.contains("todo") || result.text.contains("Todo"))
    }

    @Test("an invalid scheme is refused and changes nothing")
    func invalidSchemeChangesNothing() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"""
                {"projectID":"\#(project.id.uuidString)",
                 "statuses":[{"id":"todo","name":"Todo","category":"todo","colorToken":"accentPrimary"}]}
                """#)

        #expect(result.isError)
        #expect(result.text.lowercased().contains("done"))
        #expect(store.openProject(project.id)?.project.statusScheme == .softwareDefault)
    }

    @Test("a removal with items but no destination is refused")
    func refusesUnmappedRemoval() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        _ = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"""
                {"projectID":"\#(project.id.uuidString)",
                 "statuses":[{"id":"todo","name":"Todo","category":"todo","colorToken":"accentPrimary"},
                             {"id":"done","name":"Done","category":"done","colorToken":"success"}]}
                """#)

        #expect(result.isError)
        #expect(store.openProject(project.id)?.project.statusScheme == .softwareDefault)
    }

    @Test("a trashed project is refused for update_status_scheme")
    func schemeRefusesTrashedProject() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        try store.deleteProject(project.id, actor: .user)

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"""
                {"projectID":"\#(project.id.uuidString)",
                 "statuses":[{"id":"done","name":"Done","category":"done","colorToken":"success"}]}
                """#)

        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
    }

    @Test("a reassignment for a status that is not being removed is refused, and nothing moves")
    func schemeRefusesUnremovedReassignmentKey() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)

        // The full scheme unchanged, plus a reassignment naming a status that
        // survives and a destination that does not exist. Pre-fix this
        // returned success, said "no changes", and rewrote every todo item's
        // statusID to a status absent from the scheme.
        let statuses = StatusScheme.softwareDefault.statuses.map {
            #"{"id":"\#($0.id)","name":"\#($0.name)","category":"\#($0.category.rawValue)","colorToken":"\#($0.colorToken)"}"#
        }.joined(separator: ",")

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"""
                {"projectID":"\#(project.id.uuidString)",
                 "statuses":[\#(statuses)],
                 "reassignments":{"todo":"nonexistent"}}
                """#)

        #expect(result.isError)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.statusID == "todo")
        #expect(store.openProject(project.id)?.project.statusScheme == .softwareDefault)
    }

    @Test("a reassignment used to bulk-move a surviving status's items is refused")
    func schemeRefusesBulkMoveViaReassignment() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        let statuses = StatusScheme.softwareDefault.statuses.map {
            #"{"id":"\#($0.id)","name":"\#($0.name)","category":"\#($0.category.rawValue)","colorToken":"\#($0.colorToken)"}"#
        }.joined(separator: ",")

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"""
                {"projectID":"\#(project.id.uuidString)",
                 "statuses":[\#(statuses)],
                 "reassignments":{"todo":"done"}}
                """#)

        #expect(result.isError)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.statusID == "todo")
    }

    @Test("an unknown colorToken is refused with the valid values listed")
    func schemeRefusesUnknownColorToken() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"""
                {"projectID":"\#(project.id.uuidString)",
                 "statuses":[{"id":"done","name":"Done","category":"done","colorToken":"banana"}]}
                """#)

        #expect(result.isError)
        #expect(result.text.contains("banana"))
        #expect(result.text.contains("accentPrimary"))
        #expect(store.openProject(project.id)?.project.statusScheme == .softwareDefault)
    }

    @Test("a no-op scheme submission says nothing changed and logs no event")
    func schemeNoOpDoesNotWrite() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let before = try #require(store.openProject(project.id)).activity.count
        let statuses = StatusScheme.softwareDefault.statuses.map {
            #"{"id":"\#($0.id)","name":"\#($0.name)","category":"\#($0.category.rawValue)","colorToken":"\#($0.colorToken)"}"#
        }.joined(separator: ",")

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"""
                {"projectID":"\#(project.id.uuidString)","statuses":[\#(statuses)]}
                """#)

        #expect(!result.isError)
        #expect(result.text.lowercased().contains("nothing"))
        #expect(store.openProject(project.id)?.activity.count == before)
    }

    @Test("malformed status entries are an argument error, not a crash")
    func malformedStatuses() async {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        let result = await operations.run(
            operation: "updateStatusScheme",
            arguments: #"{"projectID":"\#(project.id.uuidString)","statuses":"not an array"}"#)

        #expect(result.isError)
    }

    @Test("update_status_scheme tells the agent to re-read when the scheme moved underneath")
    func schemeStalenessIsExplained() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        // The agent's submission is built from the scheme as it reads it, so to
        // exercise staleness the store must change between plan and apply. The
        // operation plans internally, so drive it through the store directly:
        // build a plan, change the scheme, then apply the stale plan.
        var proposedA = StatusScheme.softwareDefault
        proposedA.statuses.removeAll { $0.id == "in_review" }
        let stale = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: proposedA,
                reassignments: [:], items: []
            ).value)

        var proposedB = StatusScheme.softwareDefault
        proposedB.statuses[0] = Status(
            id: "backlog", name: "Icebox",
            category: .todo, colorToken: "muted")
        let fresh = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: proposedB,
                reassignments: [:], items: []
            ).value)
        try store.applyScheme(fresh, to: project.id, actor: .agent)

        #expect(throws: QuestError.schemeChangedUnderneath) {
            try store.applyScheme(stale, to: project.id, actor: .agent)
        }
        // And the message the tool would relay names the recovery action.
        #expect(
            QuestError.schemeChangedUnderneath.message.lowercased().contains("apply again")
                || QuestError.schemeChangedUnderneath.message.lowercased().contains("review"))
    }
}
