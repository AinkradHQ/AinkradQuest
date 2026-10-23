import AinkradAppKit
import SwiftUI

/// Sprint planning (mockup 02): the backlog on the left, the planned sprint on the right — points against
/// capacity with the velocity mark, the goal, the issues and each assignee's load. Drag between the panes. Once
/// committed under the owner policy the plan locks and the gate bar asks for the decision — the same approval as
/// Citadel's inbox (decision #33).
struct SprintPlanningSurface: View {
    let store: QuestServerStore
    let project: ServerProject
    let snapshot: ProjectSnapshot
    let openCitadel: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @State private var rejecting: ServerApproval?
    @State private var reason = ""

    private var gate: SprintGate { SprintGate.state(sprints: snapshot.sprints, approvals: store.approvals) }

    var body: some View {
        let gate = gate
        if let sprint = gate.sprint {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                header(sprint, gate: gate)
                HStack(alignment: .top, spacing: AinkradSpacing.md) {
                    backlogPane(locked: gate.isLocked).frame(maxWidth: skin.size.s460)
                    sprintPane(sprint, locked: gate.isLocked)
                }
                footer(sprint, gate: gate)
            }
            .padding(.horizontal, AinkradSpacing.md)
            .padding(.bottom, AinkradSpacing.md)
            .animation(AinkradMotion.present, value: gate)
            .ainkradModal(isPresented: Binding(get: { rejecting != nil }, set: { if !$0 { rejecting = nil } })) {
                rejectForm
            }
        } else {
            AinkradEmptyState(
                icon: QuestSurface.sprint.icon, title: "No sprint being planned",
                message: SprintLogic.active(snapshot.sprints).map {
                    "\($0.name) is running. The product owner drafts the next sprint from the backlog."
                } ?? "The product owner drafts the first sprint from the backlog.")
        }
    }

    private func header(_ sprint: ServerSprint, gate: SprintGate) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            Text(verbatim: "\(sprint.name)\(Self.dates(sprint))").questFont("t16", weight: "bold")
            HStack(spacing: AinkradSpacing.sm) {
                switch gate {
                case .awaitingApproval: AinkradBadge(text: "Awaiting approval", status: .warning)
                case .rejected: AinkradBadge(text: "Rejected — re-planning", status: .danger)
                default: AinkradBadge(text: "Draft", status: .neutral)
                }
                Faint(
                    project.ownerApprovesSprints
                        ? "policy: you approve the commit" : "policy: the product owner commits alone")
            }
        }
    }

    static func dates(_ sprint: ServerSprint) -> String {
        guard let start = sprint.startsOn, let end = sprint.endsOn else { return "" }
        let style = Date.FormatStyle().month(.abbreviated).day()
        return " · \(start.formatted(style)) → \(end.formatted(style))"
    }

    private func backlogPane(locked: Bool) -> some View {
        let backlog = BacklogLogic.backlog(snapshot.issues)
        return VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack(spacing: AinkradSpacing.sm) {
                CapsLabel(text: "Backlog")
                Faint(locked ? "plan locked until you decide" : "drag into the sprint")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                    ForEach(backlog) { issue in PlanRow(store: store, issue: issue, locked: locked) }
                }
            }
        }
        .padding(AinkradSpacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .ainkradPanel()
        .dropDestination(for: String.self) { ids, _ in move(ids, to: nil, locked: locked) }
    }

    private func sprintPane(_ sprint: ServerSprint, locked: Bool) -> some View {
        let issues = BacklogLogic.ranked(snapshot.issues.filter { $0.sprintID == sprint.id })
        let points = SprintLogic.points(issues)
        let report = snapshot.reports[sprint.id]
        let capacity = report?.capacity
        let velocity = SprintLogic.velocityMark(snapshot.velocity)
        return VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                CapsLabel(text: "\(sprint.name) · \(issues.count) issues")
                Spacer()
                Text(verbatim: "\(points)").questFont("t20", weight: "bold")
                Faint(capacity.map { "/ \($0) pts capacity" } ?? "pts · no capacity set", size: "t13")
            }
            AinkradBudgetBar(
                label: "\(sprint.name) points", value: Double(points), limit: Double(max(capacity ?? points, 1)),
                warnFraction: velocity.flatMap { v in capacity.map { v / Double(max($0, 1)) } }, showsHardLimit: true,
                tone: .success, isThick: true
            )
            .help(velocityHelp)
            if !sprint.goal.isEmpty {
                (Text("Goal: ").bold() + Text(verbatim: sprint.goal))
                    .questFont("t13")
                    .padding(AinkradSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ainkradPanel()
            }
            HStack(alignment: .top, spacing: AinkradSpacing.md) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                        ForEach(issues) { issue in PlanRow(store: store, issue: issue, locked: locked) }
                    }
                }
                capacityColumn(issues, capacity: capacity).frame(width: skin.size.s240)
            }
        }
        .padding(AinkradSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ainkradPanel()
        .dropDestination(for: String.self) { ids, _ in move(ids, to: sprint.id, locked: locked) }
    }

    private var velocityHelp: String {
        guard let mark = SprintLogic.velocityMark(snapshot.velocity) else { return "No closed sprints yet" }
        let last = snapshot.velocity.prefix(3).map { "\($0.completed)" }.joined(separator: ", ")
        return "avg \(Int(mark.rounded())) (\(last))"
    }

    private func capacityColumn(_ issues: [ServerIssue], capacity: Int?) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            CapsLabel(text: "Capacity by assignee")
            ForEach(SprintLogic.loads(issues, capacity: capacity)) { load in
                HStack(spacing: AinkradSpacing.sm) {
                    ActorFigure(actor: load.actor, store: store)
                    Text(verbatim: store.name(load.actor) ?? "Unassigned").questFont("t13").lineLimit(1)
                    Spacer(minLength: AinkradSpacing.xs)
                    AinkradBudgetBar(
                        label: store.name(load.actor) ?? "", value: Double(load.points),
                        limit: Double(max(load.capacity, load.points, 1)), warnFraction: nil, showsHardLimit: false,
                        tone: load.isFull ? .warning : .accentSecondary
                    )
                    .frame(width: skin.size.s64)
                    Faint(load.capacity > 0 ? "\(load.points)/\(load.capacity)" : "\(load.points)")
                }
                .help(load.capacity > 0 ? "\(max(0, load.capacity - load.points)) pts left" : "")
            }
        }
    }

    @ViewBuilder private func footer(_ sprint: ServerSprint, gate: SprintGate) -> some View {
        switch gate {
        case .awaitingApproval(_, let approval):
            AinkradDecisionBar(
                icon: "flag.checkered", iconTint: .secondary, caption: "Awaiting approval",
                title: "\(sprint.name) · \(SprintLogic.points(snapshot.issues.filter { $0.sprintID == sprint.id })) pts — "
                    + "edits are paused until you decide",
                actions: [
                    .init(title: "Open in Citadel", style: .ghost, perform: openCitadel).borderless().secondaryAccent(),
                    .init(title: "Reject…", style: .secondary) {
                        reason = ""
                        rejecting = approval
                    },
                    .init(title: "Approve and start", style: .primary) {
                        Task { await store.decide(approval, approve: true, reply: nil, project: project.id) }
                    },
                ]
            )
            .labelCasedCaption()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        default:
            HStack {
                Faint(
                    project.ownerApprovesSprints
                        ? "The product owner commits the plan; it then waits here for your approval."
                        : "The product owner commits the plan and the sprint starts.")
                Spacer()
                AinkradButton(title: "Commit sprint →", style: .primary) {}
                    .disabled(true)
                    .help("Citadel commits sprints through the product owner only — no endpoint for people yet.")
            }
        }
    }

    private var rejectForm: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "Reject the sprint plan", subtitle: "The reason wakes the PO and Lead to re-plan.")
            AinkradTextField(text: $reason, placeholder: "Why")
            HStack {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost) { rejecting = nil }
                AinkradButton(title: "Reject", style: .primary) {
                    guard let approval = rejecting else { return }
                    rejecting = nil
                    let why = reason.trimmingCharacters(in: .whitespaces)
                    Task { await store.decide(approval, approve: false, reply: why.isEmpty ? nil : why, project: project.id) }
                }
            }
        }
        .frame(width: skin.size.s420)
    }

    private func move(_ ids: [String], to sprint: Int64?, locked: Bool) -> Bool {
        guard !locked, let id = ids.first.flatMap(Int64.init),
            let issue = snapshot.issues.first(where: { $0.id == id }), issue.sprintID != sprint
        else { return false }
        Task { await store.setSprint(issue, to: sprint, project: project.id) }
        return true
    }
}

/// A compact planning row: key, type, title, points, assignee; draggable unless the plan is locked.
private struct PlanRow: View {
    let store: QuestServerStore
    let issue: ServerIssue
    let locked: Bool
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let row = HStack(spacing: AinkradSpacing.sm) {
            IssueKey(key: issue.key).frame(width: skin.size.s60, alignment: .leading)
            KindGlyph(kind: issue.kind)
            Text(verbatim: issue.title).questFont("t13").lineLimit(1)
            Spacer(minLength: AinkradSpacing.xs)
            AinkradPointsPill(points: issue.points, estimator: store.name(issue.next))
            ActorFigure(actor: issue.owner, store: store)
        }
        .padding(.vertical, AinkradSpacing.xs)
        .contentShape(Rectangle())
        if locked { row } else { row.draggable(String(issue.id)) }
    }
}
