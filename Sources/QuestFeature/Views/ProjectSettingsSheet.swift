import AinkradAppKit
import SwiftUI

/// The theme lookup for `ProjectColorToken` (declared in `Models/`, so the MCP
/// layer can validate against the same closed set without importing a view).
///
/// It takes the DERIVED token structs rather than the `HostTheme` object,
/// because those are what the host actually injects into the SwiftUI
/// environment (`\.ainkradTheme`, `\.ainkradStatusColors`). Taking `HostTheme`
/// forced every view that wanted a swatch to have the class threaded down to
/// it by hand.
extension ProjectColorToken {
    func color(tokens: HostThemeTokens, statusColors: AinkradStatusColors) -> Color {
        switch self {
        case .accentPrimary: tokens.accentPrimary
        case .accentSecondary: tokens.accentSecondary
        case .success: statusColors.success
        case .warning: statusColors.warning
        case .danger: statusColors.danger
        case .muted: tokens.foreground.opacity(0.4)
        }
    }
}

/// Name, summary, icon and colour. Draft-until-Save, like ItemEditor.
///
/// Presented through `.ainkradModal`, which is an OVERLAY modifier and injects
/// no `DismissAction` — so this view must never reach for
/// `@Environment(\.dismiss)`. Closing is the presenter's job, requested through
/// `onClose`; a `dismiss()` here would compile and do nothing.
struct ProjectSettingsSheet: View {
    @Bindable var store: ProjectStore
    let registry: ConnectionRegistry
    let report: (String, AinkradStatus) -> Void
    /// Asks the presenter to take this sheet down. Called ONLY as the last
    /// statement of a path, because it unmounts this subtree — a `@State`
    /// write after it would land in a view that no longer exists.
    let onClose: () -> Void

    @State private var draft: Project
    @State private var colorToken: ProjectColorToken
    /// The scheme editor's confirm step, hoisted here so this sheet can see it.
    /// `StatusSchemeEditor` remains its only writer; this sheet only READS it,
    /// to refuse to save while a plan is awaiting confirmation.
    @State private var pendingSchemePlan: SchemePlan.Plan?

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    init(
        store: ProjectStore, registry: ConnectionRegistry, project: Project,
        report: @escaping (String, AinkradStatus) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.registry = registry
        self.report = report
        self.onClose = onClose
        _draft = State(initialValue: project)
        _colorToken = State(initialValue: ProjectColorToken.resolve(project.colorToken))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "Project settings", subtitle: draft.name)

