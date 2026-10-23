import Foundation
import QuestCitadelAPI

typealias Schemas = Components.Schemas

/// An open enum on the wire (`anyOf: [enum, string]`): a known case, or a newer server's word.
protocol OpenWord {
    associatedtype Known: RawRepresentable where Known.RawValue == String
    var value1: Known? { get }
    var value2: String? { get }
}

extension OpenWord {
    var word: String { value1?.rawValue ?? value2 ?? "" }
}

extension Schemas.IssueState: OpenWord {}
extension Schemas.IssueKind: OpenWord {}
extension Schemas.SprintState: OpenWord {}
extension Schemas.ProjectMode: OpenWord {}
extension Schemas.SprintApproval: OpenWord {}
extension Schemas.ApprovalKind: OpenWord {}
extension Schemas.ApprovalStatus: OpenWord {}
extension Schemas.EpicStatus: OpenWord {}
extension Schemas.RequirementState: OpenWord {}
extension Schemas.FigureState: OpenWord {}
extension Schemas.Harness: OpenWord {}
extension Schemas.AgentStatus: OpenWord {}
extension Schemas.RunState: OpenWord {}
extension Schemas.CompanyKind: OpenWord {}
extension Schemas.TeamRole: OpenWord {}

/// Who acts on an issue: an agent, the person, or nobody yet.
enum ServerActor: Equatable, Hashable, Sendable {
    case agent(Int64)
    case human(Int64)
    case timer
    case none

    var agentID: Int64? {
        if case .agent(let id) = self { return id }
        return nil
    }
}

/// A Citadel project as Quest's sidebar and tabs read it.
struct ServerProject: Identifiable, Equatable, Sendable {
    enum Mode: String, Sendable { case scrum, kanban }
    let id: Int64
    let companyID: Int64
    var name: String
    var key: String
    var mode: Mode
    /// `owner`: the person approves a sprint commit; `product_owner`: the PO commits alone.
    var ownerApprovesSprints: Bool
}

/// One Citadel issue — Quest's work item in server mode.
struct ServerIssue: Identifiable, Equatable, Hashable, Sendable {
    let id: Int64
    var key: String
    var projectID: Int64
    var kind: String
    var title: String
    var body: String
    /// `backlog`, `todo`, `in_progress`, `in_review`, `blocked`, `done`, `cancelled` — or a newer word.
    var state: String
    var rank: Double
    var points: Int?
    var epicID: Int64?
    var sprintID: Int64?
    var requirementID: Int64?
    var owner: ServerActor
    var next: ServerActor
    /// The run holding the issue right now.
    var runID: Int64?
    var labels: [ServerLabel] = []

    var isOpen: Bool { !["done", "cancelled"].contains(state) }
}

struct ServerEpic: Identifiable, Equatable, Sendable {
    let id: Int64
    /// `CIT-E10`.
    var key = ""
    var title: String
    var status: String
}

struct ServerSprint: Identifiable, Equatable, Sendable {
    let id: Int64
    var name: String
    var goal: String
    /// `planned`, `active`, `closed`.
    var state: String
    var startsOn: Date?
    var endsOn: Date?
}

struct ServerAgent: Identifiable, Equatable, Sendable {
    let id: Int64
    var name: String
    var role: String
    var figure: String
    var palette: String
    var harness: String
    var status: String
}

struct ServerApproval: Identifiable, Equatable, Sendable {
    let id: Int64
    var kind: String
    var status: String
    var sprintID: Int64?
    var issueID: Int64?
    var requestedBy: Int64
    var reply: String?
}

struct ServerRequirement: Identifiable, Equatable, Sendable {
    let id: Int64
    var key: String
    var title: String
    var state: String
}

/// A run on an issue, for the card's "Kestrel working · 4m" line.
struct ServerRun: Identifiable, Equatable, Sendable {
    let id: Int64
    var agentID: Int64
    var issueID: Int64?
    var state: String
    var startedAt: Date?
}

struct SprintPoints: Equatable, Sendable {
    var sprintID: Int64
    var committed: Int
    var completed: Int
}

