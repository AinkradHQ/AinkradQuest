import AinkradAppKit
import SwiftUI

/// Backlog (mockup 01): every open item not in a sprint, in rank order, grouped by epic ("No epic" last). Drag a
/// row to re-rank — dropping into another epic's group moves it to that epic; the server's order wins on a
/// conflict, with Undo.
struct ServerBacklogSurface: View {
    let store: QuestServerStore
    let project: ServerProject
    let snapshot: ProjectSnapshot
    let search: String
    let planSprint: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @State private var filter = BacklogFilter()
    @State private var collapsed: Set<Int64> = []

    private var order: [ServerIssue] { store.pendingOrder[project.id] ?? BacklogLogic.backlog(snapshot.issues) }

    var body: some View {
        let order = order
        var active = filter
        active.text = search
        let shown = active.apply(order)
        let groups = BacklogLogic.groups(shown, epics: snapshot.epics, all: snapshot.issues)
        return VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            BacklogFilters(store: store, project: project, snapshot: snapshot, order: order, filter: $filter) {
                Faint("Rank order · \(shown.count) items · \(SprintLogic.points(shown)) pts")
                if project.mode == .scrum, let planned = snapshot.sprints.last(where: { $0.state == "planned" }) {
                    AinkradButton(title: "Plan sprint \(planned.name) →", style: .secondary, action: planSprint)
                        .compact().fixedSize()
                }
            }
            if order.isEmpty {
                AinkradEmptyState(
                    icon: QuestSurface.backlog.icon, title: "The backlog is empty",
                    message: "Everything open is in a sprint. ＋ adds an item.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: skin.size.s2) {
                        ForEach(groups) { group in
                            EpicHeader(group: group, collapsed: collapsed.contains(group.id)) {
                                collapsed = toggledSelection(group.id, in: collapsed)
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                drop(ids, before: group.items.first, epic: group.epic?.id, order: order)
                            }
                            if !collapsed.contains(group.id) {
                                ForEach(group.items) { issue in
                                    BacklogRow(store: store, project: project, issue: issue) { ids in
                                        drop(ids, before: issue, epic: issue.epicID, order: order)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AinkradSpacing.md)
                    .padding(.bottom, AinkradSpacing.xl)
                    .animation(AinkradMotion.present, value: order.map(\.id))
                }
            }
        }
    }

    /// A row dropped before `target` (or at the top of an empty group) in epic `epic`.
    private func drop(_ ids: [String], before target: ServerIssue?, epic: Int64?, order: [ServerIssue]) -> Bool {
        guard let id = ids.first.flatMap(Int64.init) else { return false }
        let index = target.flatMap { t in order.firstIndex { $0.id == t.id } } ?? order.count
        guard let move = BacklogLogic.move(id, to: index, in: order, epic: epic) else { return false }
        Task { await store.rerank(move, project: project.id) }
        return true
    }
}

/// The filter row: type, epic, assignee, requirement and "Unestimated", then the trailing content.
struct BacklogFilters<Trailing: View>: View {
    let store: QuestServerStore
    let project: ServerProject
    let snapshot: ProjectSnapshot
    let order: [ServerIssue]
    @Binding var filter: BacklogFilter
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        HStack(spacing: AinkradSpacing.sm) {
            kindSelect
            epicSelect
            labelSelect
            assigneeSelect
            requirementSelect
            AinkradToggleButton(
                isOn: $filter.unestimated, systemName: "questionmark.circle",
                title: "Unestimated \(order.filter { $0.points == nil }.count)"
            )
            .fixedSize()
            Spacer(minLength: AinkradSpacing.sm)
            trailing()
        }
        .padding(.horizontal, AinkradSpacing.md)
        .controlSize(.small)
    }

    private var kindSelect: some View {
        let kinds = [""] + Array(Set(order.map(\.kind))).sorted()
        let binding = Binding<String>(get: { filter.kind ?? "" }, set: { filter.kind = $0.isEmpty ? nil : $0 })
        return AinkradSelect(items: kinds, selection: binding) { $0.isEmpty ? "Type: all" : $0.capitalized }
            .fixedSize()
    }

    private var epicSelect: some View {
        let epics: [BacklogFilter.Pick<Int64>] = [.all] + snapshot.epics.map { .some($0.id) } + [.none]
        return AinkradSelect(items: epics, selection: $filter.epic) { pick -> String in
            switch pick {
            case .all: "Epic: all"
            case .none: "No epic"
            case .some(let id): snapshot.epics.first { $0.id == id }?.title ?? "Epic"
            }
        }
        .fixedSize()
    }

    private var labelSelect: some View {
        let picks: [BacklogFilter.Pick<Int64>] = [.all] + snapshot.labels.map { .some($0.id) } + [.none]
        return AinkradSelect(items: picks, selection: $filter.label) { pick -> String in
            switch pick {
            case .all: "Label: all"
            case .none: "No label"
            case .some(let id): snapshot.labels.first { $0.id == id }?.name ?? "Label"
            }
        }
        .fixedSize()
    }

    private var assigneeSelect: some View {
        let owners: [ServerActor] = [.none] + Array(Set(order.map(\.owner).filter { $0 != .none }))
        let binding = Binding<ServerActor>(
            get: { filter.assignee ?? .none }, set: { filter.assignee = $0 == .none ? nil : $0 })
        return AinkradSelect(items: owners, selection: binding) { actor -> String in
            actor == .none ? "Assignee: all" : store.name(actor) ?? "Someone"
        }
        .fixedSize()
    }

    private var requirementSelect: some View {
        let ids = Array(Set(order.compactMap(\.requirementID))).sorted()
        let picks: [BacklogFilter.Pick<Int64>] = [.all] + ids.map { .some($0) } + [.none]
        return AinkradSelect(items: picks, selection: $filter.requirement) { pick -> String in
            switch pick {
            case .all: "Requirement: all"
            case .none: "No requirement"
            case .some(let id): store.requirement(id)?.key ?? "R-?"
            }
        }
        .fixedSize()
    }
}

/// ◆ Epic title, its progress bar and "N/M done"; tap folds the group.
private struct EpicHeader: View {
    let group: BacklogGroup
    let collapsed: Bool
    let toggle: () -> Void
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradIconGlyph(systemName: collapsed ? "chevron.right" : "chevron.down", size: skin.size.s10)
                .foregroundStyle(skin.color(skin.text.faint))
            AinkradIconGlyph(systemName: group.epic == nil ? "diamond" : "diamond.fill", size: skin.size.s12)
                .foregroundStyle(
                    group.epic == nil ? skin.color(skin.text.faint) : skin.color(skin.palette.accentViolet))
            Text(verbatim: group.epic?.title ?? "No epic").questFont("t13", weight: "bold")
                .foregroundStyle(group.epic == nil ? skin.color(skin.text.muted) : skin.color(skin.text.primary))
            if let key = group.epic?.key, !key.isEmpty { IssueKey(key: key) }
            if group.epic != nil {
                AinkradStatusBar(value: Double(group.done), total: Double(max(group.total, 1)), kind: .accent)
                    .frame(width: skin.size.s120)
                Faint("\(group.done)/\(group.total) done")
            } else {
                Faint("\(group.items.count) items")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, AinkradSpacing.md)
        .padding(.bottom, AinkradSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

/// One backlog row: grip (on hover), key, type, title, requirement tag, points, assignee, ⋯.
struct BacklogRow: View {
    let store: QuestServerStore
    let project: ServerProject
    let issue: ServerIssue
    let onDrop: ([String]) -> Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            // The drop slot: a glowing gap where the row will land, not a line.
            if targeted {
                RoundedRectangle(cornerRadius: skin.radius.sm)
                    .fill(theme.accentSecondary.opacity(skin.opacity.o08))
                    .overlay(
                        RoundedRectangle(cornerRadius: skin.radius.sm)
                            .stroke(theme.accentSecondary.opacity(skin.opacity.o35), lineWidth: 1)
                    )
                    .frame(height: skin.size.s34)
                    .transition(.opacity.combined(with: .scale(scale: 1, anchor: .top)))
            }
            row
        }
        .animation(AinkradMotion.present, value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            onDrop(ids)
        } isTargeted: {
            targeted = $0
        }
    }

