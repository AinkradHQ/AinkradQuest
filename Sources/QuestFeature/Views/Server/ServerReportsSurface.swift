import AinkradAppKit
import SwiftUI

/// Reports (mockup 05): velocity and the active sprint's burndown (Scrum), cycle / lead time, the last sprint's
/// review and the retro's knowledge proposals. What Citadel does not report yet says so instead of inventing data.
struct ServerReportsSurface: View {
    let store: QuestServerStore
    let project: ServerProject
    let snapshot: ProjectSnapshot
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                if project.mode == .scrum {
                    HStack(alignment: .top, spacing: AinkradSpacing.md) {
                        tile("Velocity · last \(max(snapshot.velocity.count, 1)) sprints") { velocity }
                        tile("Burndown\(active.map { " · \($0.name)" } ?? "")") {
                            BurndownChart(report: active.flatMap { snapshot.reports[$0.id] }, sprint: active)
                        }
                    }
                    .frame(height: skin.size.s240)
                }
                tile("Cycle and lead time · 30 days") {
                    AinkradScatterChart(
                        title: "Cycle and lead time", series: [],
                        emptyMessage: "Citadel doesn't report cycle and lead time yet.")
                }
                .frame(height: skin.size.s180)
                HStack(alignment: .top, spacing: AinkradSpacing.md) {
                    tile("Sprint review\(lastClosed.map { " · \($0.name)" } ?? "")") { review }
                    tile("Retro → knowledge proposals") {
                        Faint("Citadel doesn't send retro proposals to clients yet.", size: "t13")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(minHeight: skin.size.s200)
            }
            .padding(.horizontal, AinkradSpacing.md)
            .padding(.bottom, AinkradSpacing.md)
        }
    }

    private var active: ServerSprint? { SprintLogic.active(snapshot.sprints) }
    private var lastClosed: ServerSprint? { snapshot.sprints.filter { $0.state == "closed" }.max { $0.id < $1.id } }

    private func tile<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            CapsLabel(text: title)
            content()
        }
        .padding(AinkradSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ainkradPanel()
    }

    /// Committed vs completed, oldest first, with the average line; the active sprint is drawn faded and the
    /// planned one as committed only.
    private var velocity: some View {
        let names = Dictionary(uniqueKeysWithValues: snapshot.sprints.map { ($0.id, $0.name) })
        var bars = snapshot.velocity.reversed().map { sprint in
            AinkradChartBar(
                label: names[sprint.sprintID] ?? "S?",
                segments: [
                    AinkradBarSegment(name: "Completed", value: Double(sprint.completed), tone: .accentSecondary),
                    AinkradBarSegment(
                        name: "Committed", value: Double(max(0, sprint.committed - sprint.completed)), tone: .muted),
                ])
        }
        for sprint in snapshot.sprints where sprint.state != "closed" {
            guard let report = snapshot.reports[sprint.id] else { continue }
            let committed = Double(report.committed ?? 0)
            let done = sprint.state == "active" ? Double(report.completed) : 0
            bars.append(
                AinkradChartBar(
                    label: sprint.state == "active" ? "\(sprint.name)*" : sprint.name,
                    segments: [
                        AinkradBarSegment(name: "Completed", value: done, tone: .accentPrimary),
                        AinkradBarSegment(name: "Committed", value: max(0, committed - done), tone: .muted),
                    ]))
        }
        return AinkradBarChart(
            title: "Velocity", bars: bars,
            threshold: snapshot.velocity.isEmpty
                ? nil : AinkradChartThreshold(value: snapshot.velocityAverage, label: "avg \(Int(snapshot.velocityAverage.rounded()))", tone: .accentSecondary),
            emptyMessage: "No sprints closed yet", format: { "\(Int($0)) pts" })
    }

    @ViewBuilder private var review: some View {
        if let sprint = lastClosed, let points = snapshot.velocity.first(where: { $0.sprintID == sprint.id }) {
            VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                Text(verbatim: "\(points.completed) of \(points.committed) pts done").questFont("t13", weight: "semibold")
                if !sprint.goal.isEmpty { Faint("Goal: \(sprint.goal)", size: "t13") }
                Faint("The PO's written review isn't sent to clients yet.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Faint("No sprint has closed yet.", size: "t13")
        }
    }
}

