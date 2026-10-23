import Foundation
import QuestCitadelAPI

/// What the server answered when it refused an action: its status, its stable code and its message.
struct ServerAnswer: Error, Equatable, Sendable {
    var status: Int
    var code: String
    var message: String
    /// `err_…`, unique to this answer: what "Copy error" copies, so the server's log line can be found.
    var errorID: String?

    static func unreachable(_ error: Error) -> ServerAnswer {
        ServerAnswer(status: 0, code: "unreachable", message: error.localizedDescription)
    }
}

/// One project's data as Quest's tabs read it, loaded in one go and reloaded when the event stream names it.
struct ProjectSnapshot: Equatable, Sendable {
    var issues: [ServerIssue] = []
    var epics: [ServerEpic] = []
    var sprints: [ServerSprint] = []
    /// WIP limits by issue state (Kanban).
    var limits: [String: Int] = [:]
    /// Closed sprints, newest first.
    var velocity: [SprintPoints] = []
    var velocityAverage: Double = 0
    /// The active and planned sprints' reports, by sprint id.
    var reports: [Int64: SprintReportInfo] = [:]
    var labels: [ServerLabel] = []
    var capacity = TeamCapacityInfo()
    var flow: FlowInfo?
    /// The last closed sprint's review and retro proposals.
    var review: SprintReviewInfo?
}