    private var row: some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradIconGlyph(systemName: "line.3.horizontal", size: skin.size.s10)
                .foregroundStyle(skin.color(skin.text.faint))
                .opacity(hovering ? 1 : 0)
            IssueKey(key: issue.key).frame(width: skin.size.s60, alignment: .leading)
            KindGlyph(kind: issue.kind)
            Text(verbatim: issue.title).questFont("t13").foregroundStyle(skin.color(skin.text.primary)).lineLimit(1)
            Spacer(minLength: AinkradSpacing.sm)
            RequirementTag(requirement: store.requirement(issue.requirementID))
            LabelChips(labels: issue.labels)
            AinkradPointsPill(
                points: Binding(
                    get: { issue.points },
                    set: { points in Task { await store.estimate(issue, points: points, project: project.id) } }),
                estimator: store.name(issue.next))
            ActorFigure(actor: issue.owner, store: store)
            AinkradMenuButton(items: menu) {
                AinkradIconGlyph(systemName: "ellipsis", size: skin.size.s12)
                    .foregroundStyle(skin.color(skin.text.faint))
            }
        }
        .padding(.horizontal, AinkradSpacing.sm)
        .padding(.vertical, AinkradSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: skin.radius.sm)
                .fill(theme.accentPrimary.opacity(fillOpacity))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(AinkradMotion.present, value: store.flashing.contains(issue.id))
        .draggable(String(issue.id)) {
            Text(verbatim: "\(issue.key)  \(issue.title)").questFont("t13")
                .padding(AinkradSpacing.sm)
                .background(RoundedRectangle(cornerRadius: skin.radius.sm).fill(theme.surfaceElevated))
                .rotationEffect(.degrees(-0.6))
                .scaleEffect(1.02)
        }
    }

    private var fillOpacity: Double {
        if store.flashing.contains(issue.id) { return skin.opacity.o22 }
        return hovering ? skin.opacity.o06 : 0
    }

    private var menu: [AinkradMenuItem] {
        let order = BacklogLogic.backlog(store.snapshots[project.id]?.issues ?? [])
        var items = [
            AinkradMenuItem(title: "Move to top", systemName: "arrow.up.to.line") {
                Task { await store.rerank(RankMove(issue: issue.id, place: .top, epic: nil), project: project.id) }
            },
            AinkradMenuItem(title: "Move to bottom", systemName: "arrow.down.to.line") {
                guard let last = order.last, last.id != issue.id else { return }
                Task {
                    await store.rerank(
                        RankMove(issue: issue.id, place: .after(last.id), epic: nil), project: project.id)
                }
            },
        ]
        if let planned = store.snapshots[project.id]?.sprints.last(where: { $0.state == "planned" }) {
            items.append(
                AinkradMenuItem(title: "Add to \(planned.name)", systemName: "flag") {
                    Task { await store.setSprint(issue, to: planned.id, project: project.id) }
                })
        }
        return items + LabelChips.menu(store: store, issue: issue, project: project.id)
    }
}
