import Foundation
import QuestCitadelAPI
import Testing

@testable import QuestFeature

private func issue(
    _ id: Int64, rank: Double, state: String = "backlog", epic: Int64? = nil, sprint: Int64? = nil,
    requirement: Int64? = nil, points: Int? = 3, owner: ServerActor = .none, kind: String = "task"
) -> ServerIssue {
    ServerIssue(
        id: id, key: "CIT-\(id)", projectID: 1, kind: kind, title: "Issue \(id)", body: "", state: state, rank: rank,
        points: points, epicID: epic, sprintID: sprint, requirementID: requirement, owner: owner, next: .human(1),
        runID: nil)
}

@Suite("Server mapping")
struct ServerMappingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try EventFrame.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test("an issue maps every field Quest shows, actors included")
    func issueMapping() throws {
        let wire = try decode(
            Schemas.Issue.self,
            """
            {"id": 62, "key": "CIT-62", "project_id": 1, "number": 62, "kind": "story", "title": "APNs push",
             "body": "b", "state": "in_review", "rank": 1.5, "points": 8, "epic_id": 10, "sprint_id": 5,
             "requirement_id": 12, "checkout_run_id": 7,
             "owner": {"kind": "agent", "agent_id": 3}, "next_actor": {"kind": "human", "user_id": 1}}
            """)
        let mapped = ServerIssue(wire)
        #expect(mapped.key == "CIT-62")
        #expect(mapped.kind == "story")
        #expect(mapped.state == "in_review")
        #expect(mapped.points == 8)
        #expect(mapped.epicID == 10 && mapped.sprintID == 5 && mapped.requirementID == 12)
        #expect(mapped.owner == .agent(3))
        #expect(mapped.next == .human(1))
        #expect(mapped.runID == 7)
        #expect(mapped.isOpen)
    }

    @Test("a newer server's state word survives, and a bare issue maps with no actors")
    func openWordsAndOptionals() throws {
        let wire = try decode(
            Schemas.Issue.self,
            """
            {"id": 1, "key": "CIT-1", "project_id": 1, "number": 1, "kind": "chore", "title": "t", "body": "",
             "state": "parked", "rank": 0}
            """)
        let mapped = ServerIssue(wire)
        #expect(mapped.state == "parked")
        #expect(mapped.kind == "chore")
        #expect(mapped.owner == .none && mapped.next == .none)
        #expect(mapped.points == nil)
    }

    @Test("project mode and sprint-approval policy")
    func projectMapping() throws {
        let kanban = ServerProject(
            try decode(
                Schemas.Project.self,
                #"{"id": 2, "company_id": 1, "name": "Mac Client", "key": "AMC", "mode": "kanban", "sprint_approval": "product_owner"}"#
            ))
        #expect(kanban.mode == .kanban)
        #expect(!kanban.ownerApprovesSprints)
        let scrum = ServerProject(
            try decode(
                Schemas.Project.self,
                #"{"id": 1, "company_id": 1, "name": "Citadel", "key": "CIT", "mode": "scrum", "sprint_approval": "owner"}"#
            ))
        #expect(scrum.mode == .scrum)
        #expect(scrum.ownerApprovesSprints)
    }

    @Test("sprint days and a report's burndown parse as days")
    func sprintMapping() throws {
        let sprint = ServerSprint(
            try decode(
                Schemas.Sprint.self,
                #"{"id": 5, "project_id": 1, "name": "S4", "goal": "g", "state": "active", "starts_on": "2026-10-18", "ends_on": "2026-10-27"}"#
            ))
        #expect(sprint.startsOn != nil && sprint.endsOn != nil)
        let report = SprintReportInfo(
            try decode(
                Schemas.SprintReport.self,
                #"{"sprint_id": 5, "state": "active", "committed": 34, "completed": 11, "capacity": 34, "burndown": [{"day": "2026-10-18", "left": 34}, {"day": "2026-10-19", "left": 31}]}"#
            ))
        #expect(report.burndown.map(\.left) == [34, 31])
        #expect(report.committed == 34 && report.capacity == 34)
    }
}

@Suite("Backlog ordering")
struct BacklogOrderingTests {
    let order = [issue(1, rank: 1), issue(2, rank: 2), issue(3, rank: 3), issue(4, rank: 4)]