            // `.ainkradModal` is an overlay scoped to the presenter's bounds
            // with NO intrinsic scrolling — unlike the `.sheet` it replaced,
            // which sized its own window. Header + fields + the scheme editor
            // (a 180pt list, an add row, one row per occupied removal, and the
            // confirm block) can easily exceed the shell's height, and without
            // this cap the button row below would be pushed out of reach with
            // no way to scroll back to it.
            ScrollView {
                VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    fields
                    // Reads the STORE's live project, not `draft`: binding a
                    // connection or attaching a repo commits immediately
                    // through `ProjectStore` (like `StatusSchemeEditor`'s
                    // Apply), so this must reflect what was just written
                    // rather than the snapshot captured at `init`.
                    ProjectConnectionSection(
                        store: store, registry: registry,
                        project: store.openProject(draft.id)?.project ?? draft,
                        report: report)
                    StatusSchemeEditor(
                        store: store, project: draft, report: report,
                        pendingPlan: $pendingSchemePlan)
                }
                .padding(.trailing, AinkradSpacing.xs)
            }
            // A deliberate cap, matching `ItemEditor`'s, so the buttons below
            // always stay on screen.
            .frame(maxHeight: 420)

            HStack {
                AinkradButton(title: "Cancel", style: .secondary, action: onClose)
                Spacer()
                AinkradButton(title: "Save", style: .primary, action: save)
            }
        }
        // A deliberate fixed sheet width, so the form does not reflow with the
        // pane behind it. Inside `.ainkradModal`'s 480pt cap.
        .frame(width: 420)
        .foregroundStyle(theme.foreground)
        .onSubmit(save)
        // Mounted only while NO scheme plan is pending; `StatusSchemeEditor`
        // mounts its own default-action Apply while one IS. Exactly one
        // default action exists at any moment, so Return is never ambiguous.
        .background(pendingSchemePlan == nil ? defaultActionSave : nil)
    }

    /// Return-with-nothing-focused commits, exactly as the pre-kit
    /// `Button("Save").keyboardShortcut(.defaultAction)` did.
    @ViewBuilder private var defaultActionSave: some View {
        Button("") { save() }
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var fields: some View {
        AinkradFormRow(title: "Name") {
            AinkradTextField(text: $draft.name, placeholder: "Name")
        }
        AinkradFormRow(title: "Summary") {
            AinkradTextField(text: $draft.summaryText, placeholder: "Summary")
        }
        AinkradFormRow(title: "Icon", help: "An SF Symbol name") {
            AinkradTextField(text: $draft.icon, placeholder: "SF Symbol")
        }
        AinkradFormRow(title: "Colour") {
            AinkradSelect(
                items: ProjectColorToken.allCases, selection: $colorToken,
                label: { $0.title },
                swatch: { $0.color(tokens: theme, statusColors: statusColors) })
        }
        // The kind picker only relabels the project; it does NOT change an
        // existing project's status scheme. Schemes ARE editable now, via
        // the `StatusSchemeEditor` below — this picker still does not
        // retroactively switch one.
        AinkradFormRow(title: "Kind") {
            AinkradSegmentedPicker(
                items: [ProjectKind.software, .general],
                selection: $draft.kind
            ) { $0.settingsTitle }
        }
    }

    private func save() {
        // A pending scheme plan is a confirm step the user is looking at.
        // Saving now would close the sheet and abandon it, so Return (or the
        // Save button) refuses instead of silently discarding the plan.
        guard pendingSchemePlan == nil else {
            report("Apply or cancel the status changes first.", .warning)
            return
        }
        let name: String
        switch ProjectSettingsValidation.validate(name: draft.name) {
        case .invalid(let message):
            report(message, .danger)
            return
        case .valid(let validated):
            name = validated
        }
        // This sheet's `draft` is an init-time snapshot, and things other than
        // this sheet write to a project while it is open: `StatusSchemeEditor`
        // applies scheme changes immediately on "Apply", `ProjectConnectionSection`
        // commits binds/attaches immediately through `store.overlay`, and —
        // less obviously, but just as real — an MCP caller (e.g. `add_link`)
        // can add a link or change `state` at any moment while this sheet sits
        // open, with no view here to reflect it. A live bug shipped from
        // exactly this: `save()` used to write the WHOLE stale `draft` back,
        // silently reverting whatever any of those had just done.
        //
        // The fix is structural rather than enumerating fields to refresh:
        // start from the LIVE document and apply only what THIS sheet actually
        // owns — Name, Summary, Icon, Colour, Kind, the fields its own
        // controls edit. Everything else (`links`, `state`, `archivedAt`,
        // `statusScheme`, and anything added to `Project` later) is read from
        // the live copy and never carried on `draft`, so it cannot be
        // reverted by this save no matter what changed elsewhere while the
        // sheet was open.
        guard let live = store.openProject(draft.id)?.project else {
            report(QuestError.projectNotFound(draft.id).message, .danger)
            return
        }
        let toSave = ProjectSettingsSheetWrite.apply(
            draft: draft, colorToken: colorToken,
            validatedName: name, to: live)
        do {
            try store.updateProject(toSave, actor: .user)
            // LAST statement on this path — everything after it would run in an
            // unmounted subtree.
            onClose()
        } catch let failure as QuestError {
            report(failure.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }
}

extension ProjectKind {
    /// The label the settings picker shows. Local to this file because it is a
    /// UI string, not part of the persisted vocabulary.
    fileprivate var settingsTitle: String {
        switch self {
        case .software: "Software"
        case .general: "General"
        }
    }
}