/// Quest's reads and writes on the Citadel API. Reads answer `nil` when they fail (logged); writes answer the
/// server's refusal, or `nil` when done.
extension CitadelServer {
    func read<T>(_ operation: String, _ work: () async throws -> T?) async -> T? {
        do {
            return try await work()
        } catch {
            Log.connection.error(
                "\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func projects(company: Int64) async -> [ServerProject]? {
        await read("listProjects") {
            guard case .ok(let ok) = try await client.listProjects(path: .init(id: company)) else { return nil }
            return try ok.body.json.map(ServerProject.init)
        }
    }

    func agents(company: Int64) async -> [ServerAgent]? {
        await read("listAgents") {
            guard case .ok(let ok) = try await client.listAgents(path: .init(id: company)) else { return nil }
            return try ok.body.json.map(ServerAgent.init)
        }
    }

    func approvals(company: Int64) async -> [ServerApproval]? {
        await read("listApprovals") {
            guard case .ok(let ok) = try await client.listApprovals(path: .init(id: company)) else { return nil }
            return try ok.body.json.map(ServerApproval.init)
        }
    }

    func requirements() async -> [ServerRequirement]? {
        await read("listRequirements") {
            guard case .ok(let ok) = try await client.listRequirements() else { return nil }
            return try ok.body.json.map(ServerRequirement.init)
        }
    }

    /// The company's runs that are live now: the cards' "working" lines.
    func liveRuns(company: Int64) async -> [ServerRun]? {
        await read("listCompanyRuns") {
            guard
                case .ok(let ok) = try await client.listCompanyRuns(path: .init(id: company), query: .init(live: true))
            else { return nil }
            return try ok.body.json.items.map(ServerRun.init)
        }
    }

    /// Everything one project's tabs show. `nil` when the issues could not be read; the rest degrade to empty.
    func snapshot(project: Int64) async -> ProjectSnapshot? {
        async let issues = read("listProjectIssues") { () async throws -> [ServerIssue]? in
            guard case .ok(let ok) = try await client.listProjectIssues(path: .init(id: project)) else { return nil }
            return try ok.body.json.map(ServerIssue.init)
        }
        async let epics = read("listEpics") { () async throws -> [ServerEpic]? in
            guard case .ok(let ok) = try await client.listEpics(path: .init(id: project)) else { return nil }
            return try ok.body.json.map(ServerEpic.init)
        }
        async let sprints = read("listSprints") { () async throws -> [ServerSprint]? in
            guard case .ok(let ok) = try await client.listSprints(path: .init(id: project)) else { return nil }
            return try ok.body.json.map(ServerSprint.init)
        }
        async let limits = read("listWipLimits") { () async throws -> [String: Int]? in
            guard case .ok(let ok) = try await client.listWipLimits(path: .init(id: project)) else { return nil }
            return Dictionary(
                try ok.body.json.compactMap { w in w.limit.map { (w.state.word, Int($0)) } }, uniquingKeysWith: { $1 })
        }
        async let velocity = read("getVelocity") { () async throws -> Schemas.Velocity? in
            guard case .ok(let ok) = try await client.getVelocity(path: .init(id: project), query: .init(limit: 6))
            else { return nil }
            return try ok.body.json
        }
        async let labels = read("listLabels") { () async throws -> [ServerLabel]? in
            guard case .ok(let ok) = try await client.listLabels(path: .init(id: project)) else { return nil }
            return try ok.body.json.map(ServerLabel.init)
        }
        async let capacity = read("getTeamCapacity") { () async throws -> TeamCapacityInfo? in
            guard case .ok(let ok) = try await client.getTeamCapacity(path: .init(id: project)) else { return nil }
            return TeamCapacityInfo(try ok.body.json)
        }
        async let flow = read("getProjectFlow") { () async throws -> FlowInfo? in
            guard case .ok(let ok) = try await client.getProjectFlow(path: .init(id: project)) else { return nil }
            return FlowInfo(try ok.body.json)
        }
        guard let issues = await issues else { return nil }
        var snapshot = ProjectSnapshot(issues: issues)
        snapshot.epics = await epics ?? []
        snapshot.sprints = await sprints ?? []
        snapshot.limits = await limits ?? [:]
        snapshot.labels = await labels ?? []
        snapshot.capacity = await capacity ?? TeamCapacityInfo()
        snapshot.flow = await flow
        if let velocity = await velocity {
            snapshot.velocityAverage = velocity.average
            snapshot.velocity = velocity.sprints.map {
                SprintPoints(sprintID: $0.sprintId, committed: Int($0.committed), completed: Int($0.completed))
            }
        }
        for sprint in snapshot.sprints where sprint.state != "closed" {
            if let report = await report(sprint: sprint.id) { snapshot.reports[sprint.id] = report }
        }
        if let closed = snapshot.sprints.filter({ $0.state == "closed" }).max(by: { $0.id < $1.id }) {
            snapshot.review = await review(sprint: closed.id)
        }
        return snapshot
    }

    func review(sprint: Int64) async -> SprintReviewInfo? {
        await read("getSprintReview") {
            guard case .ok(let ok) = try await client.getSprintReview(path: .init(id: sprint)) else { return nil }
            return SprintReviewInfo(try ok.body.json)
        }
    }

    func flow(issue: Int64) async -> IssueFlowInfo? {
        await read("getIssueFlow") {
            guard case .ok(let ok) = try await client.getIssueFlow(path: .init(id: issue)) else { return nil }
            return IssueFlowInfo(try ok.body.json)
        }
    }

    func report(sprint: Int64) async -> SprintReportInfo? {
        await read("getSprintReport") {
            guard case .ok(let ok) = try await client.getSprintReport(path: .init(id: sprint)) else { return nil }
            return SprintReportInfo(try ok.body.json)
        }
    }

    // MARK: - Writes

    /// Runs a write; `nil` = done, else the server's refusal in its own words.
    fileprivate func write(_ work: () async throws -> ServerAnswer?) async -> ServerAnswer? {
        do {
            return try await work()
        } catch {
            return .unreachable(error)
        }
    }

    func move(_ move: RankMove) async -> ServerAnswer? {
        let body: Schemas.MoveBody =
            switch move.place {
            case .top: .init(to: .init(value1: .top))
            case .bottom: .init(to: .init(value1: .bottom))
            case .before(let anchor): .init(anchorIssueId: anchor, to: .init(value1: .before))
            case .after(let anchor): .init(anchorIssueId: anchor, to: .init(value1: .after))
            }
        if let refused = await write({
            answer(try await client.moveIssue(path: .init(id: move.issue), body: .json(body)))
        }) {
            return refused
        }
        guard case .some(let epic) = move.epic else { return nil }
        return await write {
            answer(try await client.setIssueEpic(path: .init(id: move.issue), body: .json(.init(epicId: epic))))
        }
    }

    func transition(issue: Int64, _ step: BoardStep) async -> ServerAnswer? {
        let body: Schemas.Transition =
            switch step {
            case .ready: .ready(.init(kind: .ready))
            case .start: .start(.init(kind: .start))
            case .done: .done(.init(kind: .done))
            case .approve: .approve(.init(kind: .approve))
            case .submitForReview(let reviewer):
                .submitForReview(.init(kind: .submitForReview, reviewer: reviewer.wire))
            case .requestChanges(let assignee): .requestChanges(.init(assignee: assignee.wire, kind: .requestChanges))
            case .reopen(let next): .reopen(.init(kind: .reopen, next: next.wireNext))
            }
        return await write { answer(try await client.transitionIssue(path: .init(id: issue), body: .json(body))) }
    }

    /// Into the planned sprint (`sprint`), or back to the backlog (`nil`).
    func setSprint(issue: Int64, sprint: Int64?) async -> ServerAnswer? {
        await write {
            answer(try await client.setIssueSprint(path: .init(id: issue), body: .json(.init(sprintId: sprint))))
        }
    }

    func estimate(issue: Int64, points: Int?) async -> ServerAnswer? {
        await write {
            answer(
                try await client.estimateIssue(
                    path: .init(id: issue), body: .json(.init(points: points.map { Int32(clamping: $0) }))))
        }
    }

    func decide(approval: Int64, approve: Bool, reply: String?) async -> ServerAnswer? {
        await write {
            answer(
                try await client.decideApproval(
                    path: .init(id: approval), body: .json(.init(approve: approve, reply: reply))))
        }
    }

    /// Sets a column's WIP limit (`nil` removes it).
    func setLimit(project: Int64, state: String, limit: Int?) async -> ServerAnswer? {
        await write {
            answer(
                try await client.setWipLimit(
                    path: .init(id: project),
                    body: .json(
                        .init(
                            limit: limit.map { Int32(clamping: $0) },
                            state: .init(
                                value1: .init(rawValue: state),
                                value2: Schemas.IssueState.Value1Payload(rawValue: state) == nil ? state : nil)))))
        }
    }

    func createIssue(project: Int64, title: String, epic: Int64?) async -> ServerAnswer? {
        await write {
            answer(
                try await client.createIssue(path: .init(id: project), body: .json(.init(epicId: epic, title: title))))
        }
    }
}

extension CitadelServer {
    /// The owner's commit (decision #10): the sprint starts at once. Over the team's capacity it needs a reason.
    func commit(sprint: Int64, overrideReason: String?) async -> ServerAnswer? {
        await write {
            answer(
                try await client.commitSprint(
                    path: .init(id: sprint), body: .json(.init(overrideReason: overrideReason))))
        }
    }

    func createLabel(project: Int64, name: String) async -> ServerAnswer? {
        await write { answer(try await client.createLabel(path: .init(id: project), body: .json(.init(name: name)))) }
    }

    func renameLabel(project: Int64, label: Int64, name: String) async -> ServerAnswer? {
        await write {
            answer(
                try await client.renameLabel(path: .init(id: project, labelId: label), body: .json(.init(name: name))))
        }
    }

    func deleteLabel(project: Int64, label: Int64) async -> ServerAnswer? {
        await write { answer(try await client.deleteLabel(path: .init(id: project, labelId: label))) }
    }

    /// Puts the label on the issue, or takes it off.
    func setLabel(issue: Int64, label: Int64, on: Bool) async -> ServerAnswer? {
        await write {
            on
                ? answer(try await client.labelIssue(path: .init(id: issue, labelId: label)))
                : answer(try await client.unlabelIssue(path: .init(id: issue, labelId: label)))
        }
    }

    /// A member's points per sprint (`nil` clears it).
    func setCapacity(project: Int64, agent: Int64, capacity: Int?) async -> ServerAnswer? {
        await write {
            answer(
                try await client.setMemberCapacity(
                    path: .init(id: project, agentId: agent),
                    body: .json(.init(capacity: capacity.map { Int32(clamping: $0) }))))
        }
    }

    func createProject(company: Int64, name: String, key: String, kanban: Bool, ownerApproves: Bool) async
        -> ServerAnswer?
    {
        await write {
            answer(
                try await client.createProject(
                    path: .init(id: company),
                    body: .json(
                        .init(
                            key: key, mode: .init(value1: kanban ? .kanban : .scrum), name: name,
                            sprintApproval: .init(value1: ownerApproves ? .owner : .productOwner)))))
        }
    }

    /// The project's name, mode and sprint-approval policy.
    func updateProject(_ project: Int64, name: String, kanban: Bool, ownerApproves: Bool) async -> ServerAnswer? {
        await write {
            answer(
                try await client.updateProject(
                    path: .init(id: project),
                    body: .json(
                        .init(
                            mode: .init(value1: kanban ? .kanban : .scrum), name: name,
                            sprintApproval: .init(value1: ownerApproves ? .owner : .productOwner)))))
        }
    }
}

extension ServerActor {
    /// The wire `Actor`: a timer or nobody reads as the person (the admin, user 1) — the server never asks for one.
    var wire: Schemas.Actor {
        switch self {
        case .agent(let id): .agent(.init(agentId: id, kind: .agent))
        case .human(let id): .human(.init(kind: .human, userId: id))
        case .timer, .none: .human(.init(kind: .human, userId: 1))
        }
    }

    var wireNext: Schemas.NextActor {
        switch wire {
        case .agent(let agent): .agent(.init(agentId: agent.agentId, kind: .agent))
        case .human(let human): .human(.init(kind: .human, userId: human.userId))
        }
    }
}

/// Reads a write's output: `nil` when done, else the server's refusal (`ServerOutputs.swift`).
private func answer<Output: ServerOutput>(_ output: Output) -> ServerAnswer? { output.refusal }

/// Every write's output answers one question: did the server refuse, and why.
protocol ServerOutput { var refusal: ServerAnswer? { get } }