    @Test("the backlog is open, unsprinted items in rank order")
    func backlog() {
        let all = [
            issue(3, rank: 3), issue(1, rank: 1), issue(2, rank: 2, sprint: 9), issue(4, rank: 0, state: "done"),
            issue(5, rank: 1),
        ]
        #expect(BacklogLogic.backlog(all).map(\.id) == [1, 5, 3])
    }

    @Test("groups keep their top item's order and put No epic last, with epic progress")
    func groups() {
        let backlog = [issue(1, rank: 1), issue(2, rank: 2, epic: 20), issue(3, rank: 3, epic: 10)]
        let all = backlog + [issue(9, rank: 9, state: "done", epic: 20)]
        let groups = BacklogLogic.groups(
            backlog,
            epics: [ServerEpic(id: 10, title: "A", status: "open"), ServerEpic(id: 20, title: "B", status: "open")],
            all: all)
        #expect(groups.map(\.epic?.id) == [20, 10, nil])
        #expect(groups[0].done == 1 && groups[0].total == 2)
    }

    @Test("dragging down lands after the row above the slot; up, before the row below it")
    func moves() {
        #expect(BacklogLogic.move(1, to: 3, in: order, epic: nil) == RankMove(issue: 1, place: .before(4), epic: nil))
        #expect(BacklogLogic.move(1, to: 4, in: order, epic: nil) == RankMove(issue: 1, place: .after(4), epic: nil))
        #expect(BacklogLogic.move(4, to: 0, in: order, epic: nil) == RankMove(issue: 4, place: .before(1), epic: nil))
    }

    @Test("dropping a row where it already is asks nothing")
    func noOp() {
        #expect(BacklogLogic.move(2, to: 1, in: order, epic: nil) == nil)
        #expect(BacklogLogic.move(2, to: 2, in: order, epic: nil) == nil)
    }

    @Test("dropping into another epic's group moves it to that epic too")
    func crossEpic() {
        let move = BacklogLogic.move(2, to: 2, in: order, epic: 7)
        #expect(move == RankMove(issue: 2, place: .before(3), epic: .some(7)))
        #expect(BacklogLogic.applying(move!, to: order).first { $0.id == 2 }?.epicID == 7)
    }

    @Test("the shown order follows the move until the server answers")
    func applying() {
        let moved = BacklogLogic.applying(RankMove(issue: 1, place: .after(3), epic: nil), to: order)
        #expect(moved.map(\.id) == [2, 3, 1, 4])
    }

    @Test("the server's order agreeing with the drop is no conflict")
    func noConflict() {
        let server = [issue(2, rank: 1), issue(3, rank: 2), issue(1, rank: 2.5), issue(4, rank: 3)]
        #expect(!BacklogLogic.conflicts(RankMove(issue: 1, place: .after(3), epic: nil), server: server))
        #expect(!BacklogLogic.conflicts(RankMove(issue: 1, place: .before(4), epic: nil), server: server))
    }

    @Test("someone moving the anchor meanwhile is a conflict: the server's order wins")
    func conflict() {
        let server = [issue(2, rank: 1), issue(1, rank: 2.5), issue(4, rank: 3), issue(3, rank: 4)]
        #expect(BacklogLogic.conflicts(RankMove(issue: 1, place: .after(3), epic: nil), server: server))
        #expect(BacklogLogic.conflicts(RankMove(issue: 9, place: .top, epic: nil), server: server))
    }

    @Test("undo puts the row back before its old neighbour, in its old epic")
    func undo() {
        #expect(BacklogLogic.undo(of: 2, before: order) == RankMove(issue: 2, place: .before(3), epic: .some(nil)))
        #expect(BacklogLogic.undo(of: 4, before: order) == RankMove(issue: 4, place: .after(3), epic: .some(nil)))
    }

