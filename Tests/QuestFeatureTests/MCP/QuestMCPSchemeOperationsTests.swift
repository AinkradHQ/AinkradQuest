import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("QuestMCPOperations — status scheme")
struct QuestMCPSchemeOperationsTests {
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
