import AinkradAppKit
import SwiftUI

/// Quest in server mode (E12): the shipping shell — 232 pt sidebar, one header row with the surface switcher,
/// search and ＋ / ⚙ — reading a Citadel server instead of local files. Backlog, Sprint and Reports join List
/// (decision #36); a Kanban project has no Sprint tab.
struct ServerShell: View {
    @Bindable var store: QuestServerStore
    /// Opens the Citadel app (the gear, "Open in Citadel").
    let openCitadel: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @State private var surface: QuestSurface
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var showingNewItem = false

    init(store: QuestServerStore, openCitadel: @escaping () -> Void, surface: QuestSurface = .backlog) {
        self.store = store
        self.openCitadel = openCitadel
        _surface = State(initialValue: surface)
    }

    private var project: ServerProject? { store.selectedProject }

    var body: some View {
        VStack(spacing: 0) {
            QuestHeader(
                surface: $surface, searchText: $searchText, searchFocused: $searchFocused,
                showsSwitcher: project != nil && surface != .today,
                surfaces: SurfaceVisibility.offeredOnServer(kanban: project?.mode == .kanban),
                showsSettings: project != nil, actionsEnabled: !showingNewItem, showsTrash: false,
                onNew: { if project != nil { showingNewItem = true } }, onSettings: openCitadel, onTrash: {})
            connectionBanner
            HStack(spacing: 0) {
                ServerSidebar(store: store, surface: $surface).frame(width: skin.size.s232)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        ServerNoticeBar(store: store).padding(.bottom, AinkradSpacing.md)
                    }
            }
        }
        .animation(AinkradMotion.present, value: store.notice)
        .ainkradPanel()
        .onAppear { store.start() }
        .onChange(of: store.selectedProject?.mode) { _, mode in
            if mode == .kanban, surface == .sprint { surface = .board }
        }
        .ainkradModal(isPresented: $showingNewItem) {
            if let project {
                NewServerItemForm(store: store, project: project) { showingNewItem = false }.id(project.id)
            }
        }
    }

    @ViewBuilder private var connectionBanner: some View {
        switch store.phase {
        case .offline(let reason):
            AinkradBanner(
                message: "Can't reach \(store.host) — \(reason). Showing what was last read.", status: .warning,
                actionTitle: "Retry now", action: { store.connect() }
            )
            .padding(.horizontal, AinkradSpacing.md)
        default:
            if case .offline = store.streamStatus {
                AinkradBanner(
                    message: "The live stream from \(store.host) dropped — reconnecting.", status: .warning,
                    actionTitle: "Retry now", action: { store.retryNow() }
                )
                .padding(.horizontal, AinkradSpacing.md)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.phase == .rejected || (store.phase == .setup && !store.hasStoredKey) {
            ServerConnectCard(store: store, onDone: {})
        } else if surface == .today {
            ServerTodaySurface(store: store) { issue in
                store.select(project: issue.projectID)
                surface = .backlog
            }
        } else if let project, let snapshot = store.snapshots[project.id] {
            ZStack {
                switch surface {
                case .overview: ServerOverviewSurface(store: store, project: project, snapshot: snapshot)
                case .list: ServerListSurface(store: store, project: project, snapshot: snapshot, search: searchText)
                case .backlog:
                    ServerBacklogSurface(store: store, project: project, snapshot: snapshot, search: searchText) {
                        surface = .sprint
                    }
                case .sprint: SprintPlanningSurface(store: store, project: project, snapshot: snapshot, openCitadel: openCitadel)
                case .board: ServerBoardSurface(store: store, project: project, snapshot: snapshot, search: searchText) {
                    surface = .reports
                }
                case .reports: ServerReportsSurface(store: store, project: project, snapshot: snapshot)
                case .timeline: ServerTimelineSurface(project: project, snapshot: snapshot)
                case .today: EmptyView()
                }
            }
            .animation(AinkradMotion.present, value: surface)
        } else if project != nil || store.phase != .connected {
            AinkradLoadingState(label: loadingLabel)
        } else {
            AinkradEmptyState(
                icon: "square.stack.3d.up", title: "No projects here",
                message: "This company has no projects yet. Create one in Citadel.")
        }
    }

    private var loadingLabel: String {
        if case .connecting(let step) = store.phase { return step }
        return "Reading \(store.host)…"
    }
}

/// ＋ in server mode: a new backlog item in the selected project, optionally under an epic.
struct NewServerItemForm: View {
    let store: QuestServerStore
    let project: ServerProject
    let onClose: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @State private var title = ""
    @State private var epic: Int64 = -1

    private var epics: [ServerEpic] { store.snapshots[project.id]?.epics.filter { $0.status != "done" } ?? [] }
    private var trimmed: String { title.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "New item in \(project.name)")
            AinkradFormRow(title: "Title") { AinkradTextField(text: $title, placeholder: "What needs doing") }
            AinkradFormRow(title: "Epic") {
                AinkradSelect(items: [-1] + epics.map(\.id), selection: $epic) { id in
                    epics.first { $0.id == id }?.title ?? "No epic"
                }
            }
            HStack {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost, action: onClose)
                AinkradButton(title: "Add to backlog", style: .primary) { create() }.disabled(trimmed.isEmpty)
            }
        }
        .onSubmit(create)
        .background(HiddenShortcutButton(.defaultAction) { create() }.disabled(trimmed.isEmpty))
        .frame(width: skin.size.s420)
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        let title = trimmed
        let epic = epic < 0 ? nil : epic
        onClose()
        Task { await store.createIssue(title: title, epic: epic, project: project.id) }
    }
}