/// List (kept in server mode, decision #36): every item of the project, grouped by state, or by the requirement
/// it serves.
struct ServerListSurface: View {
    let store: QuestServerStore
    let project: ServerProject
    let snapshot: ProjectSnapshot
    let search: String
    @State private var byRequirement = false
    @State private var open: ServerIssue?

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let issues = BacklogLogic.ranked(
            snapshot.issues.filter {
                $0.state != "cancelled"
                    && (query.isEmpty || $0.title.lowercased().contains(query) || $0.key.lowercased().contains(query))
            })
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack {
                Faint("\(issues.count) items")
                Spacer()
                AinkradToggleButton(isOn: $byRequirement, title: "Group by requirement").fixedSize()
            }
            .padding(.horizontal, AinkradSpacing.md)
            .controlSize(.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                    if byRequirement {
                        ForEach(RequirementGrouping.groups(issues, requirements: store.requirements)) { group in
                            AinkradSectionHeader(
                                title: group.requirement.map { "\($0.key) · \($0.title)" } ?? "No requirement",
                                subtitle: "\(group.items.count) items")
                            ForEach(group.items) { row($0) }
                        }
                    } else {
                        ForEach(["in_progress", "in_review", "blocked", "todo", "backlog", "done"], id: \.self) { state in
                            let items = issues.filter { $0.state == state }
                            if !items.isEmpty {
                                AinkradSectionHeader(title: BoardLogic.title(state), subtitle: "\(items.count) items")
                                ForEach(items) { row($0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, AinkradSpacing.md)
            }
        }
        .ainkradModal(isPresented: Binding(get: { open != nil }, set: { if !$0 { open = nil } })) {
            if let open { ServerItemDetail(store: store, issue: open) { self.open = nil }.id(open.id) }
        }
    }

    private func row(_ issue: ServerIssue) -> some View {
        AinkradListRow(
            onTap: { open = issue },
            leading: {
                HStack(spacing: AinkradSpacing.sm) {
                    IssueKey(key: issue.key)
                    KindGlyph(kind: issue.kind)
                }
            }, title: issue.title,
            trailing: {
                HStack(spacing: AinkradSpacing.sm) {
                    RequirementTag(requirement: store.requirement(issue.requirementID))
                    AinkradPointsPill(points: issue.points)
                    ActorFigure(actor: issue.owner, store: store)
                }
            })
    }
}

/// Overview in server mode: the project's epics with their progress, and where its sprints stand.
struct ServerOverviewSurface: View {
    let store: QuestServerStore
    let project: ServerProject
    let snapshot: ProjectSnapshot
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let open = snapshot.issues.filter(\.isOpen)
        ScrollView {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                HStack(spacing: AinkradSpacing.lg) {
                    AinkradStatRow(label: "Open", value: "\(open.count)")
                    AinkradStatRow(label: "Unestimated", value: "\(open.filter { $0.points == nil }.count)", status: .warning)
                    AinkradStatRow(label: "Blocked", value: "\(open.filter { $0.state == "blocked" }.count)", status: .danger)
                    AinkradStatRow(label: "Waiting on you", value: "\(open.filter { if case .human = $0.next { true } else { false } }.count)")
                }
                AinkradSectionHeader(title: "Epics")
                ForEach(snapshot.epics) { epic in
                    let members = snapshot.issues.filter { $0.epicID == epic.id && $0.state != "cancelled" }
                    let done = members.filter { $0.state == "done" }.count
                    HStack(spacing: AinkradSpacing.sm) {
                        Text(verbatim: epic.title).questFont("t13").lineLimit(1)
                        Spacer()
                        AinkradStatusBar(value: Double(done), total: Double(max(members.count, 1)))
                            .frame(width: skin.size.s160)
                        Faint("\(done)/\(members.count) done")
                    }
                }
                if snapshot.epics.isEmpty { Faint("No epics yet.", size: "t13") }
            }
            .padding(AinkradSpacing.md)
        }
    }
}

/// Timeline in server mode: the project's sprints on their dates.
struct ServerTimelineSurface: View {
    let project: ServerProject
    let snapshot: ProjectSnapshot
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let sprints = snapshot.sprints.filter { $0.startsOn != nil }.sorted { $0.id < $1.id }
        if sprints.isEmpty {
            AinkradEmptyState(
                icon: QuestSurface.timeline.icon, title: "Nothing on the timeline",
                message: project.mode == .kanban ? "Kanban projects have no sprints." : "No sprints planned yet.")
        } else {
            let start = sprints.compactMap(\.startsOn).min() ?? Date()
            let end = sprints.compactMap { $0.endsOn ?? $0.startsOn }.max() ?? start
            let span = max(end.timeIntervalSince(start), 86_400)
            ScrollView {
                VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                    ForEach(sprints) { sprint in
                        HStack(spacing: AinkradSpacing.sm) {
                            Text(verbatim: sprint.name).questFont("t13", weight: "semibold")
                                .frame(width: skin.size.s80, alignment: .leading)
                            GeometryReader { geo in
                                let from = (sprint.startsOn ?? start).timeIntervalSince(start) / span
                                let to = ((sprint.endsOn ?? sprint.startsOn ?? start).timeIntervalSince(start) + 86_400) / span
                                AinkradStatusBar(value: 1, total: 1, kind: sprint.state == "active" ? .accent : .status(.neutral))
                                    .frame(width: max(geo.size.width * min(to - from, 1), skin.size.s8))
                                    .offset(x: geo.size.width * from)
                            }
                            .frame(height: skin.size.s12)
                            Faint(SprintPlanningSurface.dates(sprint).replacingOccurrences(of: " · ", with: ""))
                                .frame(width: skin.size.s120, alignment: .trailing)
                        }
                    }
                }
                .padding(AinkradSpacing.md)
            }
        }
    }
}
