import AinkradAppKit
import SwiftUI

/// The server-mode sidebar: the company switcher (E15.15 — same companies as Citadel, own / client badge), Today,
/// the selected company's projects only, and which server it reads.
struct ServerSidebar: View {
    @Bindable var store: QuestServerStore
    @Binding var surface: QuestSurface
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            if !store.companies.isEmpty {
                AinkradWorkspaceSwitcher(
                    workspaces: store.companies.map {
                        AinkradWorkspace(id: String($0.id), name: $0.name, kind: $0.isClient ? .client : .own)
                    },
                    selection: Binding(
                        get: { String(store.company?.id ?? 0) },
                        set: { if let id = Int64($0) { store.select(company: id) } }),
                    subtitle: "Quest · \(store.companies.count) \(store.companies.count == 1 ? "company" : "companies")")
            }
            AinkradListRow(
                isSelected: surface == .today, onTap: { surface = .today },
                leading: { AinkradIconGlyph(systemName: QuestSurface.today.icon) }, title: QuestSurface.today.title,
                trailing: { Faint("\(ServerToday.items(store).count)") })
            AinkradSectionHeader(title: "Projects")
            ScrollView {
                LazyVStack(spacing: AinkradSpacing.xs) {
                    ForEach(store.companyProjects) { project in
                        AinkradListRow(
                            isSelected: store.selectedProject?.id == project.id && surface != .today,
                            onTap: {
                                store.select(project: project.id)
                                if surface == .today { surface = .backlog }
                            },
                            leading: { AinkradIconGlyph(systemName: project.mode == .kanban ? "rectangle.split.3x1" : "flag") },
                            title: project.name, trailing: { Faint(badge(project), size: "t10") })
                    }
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(AinkradSpacing.md)
    }

    /// `S4 · day 6` for a Scrum project mid-sprint, `Kanban` for a Kanban one.
    private func badge(_ project: ServerProject) -> String {
        guard project.mode == .scrum else { return "Kanban" }
        guard let sprint = store.snapshots[project.id].flatMap({ SprintLogic.active($0.sprints) }) else { return "" }
        let day = sprint.startsOn.map { ServerDay.days(from: $0, to: Date()) }
        return day.map { "\(sprint.name) · day \($0 + 1)" } ?? sprint.name
    }

    private var footer: some View {
        HStack(spacing: AinkradSpacing.xs) {
            Circle().fill(dotColor).frame(width: skin.size.s6, height: skin.size.s6)
            Text(verbatim: store.host).questFont("t11", mono: true).foregroundStyle(skin.color(skin.text.muted))
                .lineLimit(1)
            Spacer(minLength: 0)
            AinkradMenuButton(items: [
                AinkradMenuItem(title: "Disconnect — back to this Mac's projects", systemName: "bolt.horizontal") {
                    store.disconnect()
                }
            ]) { AinkradIconGlyph(systemName: "ellipsis", size: skin.size.s12) }
        }
        .help("Quest reads \(store.host). Projects made on this Mac stay on this Mac, untouched.")
    }

    private var dotColor: Color {
        switch (store.phase, store.streamStatus) {
        case (.connected, .live?): status.success
        case (.offline, _), (.rejected, _), (_, .offline?), (_, .rejected?): status.danger
        default: status.warning
        }
    }
}

/// Today in server mode: what waits on the person across the company's projects — items whose next actor is you,
/// and sprint commits awaiting your approval.
@MainActor
enum ServerToday {
    static func items(_ store: QuestServerStore) -> [ServerIssue] {
        store.companyProjects.flatMap { store.snapshots[$0.id]?.issues ?? [] }
            .filter { issue in
                guard issue.isOpen, case .human = issue.next else { return false }
                return issue.state != "backlog"
            }
    }
}

struct ServerTodaySurface: View {
    let store: QuestServerStore
    let onOpen: (ServerIssue) -> Void

    var body: some View {
        let items = ServerToday.items(store)
        if items.isEmpty {
            AinkradEmptyState(
                icon: QuestSurface.today.icon, title: "Nothing waits on you",
                message: "Items the agents hand back to you show up here.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                    AinkradSectionHeader(title: "Waiting on you", subtitle: "\(items.count) items")
                    ForEach(items) { issue in
                        AinkradListRow(
                            onTap: { onOpen(issue) }, leading: { IssueKey(key: issue.key) }, title: issue.title,
                            subtitle: BoardLogic.title(issue.state),
                            trailing: { RequirementTag(requirement: store.requirement(issue.requirementID)) })
                    }
                }
                .padding(AinkradSpacing.md)
            }
        }
    }
}
