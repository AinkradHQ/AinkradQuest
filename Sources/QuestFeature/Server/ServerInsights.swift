import Foundation
import QuestCitadelAPI

/// A project's label, put on its issues.
struct ServerLabel: Identifiable, Equatable, Hashable, Sendable {
    let id: Int64
    var name: String
}

/// The project's team and what each member takes on per sprint (`getTeamCapacity`).
struct TeamCapacityInfo: Equatable, Sendable {
    struct Member: Identifiable, Equatable, Sendable {
        var agentID: Int64
        var capacity: Int?
        /// `product_owner`, `team_lead`, `member`.
        var role: String
        var id: Int64 { agentID }
    }

    var members: [Member] = []
    /// What a sprint commit is checked against; `nil` when no member has a capacity.
    var total: Int?

    func capacity(of actor: ServerActor) -> Int? {
        actor.agentID.flatMap { id in members.first { $0.agentID == id }?.capacity }
    }
}

/// Cycle, lead and throughput over the server's flow window (`getProjectFlow`).
struct FlowInfo: Equatable, Sendable {
    struct Times: Equatable, Sendable {
        var issueID: Int64
        var cycle: Int64?
        var lead: Int64
    }

    var since: Date
    var until: Date
    var throughput: Int
    var meanCycle: Double?
    var meanLead: Double?
    /// Each done issue, in the order it was done.
    var issues: [Times]

    var days: Int { max(1, Int((until.timeIntervalSince(since) / 86_400).rounded())) }
    var perWeek: Double { Double(throughput) * 7 / Double(days) }

    /// The 85th-percentile cycle time, nearest rank: the line on the scatter and the Kanban "past p85" mark.
    var p85Cycle: Double? { Self.percentile(issues.compactMap(\.cycle).map(Double.init), 0.85) }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// One issue's flow (`getIssueFlow`): its item detail line.
struct IssueFlowInfo: Equatable, Sendable {
    var cycle: Int64?
    var lead: Int64?
    var age: Int64?
}

/// A closed sprint's review and the retro proposals made from it (`getSprintReview`).
struct SprintReviewInfo: Equatable, Sendable {
    /// What the server stored when the sprint closed (`review_in`); `nil` before.
    struct Summary: Decodable, Equatable, Sendable {
        struct Carried: Decodable, Equatable, Sendable {
            var key: String
            var title: String
            var points: Int?
        }
        struct Counted: Decodable, Equatable, Sendable {
            var key: String
            var times: Int
        }
        struct Velocity: Decodable, Equatable, Sendable {
            var previousMean: Double?
            var delta: Double?
        }
        var committed: Int
        var completed: Int
        var carried: [Carried] = []
        var velocity: Velocity?
        var blocked: [Counted] = []
        var escalated: [Counted] = []
    }

    struct Retro: Identifiable, Equatable, Sendable {
        let id: Int64
        /// `decision`, `landmine` or `retro`.
        var kind: String
        var title: String
        var body: String
        /// `proposed`, `accepted` or `rejected`.
        var status: String
        var proposedBy: Int64?
        var reason: String?
    }

    var sprintID: Int64
    var summary: Summary?
    var retro: [Retro]

    var waiting: Int { retro.filter { $0.status == "proposed" }.count }
}

enum FlowFormat {
    /// `2.4d`, `5h`, `40m` — the Kanban header and the scatter's tooltips.
    static func duration(_ seconds: Double) -> String {
        if seconds >= 86_400 { return String(format: "%.1fd", seconds / 86_400) }
        if seconds >= 3_600 { return "\(Int((seconds / 3_600).rounded()))h" }
        return "\(max(1, Int((seconds / 60).rounded())))m"
    }
}

// MARK: - Mapping from the wire

extension ServerLabel {
    init(_ label: Schemas.Label) { self.init(id: label.id, name: label.name) }
}

extension TeamCapacityInfo {
    init(_ team: Schemas.TeamCapacity) {
        self.init(
            members: team.members.map {
                Member(agentID: $0.agentId, capacity: $0.capacity.map(Int.init), role: $0.teamRole.word)
            },
            total: team.total.map(Int.init))
    }
}

extension FlowInfo {
    init(_ flow: Schemas.ProjectFlow) {
        self.init(
            since: flow.since, until: flow.until, throughput: flow.throughput, meanCycle: flow.meanCycleSecs,
            meanLead: flow.meanLeadSecs,
            issues: flow.issues.map { Times(issueID: $0.issueId, cycle: $0.cycleSecs, lead: $0.leadSecs) })
    }
}

extension IssueFlowInfo {
    init(_ flow: Schemas.IssueFlow) { self.init(cycle: flow.cycleSecs, lead: flow.leadSecs, age: flow.ageSecs) }
}

extension SprintReviewInfo {
    init(_ review: Schemas.SprintReview) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.init(
            sprintID: review.sprintId,
            summary: review.review.flatMap { object in
                (try? JSONEncoder().encode(object)).flatMap { try? decoder.decode(Summary.self, from: $0) }
            },
            retro: review.retro.map {
                Retro(
                    id: $0.id, kind: $0.kind, title: $0.title, body: $0.body, status: $0.status,
                    proposedBy: $0.proposedBy, reason: $0.reason)
            })
    }
}
