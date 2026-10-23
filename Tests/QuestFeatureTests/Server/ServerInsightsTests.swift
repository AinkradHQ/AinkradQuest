import AinkradAppKit
import Foundation
import QuestCitadelAPI
import Testing

@testable import QuestFeature

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try EventFrame.decoder.decode(T.self, from: Data(json.utf8))
}

private func issue(_ id: Int64, owner: ServerActor = .none, points: Int? = 3, labels: [ServerLabel] = [])
    -> ServerIssue
{
    ServerIssue(
        id: id, key: "CIT-\(id)", projectID: 1, kind: "task", title: "Issue \(id)", body: "", state: "todo", rank: 0,
        points: points, epicID: nil, sprintID: 5, requirementID: nil, owner: owner, next: .none, runID: nil,
        labels: labels)
}

private final class Secrets: PluginSecretStore, @unchecked Sendable {
    func secret(forKey key: String) -> String? { nil }
    func setSecret(_ value: String?, forKey key: String) {}
}

@Suite("Server insights (API minor 9)")
struct ServerInsightsTests {
    @Test("an epic maps its key")
    func epicKey() throws {
        let epic = ServerEpic(
            try decode(
                Schemas.Epic.self,
                #"{"id": 10, "key": "CIT-E10", "number": 10, "project_id": 1, "title": "Client API", "status": "open"}"#
            ))
        #expect(epic.key == "CIT-E10" && epic.title == "Client API")
    }

    @Test("team capacity maps each member, and the sprint's loads use a member's own capacity")
    func capacity() throws {
        let team = TeamCapacityInfo(
            try decode(
                Schemas.TeamCapacity.self,
                """
                {"team_id": 1, "total": 19, "members": [{"agent_id": 3, "capacity": 11, "team_role": "member"},
                 {"agent_id": 4, "capacity": 8, "team_role": "member"}, {"agent_id": 1, "team_role": "product_owner"}]}
                """))
        #expect(team.total == 19)
        #expect(team.capacity(of: .agent(3)) == 11 && team.capacity(of: .agent(1)) == nil)
        #expect(team.members.last?.role == "product_owner")
        let loads = SprintLogic.loads(
            [
                issue(1, owner: .agent(3), points: 11), issue(2, owner: .agent(4), points: 5),
                issue(3, owner: .agent(9)),
            ],
            capacity: 19, team: team)
        #expect(loads.map(\.capacity) == [11, 8, 7])
        #expect(loads[0].isFull && !loads[1].isFull)
    }

    @Test("project flow: means, weekly throughput and the p85 cycle line")
    func flow() throws {
        let flow = FlowInfo(
            try decode(
                Schemas.ProjectFlow.self,
                """
                {"since": "2026-09-23T00:00:00.000Z", "until": "2026-10-23T00:00:00.000Z", "throughput": 12,
                 "mean_cycle_secs": 172800, "mean_lead_secs": 432000,
                 "issues": [{"issue_id": 1, "cycle_secs": 86400, "lead_secs": 172800},
                  {"issue_id": 2, "lead_secs": 90000}, {"issue_id": 3, "cycle_secs": 259200, "lead_secs": 400000}]}
                """))
        #expect(flow.days == 30)
        #expect(abs(flow.perWeek - 2.8) < 0.01)
        #expect(flow.p85Cycle == 259_200)
        #expect(flow.issues[1].cycle == nil)
        #expect(FlowInfo.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.85) == 9)
        #expect(FlowInfo.percentile([], 0.85) == nil)
        #expect(FlowFormat.duration(207_360) == "2.4d")
        #expect(FlowFormat.duration(18_000) == "5h")
        #expect(FlowFormat.duration(30) == "1m")
    }

