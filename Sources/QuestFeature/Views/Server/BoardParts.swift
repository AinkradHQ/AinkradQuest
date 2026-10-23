import AinkradAppKit
import SwiftUI

/// A board column: a panel with its caps title, WIP limit ("WIP 2 / 2", amber at the limit) and count; it
/// brightens while a card is over it.
struct ColumnPanel<Cards: View>: View {
    let column: ServerColumn
    let count: Int
    /// Cards in the column's own state — what the WIP limit counts.
    let wipCount: Int
    let isFull: Bool
    @ViewBuilder let cards: () -> Cards
    let onDrop: ([String]) -> Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack(spacing: AinkradSpacing.xs) {
                CapsLabel(text: column.title)
                if let limit = column.limit {
                    Text(verbatim: "WIP \(wipCount) / \(limit)").questFont("t10", mono: true)
                        .foregroundStyle(isFull ? status.warning : skin.color(skin.text.faint))
                } else if column.state == "todo", column.title == "Ready" {
                    Faint("no limit", size: "t10")
                }
                Spacer(minLength: 0)
                AinkradBadge(text: "\(count)", status: isFull ? .warning : .neutral)
            }
            LazyVStack(alignment: .leading, spacing: AinkradSpacing.sm) { cards() }
        }
        .padding(AinkradSpacing.sm)
        .frame(width: skin.size.s260, alignment: .top)
        .ainkradPanel()
        .overlay(
            RoundedRectangle(cornerRadius: skin.radius.panel)
                .stroke(stroke, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .animation(AinkradMotion.present, value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            onDrop(ids)
        } isTargeted: {
            targeted = $0
        }
    }

    private var stroke: Color {
        if targeted { return theme.accentSecondary.opacity(skin.opacity.o70) }
        return isFull ? status.warning.opacity(skin.opacity.o60) : .clear
    }
}

/// A board card: title, what an agent is doing on it now, key, requirement tag, points (Scrum) and assignee.
/// Red rim when blocked, amber when a merge waits on you or a drop just bounced.
struct BoardCard: View {
    let store: QuestServerStore
    let project: ServerProject
    let issue: ServerIssue
    let onOpen: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var status

    private var merge: ServerApproval? {
        store.approvals.first { $0.kind == "pr_merge" && $0.status == "pending" && $0.issueID == issue.id }
    }

    var body: some View {
        AinkradCard(onTap: onOpen) {
            VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                Text(verbatim: issue.title).questFont("t13").lineLimit(2)
                    .foregroundStyle(skin.color(issue.state == "done" ? skin.text.muted : skin.text.primary))
                WorkingLine(issue: issue, store: store, hidesWaiting: merge != nil)
                if merge != nil {
                    Text("QA passed · merge waits on you").questFont("t11").foregroundStyle(status.warning)
                }
                HStack(spacing: AinkradSpacing.xs) {
                    IssueKey(key: issue.key)
                    RequirementTag(requirement: store.requirement(issue.requirementID))
                    if issue.state == "blocked" { AinkradBadge(text: "Blocked", status: .danger) }
                    if issue.state == "done" { AinkradBadge(text: "✓ done", status: .success) }
                    Spacer(minLength: 0)
                    if project.mode == .scrum, issue.state != "done", let points = issue.points {
                        AinkradPointsPill(points: points)
                    }
                    ActorFigure(actor: issue.owner, store: store)
                }
                if let merge {
                    AinkradButton(title: "Merge", style: .primary) {
                        Task { await store.decide(merge, approve: true, reply: nil, project: project.id) }
                    }
                    .compact().fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .rim(rim)
        .opacity(store.bounced == issue.id ? skin.opacity.o70 : 1)
        .animation(AinkradMotion.present, value: store.bounced)
    }

    private var rim: AinkradChartTone? {
        if store.bounced == issue.id || merge != nil { return .warning }
        if issue.state == "blocked" { return .danger }
        if store.flashing.contains(issue.id) { return .accentSecondary }
        return nil
    }
}

extension AinkradCard {
    /// The rim tint when there is one; otherwise the skin's own stroke.
    func rim(_ tone: AinkradChartTone?) -> Self { tone.map(rimTint) ?? self }
}

/// The burndown tile on the Scrum board: ideal dashed, actual solid; "11 pts left · on track".
struct BurndownTile: View {
    let snapshot: ProjectSnapshot
    let sprint: ServerSprint?
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let report = sprint.flatMap { snapshot.reports[$0.id] }
        let left = report?.burndown.last?.left
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack {
                CapsLabel(text: "Burndown")
                Spacer()
                Faint(
                    [
                        left.map { "\($0) pts left" },
                        report.flatMap {
                            SprintLogic.pace(burndown: $0.burndown, start: sprint?.startsOn, end: sprint?.endsOn)
                        },
                    ]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            BurndownChart(report: report, sprint: sprint).frame(height: skin.size.s80)
        }
        .padding(AinkradSpacing.sm)
        .ainkradPanel()
        .help("Open Reports")
    }
}

/// Ideal (dashed) and actual (solid) burndown of one sprint.
struct BurndownChart: View {
    let report: SprintReportInfo?
    let sprint: ServerSprint?

    var body: some View {
        let points = report?.burndown ?? []
        let start = sprint?.startsOn ?? points.first?.day ?? Date()
        let end = sprint?.endsOn ?? points.last?.day ?? start
        let day: (Date) -> Double = { $0.timeIntervalSince(start) / 86_400 }
        let first = Double(points.first?.left ?? report?.committed ?? 0)
        AinkradLineChart(
            title: "Burndown",
            series: [
                AinkradChartSeries(
                    name: "Ideal", points: [.init(x: 0, y: first), .init(x: day(end), y: 0)], tone: .muted,
                    isDashed: true),
                AinkradChartSeries(
                    name: "Actual",
                    points: points.map {
                        AinkradChartPoint(
                            x: day($0.day), y: Double($0.left),
                            label: $0.day.formatted(date: .abbreviated, time: .omitted))
                    },
                    tone: .accentSecondary),
            ],
            emptyMessage: "No burndown yet", format: { "\(Int($0)) pts" })
    }
}

/// Kanban header stats. Citadel does not report cycle time, lead time or throughput yet, so they read "—".
struct KanbanStats: View {
    var body: some View {
        HStack(spacing: AinkradSpacing.lg) {
            stat("Cycle time")
            stat("Lead time")
            stat("Throughput")
        }
        .help("Citadel doesn't report cycle time, lead time or throughput yet.")
    }

    private func stat(_ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AinkradSpacing.xs) {
            CapsLabel(text: label)
            Text("—").questFont("t18", weight: "bold")
        }
    }
}

/// An item's details in server mode: read-only here — Citadel owns the issue.
struct ServerItemDetail: View {
    let store: QuestServerStore
    let issue: ServerIssue
    let onClose: () -> Void
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            HStack(spacing: AinkradSpacing.sm) {
                IssueKey(key: issue.key)
                KindGlyph(kind: issue.kind)
                AinkradBadge(text: BoardLogic.title(issue.state))
                RequirementTag(requirement: store.requirement(issue.requirementID))
                Spacer()
                ActorFigure(actor: issue.owner, store: store, size: skin.size.s28)
            }
            Text(verbatim: issue.title).questFont("t16", weight: "bold")
            if !issue.body.isEmpty {
                ScrollView { AinkradMarkdownText(text: issue.body).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: skin.size.s240)
            }
            WorkingLine(issue: issue, store: store)
            HStack {
                Spacer()
                AinkradButton(title: "Close", style: .secondary, action: onClose)
            }
        }
        .frame(width: skin.size.s460)
    }
}
