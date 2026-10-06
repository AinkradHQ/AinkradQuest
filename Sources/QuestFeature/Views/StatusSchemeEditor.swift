import AinkradAppKit
import SwiftUI

/// Status-scheme editor hosted inside `ProjectSettingsSheet`. Unlike the rest
/// of that sheet, this applies through the store IMMEDIATELY on "Apply" — it
/// plans first via `SchemePlan.plan`, shows the plan's own `summary`, and
/// applies that SAME plan value, so the preview the user confirms can never
/// drift from what actually executes.
struct StatusSchemeEditor: View {
    @Environment(\.ainkradSkin) private var skin
    @Bindable var store: ProjectStore
    let project: Project
    /// The shell's reporting path, replacing this view's old `error` string.
    /// Scheme failures are transient events (a rejected plan, a stale apply),
    /// so a toast is the right shape; the STALE-REFUSAL branch below still
    /// re-seeds the rows, which is the part that must not be lost.
    let report: (String, AinkradStatus) -> Void
    /// Owned by `ProjectSettingsSheet`, not by this view, so the sheet can see
    /// its own confirm step. While a plan is pending the sheet must refuse to
    /// save underneath it — otherwise Return would discard a plan the user is
    /// looking at. One source of truth: this view is still the only writer.
    @Binding var pendingPlan: SchemePlan.Plan?

    @State private var drafts: [StatusDraft]
    @State private var newName = ""
    @State private var reassignments: [String: String] = [:]

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    init(
        store: ProjectStore, project: Project,
        report: @escaping (String, AinkradStatus) -> Void,
        pendingPlan: Binding<SchemePlan.Plan?>
    ) {
        self.store = store
        self.project = project
        self.report = report
        _pendingPlan = pendingPlan
        _drafts = State(initialValue: StatusDraft.drafts(from: project.statusScheme))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradSectionHeader(title: "Statuses")

            List {
                ForEach($drafts) { $draft in
                    HStack(spacing: AinkradSpacing.xs) {
                        AinkradTextField(text: $draft.name, placeholder: "Name")
                        AinkradSelect(
                            items: StatusCategory.allCases,
                            selection: $draft.category
                        ) { $0.rawValue }
                        AinkradSelect(
                            items: ProjectColorToken.allCases,
                            selection: $draft.color,
                            label: { $0.title },
                            swatch: {
                                $0.color(
                                    tokens: theme,
                                    statusColors: statusColors,
                                    skin: skin)
                            })
                        AinkradIconButton(systemName: "minus.circle") {
                            drafts.removeAll { $0.id == draft.id }
                        }
                        .help("Remove status")
                        .accessibilityLabel("Remove status")
                    }
                }
                .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }
            }
            // A deliberate fixed list height: the rows scroll inside the sheet
            // rather than growing it past the modal.
            .frame(height: skin.size.s180)
            .scrollContentBackground(.hidden)
            // While a plan is pending, the visible rows must stay in lockstep
            // with what the user confirmed — otherwise a post-review edit to
            // an already-reviewed row is silently discarded when Apply
            // re-seeds `drafts` from `plan.proposed`. Disabling every editable
            // control keeps Cancel/Apply as the only possible actions.
            //
            // DISABLED, never removed: each row's `AinkradSelect` opens a
            // floating panel keyed to its own `@State`, so unmounting a row to
            // express "not now" would kill an open dropdown mid-interaction.
            .disabled(pendingPlan != nil)

