import Foundation

/// One column of a server board: the issue states it holds, and its WIP limit (Kanban).
struct ServerColumn: Identifiable, Equatable, Sendable {
    /// The state a card dropped here moves to.
    var state: String
    var title: String
    var states: [String]
    var limit: Int?

    var id: String { state }
}

/// Why a drop was refused before (or after) it reached the server.
struct BoardRefusal: Error, Equatable, Sendable {
    var message: String
    /// Set when the column is full: the toast offers "Raise limit…".
    var fullColumn: String?
}

/// A step of the issue state machine, as `POST /issues/{id}/transition` takes it.
enum BoardStep: Equatable, Sendable {
    case ready, start, done, approve
    case submitForReview(reviewer: ServerActor)
    case requestChanges(assignee: ServerActor)
    case reopen(next: ServerActor)
}

enum BoardLogic {
    /// Scrum (the active sprint) and Kanban columns. Blocked cards stay in To do with a red stroke; cancelled ones
    /// leave the board.
    static func columns(mode: ServerProject.Mode, limits: [String: Int]) -> [ServerColumn] {
        let todo = mode == .kanban ? "Ready" : "To do"
        let review = mode == .kanban ? "Review" : "In review · QA"
        let done = mode == .kanban ? "Done · this week" : "Done"
        return [
            ServerColumn(state: "todo", title: todo, states: ["backlog", "todo", "blocked"], limit: limits["todo"]),
            ServerColumn(state: "in_progress", title: "In progress", states: ["in_progress"], limit: limits["in_progress"]),
            ServerColumn(state: "in_review", title: review, states: ["in_review"], limit: limits["in_review"]),
            ServerColumn(state: "done", title: done, states: ["done"], limit: nil),
        ]
    }

    /// The cards of `column`, in rank order.
    static func cards(_ column: ServerColumn, of issues: [ServerIssue]) -> [ServerIssue] {
        BacklogLogic.ranked(issues.filter { column.states.contains($0.state) })
    }

    /// Refuses a drop into a column already at its WIP limit — the same rule the server enforces (409), checked
    /// here first so the card springs back at once. A card already in that state never counts against it.
    static func wipRefusal(moving issue: ServerIssue, into column: ServerColumn, of issues: [ServerIssue])
        -> BoardRefusal?
    {
        // Counted on the column's own state only, as the server counts it.
        guard let limit = column.limit, issue.state != column.state else { return nil }
        let count = issues.filter { $0.state == column.state }.count
        guard count >= limit else { return nil }
        return BoardRefusal(
            message: "\(column.title) is full (\(count) / \(limit)). Finish or move one out before starting \(issue.key).",
            fullColumn: column.title)
    }

    /// The machine step that moves `issue` to `target`. `reviewer` is the QA agent (decision #16), `me` the person.
    static func step(
        for issue: ServerIssue, to target: String, reviewer: ServerActor?, me: ServerActor
    ) -> Result<BoardStep, BoardRefusal> {
        let assignee = issue.owner == .none || issue.owner == .timer ? me : issue.owner
        switch (issue.state, target) {
        case ("backlog", "todo"): return .success(.ready)
        case ("backlog", "in_progress"), ("todo", "in_progress"): return .success(.start)
        case ("in_progress", "in_review"):
            guard let reviewer else {
                return .failure(BoardRefusal(message: "No QA agent to review \(issue.key) — hire one in Citadel."))
            }
            return .success(.submitForReview(reviewer: reviewer))
        case ("in_progress", "done"): return .success(.done)
        case ("in_review", "done"): return .success(.approve)
        case ("in_review", "in_progress"): return .success(.requestChanges(assignee: assignee))
        case ("done", "todo"), ("cancelled", "todo"): return .success(.reopen(next: assignee))
        default:
            return .failure(
                BoardRefusal(message: "Citadel has no step from \(title(issue.state)) to \(title(target)) for \(issue.key)."))
        }
    }

    static func title(_ state: String) -> String {
        switch state {
        case "backlog": "Backlog"
        case "todo": "To do"
        case "in_progress": "In progress"
        case "in_review": "In review"
        case "blocked": "Blocked"
        case "done": "Done"
        case "cancelled": "Cancelled"
        default: state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
