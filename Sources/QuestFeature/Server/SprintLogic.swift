import Foundation

/// Where a Scrum project's next sprint stands (decision #33): one server approval behind Quest's gate bar and
/// Citadel's inbox, so approving in either clears both.
enum SprintGate: Equatable, Sendable {
    /// No planned sprint: the PO has not drafted one.
    case none
    /// Planned, not yet committed: editable.
    case draft(ServerSprint)
    /// Committed under the owner policy: edits paused until the person decides.
    case awaitingApproval(ServerSprint, approval: ServerApproval)
    /// The last commit was rejected; the PO and Lead re-plan.
    case rejected(ServerSprint, reason: String?)

    var sprint: ServerSprint? {
        switch self {
        case .none: nil
        case .draft(let sprint), .awaitingApproval(let sprint, _), .rejected(let sprint, _): sprint
        }
    }

    /// Plan edits (drag in / out) are paused while the commit waits on the person.
    var isLocked: Bool {
        if case .awaitingApproval = self { return true }
        return false
    }

    /// The planned sprint (the newest) and its `sprint_commit` approvals decide the gate.
    static func state(sprints: [ServerSprint], approvals: [ServerApproval]) -> SprintGate {
        guard let planned = sprints.filter({ $0.state == "planned" }).max(by: { $0.id < $1.id }) else { return .none }
        let commits = approvals.filter { $0.kind == "sprint_commit" && $0.sprintID == planned.id }
            .sorted { $0.id < $1.id }
        if let pending = commits.last(where: { $0.status == "pending" }) {
            return .awaitingApproval(planned, approval: pending)
        }
        if let last = commits.last, last.status == "rejected" { return .rejected(planned, reason: last.reply) }
        return .draft(planned)
    }
}

/// Points per assignee against what they can carry (sprint planning's right column).
struct AssigneeLoad: Identifiable, Equatable, Sendable {
    var actor: ServerActor
    var points: Int
    var capacity: Int

    var id: ServerActor { actor }
    var isFull: Bool { capacity > 0 && points >= capacity }
}

enum SprintLogic {
    static func active(_ sprints: [ServerSprint]) -> ServerSprint? {
        sprints.filter { $0.state == "active" }.max { $0.id < $1.id }
    }

    static func points(_ issues: [ServerIssue]) -> Int { issues.reduce(0) { $0 + ($1.points ?? 0) } }

    /// The mean completed points of the last three closed sprints: the velocity mark.
    static func velocityMark(_ history: [SprintPoints]) -> Double? {
        let last = history.prefix(3)
        guard !last.isEmpty else { return nil }
        return Double(last.reduce(0) { $0 + $1.completed }) / Double(last.count)
    }

    /// Points per owner in the sprint, heaviest first. The server keeps no per-person capacity yet, so each
    /// assignee's capacity is the sprint capacity shared evenly (`nil` capacity: no bar limit).
    static func loads(_ sprintIssues: [ServerIssue], capacity: Int?) -> [AssigneeLoad] {
        var byOwner: [ServerActor: Int] = [:]
        for issue in sprintIssues where issue.owner != .none { byOwner[issue.owner, default: 0] += issue.points ?? 0 }
        let share = capacity.map { byOwner.isEmpty ? 0 : Int((Double($0) / Double(byOwner.count)).rounded(.up)) } ?? 0
        return byOwner.map { AssigneeLoad(actor: $0.key, points: $0.value, capacity: share) }
            .sorted { ($0.points, $1.actor.sortKey) > ($1.points, $0.actor.sortKey) }
    }

    /// The ideal line: from the first day's points to zero on the last day.
    static func ideal(start: Date, end: Date, from points: Int) -> [(day: Date, left: Double)] {
        [(start, Double(points)), (end, 0)]
    }

    /// "on track" / "behind by N pts": the actual left today against the ideal line at today.
    static func pace(burndown: [(day: Date, left: Int)], start: Date?, end: Date?) -> String? {
        guard let start, let end, end > start, let first = burndown.first, let last = burndown.last else { return nil }
        let span = end.timeIntervalSince(start)
        let elapsed = min(max(0, last.day.timeIntervalSince(start)), span)
        let ideal = Double(first.left) * (1 - elapsed / span)
        let behind = Int((Double(last.left) - ideal).rounded())
        return behind > 0 ? "behind by \(behind) pts" : "on track"
    }
}

extension ServerActor {
    fileprivate var sortKey: Int64 {
        switch self {
        case .agent(let id): id
        case .human(let id): -id
        case .timer, .none: Int64.min
        }
    }
}

/// "Group by requirement" (decision #49): the requirement each item serves, so one ask can be followed across
/// the board. Items outside any requirement group last.
struct RequirementGroup: Identifiable, Equatable, Sendable {
    var requirement: ServerRequirement?
    var items: [ServerIssue]
    var id: Int64 { requirement?.id ?? -1 }
}

enum RequirementGrouping {
    static func groups(_ issues: [ServerIssue], requirements: [ServerRequirement]) -> [RequirementGroup] {
        var order: [Int64?] = []
        var items: [Int64?: [ServerIssue]] = [:]
        for issue in issues {
            if items[issue.requirementID] == nil { order.append(issue.requirementID) }
            items[issue.requirementID, default: []].append(issue)
        }
        let number: (Int64?) -> Int = { id in
            guard let id, let key = requirements.first(where: { $0.id == id })?.key else { return Int.max - 1 }
            return Int(key.split(separator: "-").last ?? "") ?? Int.max - 1
        }
        order.sort { a, b in
            if (a == nil) != (b == nil) { return b == nil }
            return (number(a), a ?? 0) < (number(b), b ?? 0)
        }
        return order.map { id in
            RequirementGroup(
                requirement: id.flatMap { id in requirements.first { $0.id == id } }
                    ?? id.map { ServerRequirement(id: $0, key: "R-?", title: "Requirement \($0)", state: "") },
                items: items[id] ?? [])
        }
    }
}