    @Test("filters: type, epic, assignee, requirement, unestimated and search")
    func filters() {
        let items = [
            issue(1, rank: 1, epic: 5, requirement: 12, owner: .agent(3), kind: "bug"),
            issue(2, rank: 2, points: nil), issue(3, rank: 3, requirement: 8),
        ]
        #expect(BacklogFilter(kind: "bug").apply(items).map(\.id) == [1])
        #expect(BacklogFilter(epic: .none).apply(items).map(\.id) == [2, 3])
        #expect(BacklogFilter(assignee: .agent(3)).apply(items).map(\.id) == [1])
        #expect(BacklogFilter(requirement: .some(8)).apply(items).map(\.id) == [3])
        #expect(BacklogFilter(requirement: .none).apply(items).map(\.id) == [2])
        #expect(BacklogFilter(unestimated: true).apply(items).map(\.id) == [2])
        #expect(BacklogFilter(text: "cit-3").apply(items).map(\.id) == [3])
    }
}

@Suite("Board rules")
struct BoardRulesTests {
    let kanban = BoardLogic.columns(mode: .kanban, limits: ["in_progress": 2])

    private var inProgress: ServerColumn { kanban[1] }

    @Test("a drop into a column at its WIP limit is refused, naming the column and the card")
    func full() {
        let issues = [issue(1, rank: 1, state: "in_progress"), issue(2, rank: 2, state: "in_progress")]
        let refusal = BoardLogic.wipRefusal(moving: issue(3, rank: 3, state: "todo"), into: inProgress, of: issues)
        #expect(refusal?.fullColumn == "In progress")
        #expect(refusal?.message.contains("(2 / 2)") == true)
        #expect(refusal?.message.contains("CIT-3") == true)
    }

    @Test("room left, no limit, or a card already in the column: no refusal")
    func notFull() {
        let one = [issue(1, rank: 1, state: "in_progress")]
        #expect(BoardLogic.wipRefusal(moving: issue(3, rank: 3, state: "todo"), into: inProgress, of: one) == nil)
        let two = one + [issue(2, rank: 2, state: "in_progress")]
        #expect(BoardLogic.wipRefusal(moving: two[0], into: inProgress, of: two) == nil)
        #expect(BoardLogic.wipRefusal(moving: issue(3, rank: 3), into: kanban[0], of: two) == nil)
    }

    @Test("columns carry their limits; Kanban and Scrum titles differ")
    func columns() {
        #expect(inProgress.limit == 2)
        #expect(kanban.map(\.title) == ["Ready", "In progress", "Review", "Done · this week"])
        #expect(BoardLogic.columns(mode: .scrum, limits: [:])[2].title == "In review · QA")
    }

    @Test("each drag maps to its machine step; review needs the QA agent")
    func steps() {
        let me = ServerActor.human(1)
        let qa = ServerActor.agent(6)
        #expect(BoardLogic.step(for: issue(1, rank: 0), to: "todo", reviewer: qa, me: me) == .success(.ready))
        #expect(
            BoardLogic.step(for: issue(1, rank: 0, state: "todo"), to: "in_progress", reviewer: qa, me: me)
                == .success(.start))
        #expect(
            BoardLogic.step(for: issue(1, rank: 0, state: "in_progress"), to: "in_review", reviewer: qa, me: me)
                == .success(.submitForReview(reviewer: qa)))
        #expect(
            BoardLogic.step(for: issue(1, rank: 0, state: "in_review"), to: "done", reviewer: qa, me: me)
                == .success(.approve))
        #expect(
            BoardLogic.step(
                for: issue(1, rank: 0, state: "in_review", owner: .agent(3)), to: "in_progress", reviewer: qa, me: me)
                == .success(.requestChanges(assignee: .agent(3))))
        #expect(
            BoardLogic.step(for: issue(1, rank: 0, state: "done"), to: "todo", reviewer: qa, me: me)
                == .success(.reopen(next: me)))
    }

    @Test("a move with no machine step, or review with no QA agent, is refused here")
    func refusals() {
        let me = ServerActor.human(1)
        guard
            case .failure = BoardLogic.step(
                for: issue(1, rank: 0, state: "in_progress"), to: "todo", reviewer: nil, me: me)
        else {
            Issue.record("in progress → to do has no step")
            return
        }
        guard
            case .failure(let noQA) = BoardLogic.step(
                for: issue(1, rank: 0, state: "in_progress"), to: "in_review", reviewer: nil, me: me)
        else {
            Issue.record("review without a QA agent must refuse")
            return
        }
        #expect(noQA.message.contains("QA"))
    }
}

