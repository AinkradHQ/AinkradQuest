import AinkradAppKit
import SwiftUI

/// Wraps a freshly created project's attachment suggestions for presentation,
/// which needs `Identifiable` rather than a bare tuple. File-scope (no longer
/// private to the sidebar) because `NewProjectForm` owns creation now.
struct SuggestionSheetState: Identifiable {
    let projectID: UUID
    let suggestions: [AttachmentSuggestion]
    var id: UUID { projectID }
}

/// Opens the shell's single new-project modal. The sidebar's "New project"
/// button, the command menu's `.newProject`, the ⌘N chord and the header's "+"
/// (with no project selected) all have to reach ONE presentation, and
/// `QuestSidebar.init` is a fixed contract with no room for another binding — so
/// the shell publishes the trigger instead.
///
/// A named `Equatable` wrapper rather than a bare `() -> Void`: `@Entry` warns
/// that storing a closure invalidates every dependent on each update, because
/// closures cannot be compared. The shell builds a fresh closure on every body
/// pass, so that would churn the sidebar subtree. All instances compare equal
/// because the action's behaviour never varies — only its captured `self` does.
struct QuestNewProjectAction: Equatable {
    /// The default is deliberately loud, matching `QuestShellContent.activate`'s
    /// unhandled-binding trap: an inert "New project" button produces no build
    /// error and no warning, so a sidebar mounted outside `QuestShellContent`
    /// must fail visibly in debug rather than silently doing nothing.
    /// Computed, not a `static let`: the type holds a closure and so is not
    /// `Sendable`, which makes a stored global a Swift 6 concurrency error.
    static var unwired: QuestNewProjectAction {
        QuestNewProjectAction {
            assertionFailure(
                "QuestSidebar was mounted without \\.questNewProject injected — the New project button is inert")
        }
    }

    private let perform: () -> Void

    init(_ perform: @escaping () -> Void) { self.perform = perform }

    func callAsFunction() { perform() }

    static func == (lhs: QuestNewProjectAction, rhs: QuestNewProjectAction) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var questNewProject: QuestNewProjectAction = .unwired
}

struct QuestSidebar: View {
    @Bindable var store: ProjectStore
    let documents: PluginDocumentStore
    @Binding var selection: UUID?
    @Binding var surface: QuestSurface
    @Binding var settingsProject: UUID?
    let report: (String, AinkradStatus) -> Void

    @State private var filter: ProjectStateFilter = .active
    @Environment(\.questNewProject) private var newProject

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            // Today stays in the sidebar: it is the cross-project entry point,
            // not a surface of the selected project, so the header's switcher
            // (which is project-scoped) is the wrong home for it.
            AinkradListRow(
                isSelected: surface == .today,
                onTap: {
                    surface = .today
                    selection = nil
                },
                leading: { AinkradIconGlyph(systemName: QuestSurface.today.icon) },
                title: QuestSurface.today.title,
                trailing: { EmptyView() })

            HStack {
                AinkradSectionHeader(title: "Projects")
                Spacer()
                AinkradSelect(items: ProjectStateFilter.allCases, selection: $filter) { $0.title }
                    .frame(maxWidth: 104)
            }

            ScrollView {
                LazyVStack(spacing: AinkradSpacing.xs) {
                    ForEach(visibleProjects) { project in
                        AinkradListRow(
                            isSelected: selection == project.id,
                            onTap: { selection = project.id },
                            leading: { AinkradIconGlyph(systemName: project.icon) },
                            title: project.name,
                            trailing: { EmptyView() }
                        )
                        .ainkradContextMenu(menu(for: project))
                    }
                }
            }
            // Both handlers must test against the NEW value. `visibleProjects`
            // is computed from the PREVIOUS body pass's state, so closing over
            // it tested the pre-change list and left, say, a paused project
            // selected and rendered in the detail pane after All → Active.
            .onChange(of: filter) { _, newFilter in
                clearSelectionIfHidden(from: newFilter.apply(to: store.projects))
            }
            .onChange(of: store.projects) { _, newProjects in
                clearSelectionIfHidden(from: filter.apply(to: newProjects))
            }

            Spacer(minLength: 0)

