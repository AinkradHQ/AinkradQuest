import Foundation

/// One group of the backlog: an epic and its items in rank order, or "No epic" (`epic == nil`), which sits last.
struct BacklogGroup: Identifiable, Equatable, Sendable {
    var epic: ServerEpic?
    var items: [ServerIssue]
    /// The epic's progress across ALL its issues, not just the backlog's.
    var done: Int
    var total: Int

    var id: Int64 { epic?.id ?? -1 }
}

/// What the server is asked to do with a dragged row (`POST /issues/{id}/move`, then `/epic` when it changed group).
struct RankMove: Equatable, Sendable {
    enum Place: Equatable, Sendable {
        case top, bottom
        case before(Int64)
        case after(Int64)
    }
    var issue: Int64
    var place: Place
    /// Set when the drop landed in another epic's group: `.some(nil)` takes it out of its epic.
    var epic: Int64??
}

/// The backlog's pure rules: what it holds, its order, and how a drag becomes a server move.
enum BacklogLogic {
    /// Every open item not in a sprint, in rank order (lower first; id breaks a tie so the order is stable).
    static func backlog(_ issues: [ServerIssue]) -> [ServerIssue] {
        ranked(issues.filter { $0.isOpen && $0.sprintID == nil })
    }

    static func ranked(_ issues: [ServerIssue]) -> [ServerIssue] {
        issues.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
    }

    /// Groups `backlog` by epic. Epics keep the order of their highest-ranked item; "No epic" is last. `all` is
    /// every issue of the project, for the "N/M done" progress.
    static func groups(_ backlog: [ServerIssue], epics: [ServerEpic], all: [ServerIssue]) -> [BacklogGroup] {
        var order: [Int64?] = []
        var items: [Int64?: [ServerIssue]] = [:]
        for issue in backlog {
            if items[issue.epicID] == nil { order.append(issue.epicID) }
            items[issue.epicID, default: []].append(issue)
        }
        order.sort { a, b in a != nil && b == nil }
        return order.map { epicID in
            let members = all.filter { $0.epicID == epicID && $0.state != "cancelled" }
            return BacklogGroup(
                epic: epicID.flatMap { id in epics.first { $0.id == id } }
                    ?? epicID.map { ServerEpic(id: $0, title: "Epic \($0)", status: "open") },
                items: items[epicID] ?? [], done: members.filter { $0.state == "done" }.count,
                total: members.count)
        }
    }

    /// The move for dropping `issue` at `index` of `order` (the list as shown, the dragged row still in it), into
    /// the group of epic `epic` (`nil` = No epic). `nil` when nothing changes.
    static func move(
        _ issue: Int64, to index: Int, in order: [ServerIssue], epic targetEpic: Int64?
    ) -> RankMove? {
        guard let from = order.firstIndex(where: { $0.id == issue }) else { return nil }
        let currentEpic = order[from].epicID
        var rest = order
        rest.remove(at: from)
        let slot = min(max(0, index > from ? index - 1 : index), rest.count)
        let epicChange: Int64?? = targetEpic == currentEpic ? .none : .some(targetEpic)
        if slot == from, epicChange == nil { return nil }
        let place: RankMove.Place =
            if rest.isEmpty { .top } else if slot < rest.count { .before(rest[slot].id) } else {
                .after(rest[rest.count - 1].id)
            }
        return RankMove(issue: issue, place: place, epic: epicChange)
    }

    /// `order` with the move applied — what the list shows until the server answers.
    static func applying(_ move: RankMove, to order: [ServerIssue]) -> [ServerIssue] {
        guard let from = order.firstIndex(where: { $0.id == move.issue }) else { return order }
        var rest = order
        var moved = rest.remove(at: from)
        if case .some(let epic) = move.epic { moved.epicID = epic }
        let index: Int =
            switch move.place {
            case .top: 0
            case .bottom: rest.count
            case .before(let anchor): rest.firstIndex { $0.id == anchor } ?? rest.count
            case .after(let anchor): (rest.firstIndex { $0.id == anchor }).map { $0 + 1 } ?? rest.count
            }
        rest.insert(moved, at: index)
        return rest
    }

    /// True when the server's order after the move does not put the issue where this client put it: someone else
    /// moved it, or its anchor, meanwhile. The server's order wins; the person gets an Undo.
    static func conflicts(_ move: RankMove, server: [ServerIssue]) -> Bool {
        let ids = ranked(server).map(\.id)
        guard let at = ids.firstIndex(of: move.issue) else { return true }
        switch move.place {
        case .top: return at != 0
        case .bottom: return at != ids.count - 1
        case .before(let anchor): return at + 1 >= ids.count || ids[at + 1] != anchor
        case .after(let anchor): return at == 0 || ids[at - 1] != anchor
        }
    }

    /// The move that puts `issue` back where it was in `before` (Undo).
    static func undo(of issue: Int64, before: [ServerIssue]) -> RankMove? {
        let ids = before.map(\.id)
        guard let at = ids.firstIndex(of: issue) else { return nil }
        let original = before[at]
        let place: RankMove.Place = at + 1 < ids.count ? .before(ids[at + 1]) : at > 0 ? .after(ids[at - 1]) : .top
        return RankMove(issue: issue, place: place, epic: .some(original.epicID))
    }
}

/// The backlog's filters (type, epic, assignee, requirement, "Unestimated") and the header's search. `nil` is
/// "all"; `Filter.none` picks the items with no epic / no requirement.
struct BacklogFilter: Equatable, Sendable {
    enum Pick<T: Hashable & Sendable>: Hashable, Sendable {
        case all
        case none
        case some(T)

        func matches(_ value: T?) -> Bool {
            switch self {
            case .all: true
            case .none: value == nil
            case .some(let wanted): value == wanted
            }
        }
    }

    var kind: String?
    var epic: Pick<Int64> = .all
    var assignee: ServerActor?
    var requirement: Pick<Int64> = .all
    /// `.some(id)`: carries that label; `.none`: carries none.
    var label: Pick<Int64> = .all
    var unestimated = false
    var text = ""

    var isActive: Bool { self != BacklogFilter(text: text) }

    func apply(_ issues: [ServerIssue]) -> [ServerIssue] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        return issues.filter { issue in
            (kind == nil || issue.kind == kind) && epic.matches(issue.epicID)
                && (assignee == nil || issue.owner == assignee) && requirement.matches(issue.requirementID)
                && (!unestimated || issue.points == nil) && Self.labelMatches(label, issue.labels)
                && (query.isEmpty || issue.title.lowercased().contains(query) || issue.key.lowercased().contains(query))
        }
    }

    private static func labelMatches(_ pick: Pick<Int64>, _ labels: [ServerLabel]) -> Bool {
        switch pick {
        case .all: true
        case .none: labels.isEmpty
        case .some(let id): labels.contains { $0.id == id }
        }
    }
}