    @Test("an issue's flow line names only the times it has")
    func issueFlow() throws {
        let open = IssueFlowInfo(
            try decode(
                Schemas.IssueFlow.self,
                #"{"created_at": "2026-10-20T00:00:00.000Z", "started_at": "2026-10-21T00:00:00.000Z", "age_secs": 86400}"#
            ))
        #expect(ServerItemDetail.flowLine(open) == "age 1.0d")
        #expect(
            ServerItemDetail.flowLine(IssueFlowInfo(cycle: 3_600, lead: 7_200, age: 7_200))
                == "cycle 1h · lead 2h · age 2h")
        #expect(ServerItemDetail.flowLine(nil) == nil)
    }

    @Test("a closed sprint's stored review and its retro proposals read from the free-form object")
    func review() throws {
        let review = SprintReviewInfo(
            try decode(
                Schemas.SprintReview.self,
                """
                {"sprint_id": 4, "state": "closed",
                 "review": {"committed": 33, "completed": 31, "carried_to": null,
                  "carried": [{"issue": 49, "key": "CIT-49", "title": "Runner lost", "points": 3, "state": "todo"}],
                  "velocity": {"previous_mean": 28.0, "delta": 3.0, "sprints": 3},
                  "blocked": [{"issue": 55, "key": "CIT-55", "times": 2}], "escalated": []},
                 "retro": [{"id": 7, "kind": "landmine", "title": "Never pass context in argv", "body": "E2BIG",
                  "status": "proposed", "proposed_by": 3},
                  {"id": 8, "kind": "decision", "title": "QA re-runs the suite", "body": "", "status": "accepted",
                  "reason": "agreed"}]}
                """))
        let summary = try #require(review.summary)
        #expect(summary.committed == 33 && summary.completed == 31)
        #expect(summary.carried.map(\.key) == ["CIT-49"])
        #expect(summary.velocity?.delta == 3)
        #expect(review.waiting == 1)
        #expect(review.retro.map(\.kind) == ["landmine", "decision"])
        #expect(ServerReportsSurface.delta(summary.velocity) == " · +3 vs avg")
        #expect(ServerReportsSurface.lines(summary) == ["Carried over: CIT-49 (Runner lost)", "Blocked: CIT-55 ×2"])
        let before = SprintReviewInfo(
            try decode(Schemas.SprintReview.self, #"{"sprint_id": 5, "state": "active", "retro": []}"#))
        #expect(before.summary == nil && before.waiting == 0)
    }

    @Test("the label filter: carries a label, or carries none")
    func labelFilter() {
        let api = ServerLabel(id: 1, name: "api")
        let items = [issue(1, labels: [api]), issue(2), issue(3, labels: [ServerLabel(id: 2, name: "macos")])]
        #expect(BacklogFilter(label: .some(1)).apply(items).map(\.id) == [1])
        #expect(BacklogFilter(label: .none).apply(items).map(\.id) == [2])
        #expect(BacklogFilter().apply(items).count == 3)
    }

    @Test("a project key is 1–10 capitals and digits, starting with a letter")
    func projectKey() {
        #expect(ServerNewProjectForm.isValidKey("CIT"))
        #expect(ServerNewProjectForm.isValidKey("A1"))
        #expect(!ServerNewProjectForm.isValidKey(""))
        #expect(!ServerNewProjectForm.isValidKey("1AB"))
        #expect(!ServerNewProjectForm.isValidKey("ABCDEFGHIJK"))
        #expect(!ServerNewProjectForm.isValidKey("AB-1"))
    }
}

@MainActor
@Suite("Server store (API minor 9)")
struct ServerStoreMinor9Tests {
    private func event(_ action: String, details: String, kind: String = "issue", entity: Int64 = 62) throws
        -> Schemas.Event
    {
        try EventFrame.decoder.decode(
            Schemas.Event.self,
            from: Data(
                """
                {"seq": 4, "at": "2026-10-23T10:00:00.000Z", "payload": {"type": "audit", "audit_seq": 9,
                 "action": "\(action)", "actor": {"kind": "user", "user_id": 1}, "details": \(details),
                 "entity_kind": "\(kind)", "entity_id": \(entity)}}
                """.utf8))
    }

    @Test("an issue event naming its project reloads only that project; one without reloads them all")
    func scopedReloads() throws {
        let store = QuestServerStore(documents: MemoryDocumentStore(), secrets: Secrets())
        store.received(try event("issue.in_review", details: #"{"project_id": 7}"#))
        #expect(store.pending == [.project(7)])
        let unscoped = QuestServerStore(documents: MemoryDocumentStore(), secrets: Secrets())
        unscoped.received(try event("issue.in_review", details: "{}"))
        #expect(unscoped.pending == [.projects])
    }

    @Test("label events name their project; project events re-read the list")
    func labelAndProjectEvents() throws {
        let store = QuestServerStore(documents: MemoryDocumentStore(), secrets: Secrets())
        store.received(try event("label.created", details: #"{"project": 3, "name": "api"}"#, kind: "label"))
        #expect(store.pending == [.project(3)])
        let created = QuestServerStore(documents: MemoryDocumentStore(), secrets: Secrets())
        created.received(try event("project.created", details: "{}", kind: "project", entity: 9))
        #expect(created.pending == [.projectList, .projects])
    }

    @Test("a refusal with an error id offers Copy error; one without does not")
    func copyError() {
        let store = QuestServerStore(documents: MemoryDocumentStore(), secrets: Secrets())
        store.refuse(
            "Couldn't commit S5", ServerAnswer(status: 409, code: "conflict", message: "over", errorID: "err_01J"))
        #expect(store.notice?.actionTitle == "Copy error")
        #expect(store.notice?.message == "Couldn't commit S5: over")
        store.refuse("Couldn't commit S5", ServerAnswer(status: 0, code: "unreachable", message: "x"))
        #expect(store.notice?.actionTitle == nil)
    }

    @Test("Raise limit… opens the project settings on the WIP limits")
    func raiseLimit() async {
        let store = QuestServerStore(documents: MemoryDocumentStore(), secrets: Secrets())
        let project = ServerProject(
            id: 2, companyID: 1, name: "Mac Client", key: "AMC", mode: .kanban, ownerApprovesSprints: true)
        await store.raiseLimit(project: project, column: BoardLogic.columns(mode: .kanban, limits: [:])[1])
        #expect(store.settingsSheet == .limits)
    }
}