            AinkradButton(title: "New project", style: .secondary, icon: "plus") {
                newProject()
            }
        }
        .padding(AinkradSpacing.md)
    }

    private var visibleProjects: [ProjectSummary] { filter.apply(to: store.projects) }

    private func menu(for project: ProjectSummary) -> [AinkradMenuItem] {
        [
            AinkradMenuItem(title: "Settings…", systemName: "gearshape") {
                settingsProject = project.id
            },
            AinkradMenuItem(title: "Active", systemName: "play.circle") {
                setState(project.id, .active)
            },
            AinkradMenuItem(title: "Pause", systemName: "pause.circle") {
                setState(project.id, .paused)
            },
            AinkradMenuItem(title: "Archive", systemName: "archivebox") {
                setState(project.id, .archived)
            },
            AinkradMenuItem(title: "Move to Trash", systemName: "trash", isDestructive: true) {
                trash(project.id)
            },
        ]
    }

    private func setState(_ id: UUID, _ state: ProjectState) {
        do {
            try store.setState(id, state: state, actor: .user)
            report("Moved to \(state.rawValue)", .success)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    private func trash(_ id: UUID) {
        do {
            try store.deleteProject(id, actor: .user)
            if selection == id { selection = nil }
            report("Moved to Trash", .success)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    /// If the selected project falls outside the current filter — because the
    /// filter changed or the project's state moved it out — the detail
    /// surfaces must not keep showing a project the sidebar no longer lists.
    private func clearSelectionIfHidden(from visibleProjects: [ProjectSummary]) {
        if let selection, !visibleProjects.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }
}

/// Project creation, moved out of the sidebar footer into a modal so the
/// sidebar is a list and nothing else.
struct NewProjectForm: View {
    @Bindable var store: ProjectStore
    let documents: PluginDocumentStore
    let report: (String, AinkradStatus) -> Void
    /// Hands the shell the new project AND its resolved attachment suggestions.
    /// The suggestions cannot be presented from here: this form is itself the
    /// content of the shell's `.ainkradModal`, and `AinkradModalModifier` is an
    /// `overlay { if isPresented … }`, so the moment the shell dismisses the
    /// new-project modal this whole subtree — including any `@State` holding a
    /// suggestion list — is torn down before a nested modal could render. Only
    /// a view that outlives the form can present them.
    let onCreated: (UUID, [AttachmentSuggestion]) -> Void

    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "New project")
            AinkradFormRow(title: "Name") {
                AinkradTextField(text: $name, placeholder: "Project name")
            }
            HStack {
                Spacer()
                // Disabled rather than silently refusing: `create()`'s empty
                // guard used to `return` with no toast and no visible state, so
                // a click on an empty field looked like a broken button.
                AinkradButton(title: "Create", style: .primary) { create() }
                    .disabled(trimmed.isEmpty)
            }
        }
        // Return creates, as the pre-M5 sidebar footer's `.onSubmit(create)`
        // did. Both paths are needed: `.onSubmit` fires from the focused text
        // field, the hidden `.defaultAction` button covers Return with nothing
        // focused — `AinkradButton` carries no keyboard shortcut of its own, so
        // migrating off `Button` drops `.defaultAction` silently.
        .onSubmit(create)
        .background(defaultActionCreate)
        // `.ainkradModal` already pads its content with `AinkradSpacing.lg`;
        // repeating it here would double the inset. 420 is inside the
        // modifier's 448pt content budget (480 cap less that padding).
        .frame(width: 420)
    }

    /// Return-with-nothing-focused creates, exactly as the pre-kit
    /// `Button("Create").keyboardShortcut(.defaultAction)` did. Disabled on an
    /// empty name so Return matches the visibly disabled Create button.
    private var defaultActionCreate: some View {
        HiddenShortcutButton(.defaultAction) { create() }
            .disabled(trimmed.isEmpty)
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        let name = trimmed
        // The store write happens FIRST and unconditionally: the project exists
        // and is persisted before anything touches the filesystem, so nothing
        // below can prevent or undo creation.
        let project = store.createProject(name: name, kind: .software, actor: .user)
        self.name = ""
        report("Created \(project.name)", .success)

        // Suggestions are resolved AFTER the project exists and never gate it.
        // With no root granted — the normal case — `build` returns empty and the
        // shell selects the project and shows no picker. Each root is scanned
        // inside its own balanced `FolderBookmark.withAccess` scope; no scoped
        // resource survives this call.
        let suggestions = AttachmentSuggestions.build(projectName: name, in: documents)
        onCreated(project.id, suggestions)
    }
}