            HStack(spacing: AinkradSpacing.xs) {
                AinkradTextField(text: $newName, placeholder: "New status")
                    .disabled(pendingPlan != nil)
                AinkradButton(title: "Add", style: .secondary) {
                    drafts.append(StatusDraft.make(name: newName, existing: drafts))
                    newName = ""
                }
                .disabled(
                    pendingPlan != nil
                        || newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Any removed status that still holds items needs a destination
            // before the plan will validate.
            ForEach(occupiedRemovals, id: \.id) { status in
                AinkradFormRow(title: "Move \(status.name)'s \(itemCount(status.id)) item(s) to") {
                    AinkradSelect(items: destinations, selection: binding(for: status.id)) {
                        destinationLabel($0)
                    }
                }
            }
            .disabled(pendingPlan != nil)

            if let pendingPlan {
                VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                    Text("This will: \(pendingPlan.summary)").font(skin.font(AinkradFontToken(sizeKey: "t10")))
                    HStack {
                        AinkradButton(title: "Cancel", style: .secondary) {
                            self.pendingPlan = nil
                        }
                        AinkradButton(title: "Apply", style: .primary) {
                            apply(pendingPlan)
                        }
                    }
                }
                // Restores the `.defaultAction` the pre-kit `Button("Apply")`
                // carried. Mounted ONLY while a plan is pending, and the
                // sheet's own default-action Save is mounted only while one is
                // NOT — so exactly one default action exists at any moment and
                // Return can never mean two things.
                .background(defaultActionApply(pendingPlan))
            } else {
                AinkradButton(title: "Review changes", style: .secondary, action: review)
            }
        }
        .foregroundStyle(theme.foreground)
    }

    private func defaultActionApply(_ plan: SchemePlan.Plan) -> some View {
        HiddenShortcutButton(.defaultAction) { apply(plan) }
    }

    private var items: [WorkItem] { store.allItems(in: project.id) }

    /// The destinations a reassignment select offers: the sentinel `""`
    /// ("Choose…") plus every surviving draft id. `AinkradSelect` takes a
    /// NON-optional binding, so the "nothing picked yet" state has to be a real
    /// member of the item list rather than a nil selection — the sentinel keeps
    /// `SchemePlan`'s "no destination chosen" rejection reachable exactly as the
    /// old `Text("Choose…").tag("")` row did.
    private var destinations: [String] { [""] + drafts.map(\.id) }

    private func destinationLabel(_ id: String) -> String {
        id.isEmpty ? "Choose…" : (drafts.first { $0.id == id }?.name ?? id)
    }

    /// The scheme as it stands in the store RIGHT NOW, not the copy captured
    /// when this sheet opened. Within one sheet session, Apply can run more
    /// than once — a second plan must diff against what the first apply just
    /// wrote, or a revert of that first change is invisible (diffed against
    /// the pre-session original, it looks like a no-op) and a re-removal of
    /// an already-removed status gets proposed again. Falls back to the
    /// captured `project` only if the store somehow has nothing open (should
    /// not happen for an existing project mid-session).
    private var currentScheme: StatusScheme {
        store.openProject(project.id)?.project.statusScheme ?? project.statusScheme
    }

    private var occupiedRemovals: [Status] {
        let surviving = Set(drafts.map(\.id))
        return currentScheme.statuses
            .filter { !surviving.contains($0.id) && itemCount($0.id) > 0 }
    }

    private func itemCount(_ statusID: String) -> Int {
        items.filter { $0.statusID == statusID }.count
    }

    private func binding(for statusID: String) -> Binding<String> {
        Binding(
            get: { reassignments[statusID] ?? "" },
            set: { reassignments[statusID] = $0.isEmpty ? nil : $0 })
    }

    /// Plans first and shows the result. The user confirms the SAME plan value
    /// that will execute, so the preview cannot disagree with the outcome.
    private func review() {
        switch SchemeEditorState.plan(
            current: currentScheme, drafts: drafts,
            reassignments: reassignments, items: items)
        {
        case .invalid(let message):
            report(message, .danger)
            pendingPlan = nil
        case .valid(let plan) where plan.changesNothing:
            // Nothing to confirm and nothing to write. Offering a confirm step
            // whose only outcome is a "no changes" entry in the activity log
            // asks the user to approve a lie.
            report("No status changes to apply.", .neutral)
            pendingPlan = nil
        case .valid(let plan):
            pendingPlan = plan
        }
    }

    private func apply(_ plan: SchemePlan.Plan) {
        do {
            try store.applyScheme(plan, to: project.id, actor: .user)
            // Re-seed from what was actually just applied, and drop any
            // leftover pre-apply edit state, so a second Apply in this same
            // sheet session diffs against reality instead of stale rows.
            let next = SchemeEditorState.afterApply(plan)
            drafts = next.drafts
            reassignments = next.reassignments
            pendingPlan = nil
        } catch QuestError.schemeChangedUnderneath {
            let recovered = SchemeEditorState.afterStaleRefusal(currentScheme: currentScheme)
            drafts = recovered.drafts
            reassignments = recovered.reassignments
            pendingPlan = nil
            report(QuestError.schemeChangedUnderneath.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }
}
