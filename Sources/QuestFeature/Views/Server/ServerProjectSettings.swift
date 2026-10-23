import AinkradAppKit
import SwiftUI

/// ⚙ in server mode: the project's settings on the server — its name, mode and sprint-approval policy
/// (`updateProject`), the board's WIP limits, its labels, and each team member's capacity. "Raise limit…" opens
/// it on the WIP limits; "Manage labels…" on the labels.
struct ServerProjectSettings: View {
    let store: QuestServerStore
    let project: ServerProject
    let onClose: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @State private var section: SettingsSection
    @State private var name: String
    @State private var kanban: Bool
    @State private var ownerApproves: Bool
    @State private var limits: [String: Int]
    @State private var capacities: [Int64: Int]
    @State private var newLabel = ""
    @State private var labelNames: [Int64: String] = [:]

    init(store: QuestServerStore, project: ServerProject, section: SettingsSection, onClose: @escaping () -> Void) {
        self.store = store
        self.project = project
        self.onClose = onClose
        let snapshot = store.snapshots[project.id]
        _section = State(initialValue: section)
        _name = State(initialValue: project.name)
        _kanban = State(initialValue: project.mode == .kanban)
        _ownerApproves = State(initialValue: project.ownerApprovesSprints)
        _limits = State(initialValue: snapshot?.limits ?? [:])
        _capacities = State(
            initialValue: Dictionary(
                (snapshot?.capacity.members ?? []).map { ($0.agentID, $0.capacity ?? 0) }, uniquingKeysWith: { $1 }))
    }

    private var snapshot: ProjectSnapshot? { store.snapshots[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "\(project.name) settings", subtitle: "\(project.key) · on \(store.host)")
            AinkradSegmentedPicker(items: SettingsSection.allCases, selection: $section) { $0.rawValue }.fixedSize()
            Group {
                switch section {
                case .project: projectSection
                case .limits: limitsSection
                case .labels: labelsSection
                case .capacity: capacitySection
                }
            }
            .frame(minHeight: skin.size.s200, alignment: .top)
            HStack {
                Spacer()
                AinkradButton(title: "Done", style: .secondary, action: onClose)
            }
        }
        .frame(width: skin.size.s460)
    }

    // MARK: - Project

    private var projectSection: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let changed =
            trimmed != project.name || kanban != (project.mode == .kanban)
            || ownerApproves != project.ownerApprovesSprints
        return VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradFormRow(title: "Name") { AinkradTextField(text: $name, placeholder: "Project name") }
            AinkradFormRow(title: "Mode", help: "Scrum to Kanban only with no planned or active sprint.") {
                AinkradSegmentedPicker(items: [false, true], selection: $kanban) { $0 ? "Kanban" : "Scrum" }
                    .fixedSize()
            }
            AinkradFormRow(title: "Sprint commit") {
                AinkradSelect(items: [true, false], selection: $ownerApproves) {
                    $0 ? "You approve the commit" : "The product owner commits alone"
                }
            }
            HStack {
                Spacer()
                AinkradButton(title: "Save", style: .primary) {
                    Task {
                        await store.updateProject(project, name: trimmed, kanban: kanban, ownerApproves: ownerApproves)
                    }
                }
                .disabled(!changed || trimmed.isEmpty)
            }
        }
    }

    // MARK: - WIP limits

    private var limitsSection: some View {
        let columns = BoardLogic.columns(mode: project.mode, limits: snapshot?.limits ?? [:]).filter {
            $0.state != "done"
        }
        return VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            Faint("0 means no limit. The server refuses a move into a full column, agents' moves too.", size: "t13")
            ForEach(columns) { column in
                AinkradFormRow(title: column.title, help: column.limit.map { "now \($0)" } ?? "now no limit") {
                    AinkradStepper(
                        value: Binding(get: { limits[column.state] ?? 0 }, set: { limits[column.state] = $0 }),
                        in: 0...50)
                }
            }
            HStack {
                Spacer()
                AinkradButton(title: "Save limits", style: .primary) {
                    let current = snapshot?.limits ?? [:]
                    let changes = columns.map(\.state).filter { (limits[$0] ?? 0) != (current[$0] ?? 0) }
                    Task {
                        for state in changes {
                            let limit = limits[state] ?? 0
                            await store.setLimit(limit > 0 ? limit : nil, state: state, project: project.id)
                        }
                    }
                }
                .disabled(columns.allSatisfy { (limits[$0.state] ?? 0) == (snapshot?.limits[$0.state] ?? 0) })
            }
        }
    }

    // MARK: - Labels

    private var labelsSection: some View {
        let labels = snapshot?.labels ?? []
        let typed = newLabel.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            if labels.isEmpty { Faint("No labels yet.", size: "t13") }
            ForEach(labels) { label in
                let draft = Binding(get: { labelNames[label.id] ?? label.name }, set: { labelNames[label.id] = $0 })
                let renamed = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
                HStack(spacing: AinkradSpacing.sm) {
                    AinkradTextField(text: draft, placeholder: label.name)
                    AinkradButton(title: "Rename", style: .ghost) {
                        Task { await store.renameLabel(label, to: renamed, project: project.id) }
                    }
                    .compact().fixedSize()
                    .disabled(renamed.isEmpty || renamed == label.name)
                    AinkradIconButton(systemName: "trash", size: skin.size.s28, tooltip: "Delete \(label.name)") {
                        Task { await store.deleteLabel(label, project: project.id) }
                    }
                }
            }
            HStack(spacing: AinkradSpacing.sm) {
                AinkradTextField(text: $newLabel, placeholder: "New label")
                AinkradButton(title: "Add", style: .primary) {
                    newLabel = ""
                    Task { await store.createLabel(typed, project: project.id) }
                }
                .compact().fixedSize()
                .disabled(typed.isEmpty)
            }
        }
    }

    // MARK: - Capacity

    private var capacitySection: some View {
        let members = snapshot?.capacity.members ?? []
        return VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            if members.isEmpty {
                Faint("No team owns this project, so there is no capacity to set.", size: "t13")
            } else {
                Faint(
                    "Points each member takes on per sprint; a commit over the total needs a reason. 0 clears it.",
                    size: "t13")
                ForEach(members) { member in
                    HStack(spacing: AinkradSpacing.sm) {
                        ActorFigure(actor: .agent(member.agentID), store: store)
                        Text(verbatim: store.agent(member.agentID)?.name ?? "Agent \(member.agentID)").questFont("t13")
                        Faint(member.role.replacingOccurrences(of: "_", with: " "))
                        Spacer()
                        AinkradStepper(
                            value: Binding(
                                get: { capacities[member.agentID] ?? 0 }, set: { capacities[member.agentID] = $0 }),
                            in: 0...99)
                    }
                }
                HStack {
                    Faint(snapshot?.capacity.total.map { "Team: \($0) pts per sprint" } ?? "No capacity set")
                    Spacer()
                    AinkradButton(title: "Save capacity", style: .primary) {
                        let changed = members.filter { (capacities[$0.agentID] ?? 0) != ($0.capacity ?? 0) }
                        Task {
                            for member in changed {
                                let value = capacities[member.agentID] ?? 0
                                await store.setCapacity(
                                    value > 0 ? value : nil, agent: member.agentID, project: project.id)
                            }
                        }
                    }
                    .disabled(members.allSatisfy { (capacities[$0.agentID] ?? 0) == ($0.capacity ?? 0) })
                }
            }
        }
    }
}

