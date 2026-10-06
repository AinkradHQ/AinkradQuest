import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("QuestMCPOperations — links")
struct QuestMCPLinkOperationsTests {
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
}
