import AinkradAppKit
import SwiftUI

/// Board (mockups 03 / 04): the active sprint's issues (Scrum) or every open issue (Kanban) in the project's
/// columns, with what each agent is doing now. Drags write to the server; a full column refuses (WIP) and the card
/// springs back. Cards can be grouped by epic or by the requirement they serve (decision #49).
struct ServerBoardSurface: View {
    let store: QuestServerStore
    let project: ServerProject
    let snapshot: ProjectSnapshot
    let search: String
    let openReports: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @State private var scope: Scope = .all
    @State private var byEpic = false
    @State private var byRequirement = false
    @State private var confirming: (issue: ServerIssue, column: ServerColumn)?
    @State private var open: ServerIssue?

    enum Scope: String, CaseIterable, Hashable {
        case all = "All", mine = "Mine", working = "Agents working"
    }

    private var sprint: ServerSprint? { SprintLogic.active(snapshot.sprints) }

    /// The board's issues: the active sprint's (Scrum) or all but the backlog's (Kanban), filtered.
    private var issues: [ServerIssue] {
        let base =
            project.mode == .kanban
            ? snapshot.issues.filter { $0.state != "cancelled" && !($0.state == "backlog" && $0.sprintID == nil) }
            : snapshot.issues.filter { $0.sprintID != nil && $0.sprintID == sprint?.id && $0.state != "cancelled" }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return base.filter { issue in
            switch scope {
            case .all: true
            case .mine: issue.owner == store.me || issue.next == store.me
            case .working: store.run(on: issue) != nil
            }
        }
        .filter { query.isEmpty || $0.title.lowercased().contains(query) || $0.key.lowercased().contains(query) }
    }

    var body: some View {
        let columns = BoardLogic.columns(mode: project.mode, limits: snapshot.limits)
        let issues = issues
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            HStack(alignment: .top, spacing: AinkradSpacing.md) {
                header
                Spacer(minLength: AinkradSpacing.md)
                if project.mode == .scrum {
                    BurndownTile(snapshot: snapshot, sprint: sprint).frame(width: skin.size.s360).onTapGesture(perform: openReports)
                } else {
                    KanbanStats().onTapGesture(perform: openReports)
                }
            }
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: AinkradSpacing.md) {
                    ForEach(columns) { column in columnView(column, issues: issues) }
                }
                .animation(AinkradMotion.present, value: issues.map { "\($0.id)\($0.state)" })
            }
        }
        .padding(.horizontal, AinkradSpacing.md)
        .ainkradModal(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let confirming { confirmForm(confirming.issue, confirming.column).id(confirming.issue.id) }
        }
        .ainkradModal(isPresented: Binding(get: { open != nil }, set: { if !$0 { open = nil } })) {
            if let open { ServerItemDetail(store: store, issue: open) { self.open = nil }.id(open.id) }
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            if project.mode == .kanban {
                HStack(spacing: AinkradSpacing.sm) {
                    Text(verbatim: project.name).questFont("t16", weight: "bold")
                    AinkradBadge(text: "Kanban")
                }
            } else if let sprint {
                Text(verbatim: "\(sprint.name)\(Self.day(sprint))").questFont("t16", weight: "bold")
                HStack(spacing: AinkradSpacing.sm) {
                    AinkradBadge(text: "Active", status: .success)
                    let all = snapshot.issues.filter { $0.sprintID == sprint.id }
                    Faint(
                        "\(SprintLogic.points(all.filter { $0.state == "done" })) of \(SprintLogic.points(all)) pts done"
                            + (sprint.goal.isEmpty ? "" : " · Goal: \(sprint.goal)"))
                }
            } else {
                Text("No active sprint").questFont("t16", weight: "bold")
                Faint("Plan one on the Sprint tab.")
            }
            HStack(spacing: AinkradSpacing.sm) {
                AinkradSegmentedPicker(items: Scope.allCases, selection: $scope) { $0.rawValue }.fixedSize()
                // Exclusive: turning one grouping on turns the other off.
                AinkradToggleButton(
                    isOn: Binding(
                        get: { byEpic },
                        set: {
                            byEpic = $0
                            if $0 { byRequirement = false }
                        }), title: "Group by epic"
                ).fixedSize()
                AinkradToggleButton(
                    isOn: Binding(
                        get: { byRequirement },
                        set: {
                            byRequirement = $0
                            if $0 { byEpic = false }
                        }), title: "Group by requirement"
                ).fixedSize()
            }
            .controlSize(.small)
        }
    }

    static func day(_ sprint: ServerSprint) -> String {
        guard let start = sprint.startsOn else { return "" }
        let day = ServerDay.days(from: start, to: Date()) + 1
        guard let end = sprint.endsOn else { return " · day \(day)" }
        let length = ServerDay.days(from: start, to: end) + 1
        return " · day \(min(day, length)) of \(length)"
    }

    private func columnView(_ column: ServerColumn, issues: [ServerIssue]) -> some View {
        let cards = BoardLogic.cards(column, of: issues)
        let count = snapshot.issues.filter { $0.state == column.state }.count
        let full = column.limit.map { count >= $0 } ?? false
        return ColumnPanel(column: column, count: cards.count, wipCount: count, isFull: full) {
            if byRequirement {
                ForEach(RequirementGrouping.groups(cards, requirements: store.requirements)) { group in
                    Faint(group.requirement.map { "\($0.key) · \($0.title)" } ?? "No requirement", size: "t10")
                    ForEach(group.items) { card($0, column: column) }
                }
            } else if byEpic {
                ForEach(BacklogLogic.groups(cards, epics: snapshot.epics, all: snapshot.issues)) { group in
                    Faint(group.epic?.title ?? "No epic", size: "t10")
                    ForEach(group.items) { card($0, column: column) }
                }
            } else {
                let shown = column.state == "done" ? Array(cards.prefix(5)) : cards
                ForEach(shown) { card($0, column: column) }
                if shown.count < cards.count { Faint("+\(cards.count - shown.count) more") }
            }
        } onDrop: { ids in
            guard let id = ids.first.flatMap(Int64.init), let issue = snapshot.issues.first(where: { $0.id == id })
            else { return false }
            if store.run(on: issue) != nil, !column.states.contains(issue.state) {
                confirming = (issue, column)
            } else {
                Task { await store.drop(issue, on: column, project: project) }
            }
            return true
        }
    }

    private func card(_ issue: ServerIssue, column: ServerColumn) -> some View {
        BoardCard(store: store, project: project, issue: issue) { open = issue }
            .draggable(String(issue.id)) {
                Text(verbatim: issue.title).questFont("t13").padding(AinkradSpacing.sm)
                    .rotationEffect(.degrees(-2))
            }
    }

    private func confirmForm(_ issue: ServerIssue, _ column: ServerColumn) -> some View {
        let who = store.run(on: issue).flatMap { store.agent($0.agentID)?.name } ?? "An agent"
        return VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(
                title: "\(who) is working on \(issue.key)",
                subtitle: "Moving it to \(column.title) takes it out of \(who)'s hands.")
            HStack {
                Spacer()
                AinkradButton(title: "Keep it", style: .ghost) { confirming = nil }
                AinkradButton(title: "Move it", style: .primary) {
                    confirming = nil
                    Task { await store.drop(issue, on: column, project: project) }
                }
            }
        }
        .frame(width: skin.size.s420)
    }
}