struct SprintReportInfo: Equatable, Sendable {
    var sprintID: Int64
    var committed: Int?
    var completed: Int
    var capacity: Int?
    /// Points left at the end of each day, oldest first.
    var burndown: [(day: Date, left: Int)]

    static func == (a: SprintReportInfo, b: SprintReportInfo) -> Bool {
        a.sprintID == b.sprintID && a.committed == b.committed && a.completed == b.completed
            && a.capacity == b.capacity && a.burndown.map(\.left) == b.burndown.map(\.left)
            && a.burndown.map(\.day) == b.burndown.map(\.day)
    }
}

// MARK: - Mapping from the wire

enum ServerDay {
    /// Whole days from `start` to `end`, counted in UTC as the server writes days.
    static func days(from start: Date, to end: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end))
            .day ?? 0
    }

    /// `YYYY-MM-DD` as the server writes a sprint or burndown day, read in UTC.
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        return try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash))
    }
}

extension ServerActor {
    init(_ actor: Schemas.Actor?) {
        switch actor {
        case .agent(let agent): self = .agent(agent.agentId)
        case .human(let human): self = .human(human.userId)
        case nil: self = .none
        }
    }

    init(_ next: Schemas.NextActor?) {
        switch next {
        case .agent(let agent): self = .agent(agent.agentId)
        case .human(let human): self = .human(human.userId)
        case .timer: self = .timer
        case nil: self = .none
        }
    }
}

extension ServerProject {
    init(_ project: Schemas.Project) {
        self.init(
            id: project.id, companyID: project.companyId, name: project.name, key: project.key,
            mode: project.mode.word == "kanban" ? .kanban : .scrum,
            ownerApprovesSprints: project.sprintApproval.word != "product_owner")
    }
}

extension ServerIssue {
    init(_ issue: Schemas.Issue) {
        self.init(
            id: issue.id, key: issue.key, projectID: issue.projectId, kind: issue.kind.word, title: issue.title,
            body: issue.body, state: issue.state.word, rank: issue.rank, points: issue.points.map(Int.init),
            epicID: issue.epicId, sprintID: issue.sprintId, requirementID: issue.requirementId,
            owner: ServerActor(issue.owner), next: ServerActor(issue.nextActor), runID: issue.checkoutRunId,
            labels: issue.labels.map(ServerLabel.init))
    }
}

extension ServerEpic {
    init(_ epic: Schemas.Epic) { self.init(id: epic.id, key: epic.key, title: epic.title, status: epic.status.word) }
}

extension ServerSprint {
    init(_ sprint: Schemas.Sprint) {
        self.init(
            id: sprint.id, name: sprint.name, goal: sprint.goal, state: sprint.state.word,
            startsOn: ServerDay.parse(sprint.startsOn), endsOn: ServerDay.parse(sprint.endsOn))
    }
}

extension ServerAgent {
    init(_ agent: Schemas.Agent) {
        self.init(
            id: agent.id, name: agent.name, role: agent.role, figure: agent.figureState.word,
            palette: agent.appearance.paletteId, harness: agent.harness.word, status: agent.status.word)
    }
}

extension ServerApproval {
    init(_ approval: Schemas.Approval) {
        self.init(
            id: approval.id, kind: approval.kind.word, status: approval.status.word, sprintID: approval.sprintId,
            issueID: approval.issueId, requestedBy: approval.requestedBy, reply: approval.reply)
    }
}

extension ServerRequirement {
    init(_ requirement: Schemas.Requirement) {
        self.init(
            id: requirement.id, key: requirement.key, title: requirement.title, state: requirement.state.word)
    }
}

extension ServerRun {
    init(_ run: Schemas.Run) {
        self.init(
            id: run.id, agentID: run.agentId, issueID: run.issueId, state: run.state.word,
            startedAt: run.startedAt)
    }
}

extension SprintReportInfo {
    init(_ report: Schemas.SprintReport) {
        self.init(
            sprintID: report.sprintId, committed: report.committed.map(Int.init), completed: Int(report.completed),
            capacity: report.capacity.map(Int.init),
            burndown: report.burndown.compactMap { day in ServerDay.parse(day.day).map { ($0, Int(day.left)) } })
    }
}