/// "New project" in server mode: a project in the selected company on the server.
struct ServerNewProjectForm: View {
    let store: QuestServerStore
    let onClose: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @State private var name = ""
    @State private var key = ""
    @State private var kanban = false
    @State private var ownerApproves = true

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    /// What the server takes: 1–10 capitals and digits, starting with a letter.
    var keyIsValid: Bool { Self.isValidKey(key) }

    nonisolated static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, (1...10).contains(key.unicodeScalars.count) else { return false }
        let capitals = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return capitals.contains(first)
            && key.unicodeScalars.allSatisfy { capitals.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(
                title: "New project", subtitle: "In \(store.company?.name ?? "this company") on \(store.host)")
            AinkradFormRow(title: "Name") { AinkradTextField(text: $name, placeholder: "Mac Client") }
            AinkradFormRow(title: "Key", help: "Issue prefix: CIT for CIT-12. Capitals and digits.") {
                AinkradTextField(text: Binding(get: { key }, set: { key = $0.uppercased() }), placeholder: "AMC")
            }
            AinkradFormRow(title: "Mode") {
                AinkradSegmentedPicker(items: [false, true], selection: $kanban) { $0 ? "Kanban" : "Scrum" }
                    .fixedSize()
            }
            if !kanban {
                AinkradFormRow(title: "Sprint commit") {
                    AinkradSelect(items: [true, false], selection: $ownerApproves) {
                        $0 ? "You approve the commit" : "The product owner commits alone"
                    }
                }
            }
            HStack {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost, action: onClose)
                AinkradButton(title: "Create project", style: .primary) { create() }
                    .disabled(trimmed.isEmpty || !keyIsValid)
            }
        }
        .frame(width: skin.size.s420)
    }

    private func create() {
        guard !trimmed.isEmpty, keyIsValid else { return }
        let (name, key, kanban, owner) = (trimmed, key, kanban, ownerApproves)
        onClose()
        Task { _ = await store.createProject(name: name, key: key, kanban: kanban, ownerApproves: owner) }
    }
}
