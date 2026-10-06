import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("QuestMCPOperations")
struct QuestMCPOperationsTests {
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
    func depthRefused() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        let item = try store.createItem(
            projectID: project.id, parentID: epic.id, type: .task,
            title: "I", statusID: "todo", actor: .user)
        let subtask = try store.createItem(
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
    func search() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "Auth epic", statusID: "todo", actor: .user)
        _ = try store.createItem(
            projectID: project.id, parentID: epic.id, type: .bug,
            title: "Refresh token loops", statusID: "todo", actor: .user)

        let result = await operations.run(operation: "searchItems", arguments: #"{"query":"refresh"}"#)
        #expect(!result.isError)
        #expect(result.text.contains("Refresh token loops"))
        #expect(!result.text.contains("Auth epic"))
    }

    @Test("delete_item is soft — the item is recoverable afterwards")
    func softDelete() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)

        _ = await operations.run(
            operation: "deleteItem",
            arguments: #"{"itemID":"\#(epic.id.uuidString)"}"#)

        #expect(store.items(in: project.id).isEmpty)
        #expect(store.allItems(in: project.id).count == 1)
    }

    @Test("get_item says so when the item is in the trash")
    func getItemReportsTrash() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        let live = await operations.run(
            operation: "getItem",
            arguments: #"{"itemID":"\#(epic.id.uuidString)"}"#)
        #expect(!live.text.contains("IN TRASH"))

        try store.deleteItem(epic.id, actor: .user)
        let trashed = await operations.run(
            operation: "getItem",
            arguments: #"{"itemID":"\#(epic.id.uuidString)"}"#)
        #expect(!trashed.isError)
        #expect(trashed.text.contains("IN TRASH"))
    }

    @Test("mutations refuse a soft-deleted item and say it must be restored first")
    func mutationsRefuseTrashedItem() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        try store.deleteItem(epic.id, actor: .user)
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
    func mutationsRefuseItemInTrashedProject() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        try store.deleteProject(project.id, actor: .user)

        let result = await operations.run(
            operation: "setStatus",
            arguments: #"{"itemID":"\#(epic.id.uuidString)","statusID":"done"}"#)
        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
        #expect(store.allItems(in: project.id)[0].statusID == "todo")
    }

    @Test("create_item refuses a trashed parent — no live item under a deleted parent")
    func createItemRefusesTrashedParent() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        try store.deleteItem(epic.id, actor: .user)

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
    func createItemRefusesTrashedProject() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        try store.deleteProject(project.id, actor: .user)

        let result = await operations.run(
            operation: "createItem",
            arguments: #"{"projectID":"\#(project.id.uuidString)","type":"epic","title":"Hidden"}"#)

        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
        #expect(result.text.contains("Restore"))
        #expect(store.allItems(in: project.id).isEmpty)
    }

    @Test("update_project refuses a trashed project rather than succeeding silently")
    func updateProjectRefusesTrashedProject() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)
        try store.deleteProject(project.id, actor: .user)

        let result = await operations.run(
            operation: "updateProject",
            arguments: #"{"projectID":"\#(project.id.uuidString)","name":"Renamed"}"#)

        #expect(result.isError)
        #expect(result.text.lowercased().contains("trash"))
        #expect(result.text.contains("Restore"))
        #expect(store.trashedProjects.map(\.name) == ["P"])
    }

    @Test("get_project says so when the project is in the trash")
    func getProjectReportsTrash() async throws {
        let (operations, store) = makeSubject()
        let project = store.createProject(name: "P", kind: .software, actor: .user)

        let live = await operations.run(
            operation: "getProject",
            arguments: #"{"projectID":"\#(project.id.uuidString)"}"#)
        #expect(!live.isError)
        #expect(!live.text.contains("IN TRASH"))

        try store.deleteProject(project.id, actor: .user)
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
}