@Suite("Sprint gate")
struct SprintGateTests {
    let planned = ServerSprint(id: 6, name: "S5", goal: "", state: "planned")
    let active = ServerSprint(id: 5, name: "S4", goal: "", state: "active")

    private func approval(
        _ id: Int64, _ status: String, sprint: Int64 = 6, kind: String = "sprint_commit", reply: String? = nil
    )
        -> ServerApproval
    {
        ServerApproval(id: id, kind: kind, status: status, sprintID: sprint, issueID: nil, requestedBy: 1, reply: reply)
    }

    @Test("no planned sprint: nothing to gate")
    func none() {
        #expect(SprintGate.state(sprints: [active], approvals: []) == .none)
    }

    @Test("planned with no commit is a draft, editable")
    func draft() {
        let gate = SprintGate.state(sprints: [active, planned], approvals: [approval(1, "pending", kind: "pr_merge")])
        #expect(gate == .draft(planned))
        #expect(!gate.isLocked)
    }

    @Test("a pending sprint_commit for the planned sprint locks the plan behind the gate bar")
    func awaiting() {
        let pending = approval(2, "pending")
        let gate = SprintGate.state(sprints: [planned], approvals: [approval(1, "rejected"), pending])
        #expect(gate == .awaitingApproval(planned, approval: pending))
        #expect(gate.isLocked)
    }

    @Test("the newest decision wins: a rejection carries its reason, an approval elsewhere is ignored")
    func rejected() {
        let gate = SprintGate.state(
            sprints: [planned],
            approvals: [approval(3, "rejected", reply: "too big"), approval(4, "approved", sprint: 99)])
        #expect(gate == .rejected(planned, reason: "too big"))
    }

    @Test("capacity per assignee, heaviest first, full at its share")
    func loads() {
        let issues = [
            issue(1, rank: 0, points: 8, owner: .agent(3)), issue(2, rank: 0, points: 3, owner: .agent(3)),
            issue(3, rank: 0, points: 5, owner: .agent(4)), issue(4, rank: 0, points: 2),
        ]
        let loads = SprintLogic.loads(issues, capacity: 20)
        #expect(loads.map(\.actor) == [.agent(3), .agent(4)])
        #expect(loads[0].points == 11 && loads[0].capacity == 10 && loads[0].isFull)
        #expect(!loads[1].isFull)
        #expect(
            SprintLogic.velocityMark([
                .init(sprintID: 1, committed: 30, completed: 27), .init(sprintID: 2, committed: 30, completed: 30),
                .init(sprintID: 3, committed: 30, completed: 33), .init(sprintID: 4, committed: 1, completed: 1),
            ]) == 30)
    }
}

@Suite("Requirement grouping")
struct RequirementGroupingTests {
    let requirements = [
        ServerRequirement(id: 12, key: "R-12", title: "Trust", state: "in_progress"),
        ServerRequirement(id: 8, key: "R-8", title: "Replay", state: "in_progress"),
    ]

    @Test("groups follow the requirement number; items with none come last")
    func order() {
        let groups = RequirementGrouping.groups(
            [
                issue(1, rank: 0), issue(2, rank: 0, requirement: 12), issue(3, rank: 0, requirement: 8),
                issue(4, rank: 0, requirement: 12),
            ],
            requirements: requirements)
        #expect(groups.map(\.requirement?.key) == ["R-8", "R-12", nil])
        #expect(groups[1].items.map(\.id) == [2, 4])
    }

    @Test("a requirement this client has not read yet still groups, after the known ones")
    func unknown() {
        let groups = RequirementGrouping.groups(
            [issue(1, rank: 0, requirement: 99), issue(2, rank: 0, requirement: 8)], requirements: requirements)
        #expect(groups.map(\.requirement?.id) == [8, 99])
    }

    @Test("server mode offers List next to Backlog, and no Sprint tab for Kanban")
    func surfaces() {
        let scrum = SurfaceVisibility.offeredOnServer(kanban: false)
        #expect(
            scrum.contains(.list) && scrum.contains(.backlog) && scrum.contains(.sprint) && scrum.contains(.reports))
        #expect(!SurfaceVisibility.offeredOnServer(kanban: true).contains(.sprint))
        #expect(!SurfaceVisibility.offered(hasProject: true).contains(.backlog))
    }
}
