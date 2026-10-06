import AinkradAppKit
import SwiftUI

/// The other half of soft delete. Without this view, "restorable" is a claim
/// with no interface behind it — and the MCP deletes are classified on the
/// promise that a person can undo them.
struct TrashView: View {
    @Bindable var store: ProjectStore
    /// Every failure goes to the shell's single toast path; this view owns no
    /// error string of its own.
    let report: (String, AinkradStatus) -> Void
    /// `.ainkradModal` injects no `DismissAction`, so the presenter — not this
    /// view — owns closing it.
    let onClose: () -> Void

    /// What is awaiting an irreversible purge. One piece of state for all three
    /// destructive paths, so two confirm dialogs can never be up at once —
    /// `.ainkradConfirmDialog` scopes its scrim to the view it modifies, and
    /// stacked scrims over one 440pt panel would leave the user unable to tell
    /// which question they are answering.
    @State private var pendingPurge: PendingPurge?

    enum PendingPurge: Equatable {
        case project(UUID)
        case item(UUID)
        case everything
    }

    var body: some View {
        // Computed once per render rather than as a computed property
        // re-flatMapped/filtered over every project's items on each access
        // (previously read twice for emptiness and again in the ForEach).
        let itemEntries = itemEntries
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            header
            if store.trashedProjects.isEmpty && itemEntries.isEmpty {
                AinkradEmptyState(
                    icon: "trash", title: "Trash is empty",
                    message: "Deleted projects and items appear here until you restore or purge them."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.md) {
                        if !store.trashedProjects.isEmpty {
                            AinkradSectionFrame(title: "Projects") {
                                LazyVStack(spacing: AinkradSpacing.xs) {
                                    ForEach(store.trashedProjects) { project in
                                        projectRow(project)
                                    }
                                }
                            }
                        }
                        if !itemEntries.isEmpty {
                            AinkradSectionFrame(title: "Items") {
                                LazyVStack(spacing: AinkradSpacing.xs) {
                                    ForEach(itemEntries) { entry in
                                        itemRow(entry)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // No padding of its own: `AinkradModalModifier` already applies
        // `.padding(AinkradSpacing.lg)` to its content, so a second one here
        // would double the inset.
        //
        // A deliberate fixed size so the trash does not reflow with the pane
        // behind it. The modifier pads BEFORE it caps (`.padding(.lg)` then
        // `.frame(maxWidth: 480)`), so the content budget is 480 - 2*16 = 448
        // and anything wider has its panel border drawn over the content.
        .frame(width: 440, height: 440)
        // Attached at THIS view's root, not inside a row or the scroll view:
        // the kit dims and centres the dialog within the view it modifies, so
        // an inner attachment would scope the scrim to that inner box.
        .ainkradConfirmDialog(
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }),
            title: "Delete permanently?",
            // Names the project: this is the one irreversible
            // action in the app, and "this project" does not
            // tell you WHICH row's Delete you pressed.
            message: purgeMessage,
            confirmTitle: confirmTitle,
            isDestructive: true
        ) {
            switch pendingPurge {
            case .project(let id): purgeProject(id)
            case .item(let id): purgeItem(id)
            case .everything: emptyTrash()
            case nil: break
            }
            pendingPurge = nil
        }
    }

    private var confirmTitle: String {
        pendingPurge == .everything ? "Delete all" : "Delete"
    }

    /// Falls back to the unnamed wording only if the row has vanished from
    /// under the dialog, which the confirm path never expects.
    private var purgeMessage: String {
        switch pendingPurge {
        case .project(let id):
            guard let name = store.trashedProjects.first(where: { $0.id == id })?.name else {
                return "This project and everything in it will be gone for good. This cannot be undone."
            }
            return "“\(name)” and everything in it will be gone for good. This cannot be undone."
        case .item(let id):
            guard let entry = itemEntries.first(where: { $0.id == id }) else {
                return "This item will be gone for good. This cannot be undone."
            }
            // Says the part that is not on screen: the row shows one title, but
            // a trashed epic takes its whole subtree with it.
            return "“\(entry.label)” and anything filed under it will be gone for good. "
                + "This cannot be undone."
        case .everything:
            return TrashPurge.confirmMessage(purgeEverythingPlan)
        case nil:
            return ""
        }
    }

    /// Computed for the DIALOG's wording from the same inputs the store will
    /// re-plan from, so the counts the user agrees to are the counts that get
    /// destroyed.
    private var purgeEverythingPlan: TrashPurgePlan {
        TrashPurge.plan(
            liveProjectIDs: store.projects.map(\.id),
            trashedProjectIDs: store.trashedProjects.map(\.id),
            trashedItemIDs: { store.allItems(in: $0).filter(\.isDeleted).map(\.id) })
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(
                title: "Trash",
                subtitle: "Restore an item, or delete it permanently."
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            // `.danger`, not `.primary`, and so deliberately WITHOUT a
            // `.defaultAction`: nothing here should be reachable by pressing
            // Return. Hidden entirely when there is nothing to empty, rather
            // than disabled — a dimmed button still invites a click.
            if !purgeEverythingPlan.isEmpty {
                AinkradButton(title: "Empty trash", style: .danger) {
                    pendingPurge = .everything
                }
            }
            AinkradIconButton(systemName: "xmark", action: onClose)
                .help("Close")
                .accessibilityLabel("Close")
        }
    }

    private func projectRow(_ project: ProjectSummary) -> some View {
        AinkradListRow(
            leading: { AinkradIconGlyph(systemName: project.icon) },
            title: project.name,
            subtitle: "Project",
            trailing: {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradButton(title: "Restore", style: .secondary) {
                        restoreProject(project.id)
                    }
                    // Opens the confirm dialog rather than purging:
                    // the destructive half never fires from one tap.
                    AinkradButton(title: "Delete", style: .danger) {
                        pendingPurge = .project(project.id)
                    }
                }
            })
    }

    private func itemRow(_ entry: TrashedItemEntry) -> some View {
        AinkradListRow(
            leading: { AinkradIconGlyph(systemName: "checklist") },
            title: entry.label,
            subtitle: "Work item",
            trailing: {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradButton(title: "Restore", style: .secondary) {
                        restoreItem(entry.id)
                    }
                    // Matches the project row exactly: the confirm
                    // dialog is the only route to the destructive
                    // half, never a single tap.
                    AinkradButton(title: "Delete", style: .danger) {
                        pendingPurge = .item(entry.id)
                    }
                }
            })
    }

    /// Items whose project is live AND items whose project is itself trashed
    /// — both must be reachable here, or restoring an item can require first
    /// restoring its project.
    private var itemEntries: [TrashedItemEntry] {
        TrashListing.itemEntries(
            projects: store.projects, trashedProjects: store.trashedProjects,
            allItems: store.allItems(in:))
    }

    /// Restore is the reversible half, so it confirms with a `.success` toast
    /// rather than a dialog.
    private func restoreProject(_ id: UUID) {
        let name = store.trashedProjects.first { $0.id == id }?.name
        run {
            try store.restoreProject(id, actor: .user)
        } ok: {
            report(name.map { "Restored \($0)." } ?? "Restored the project.", .success)
        }
    }

    private func restoreItem(_ id: UUID) {
        run {
            try store.restoreItem(id, actor: .user)
        } ok: {
            report("Restored the item.", .success)
        }
    }

    /// Irreversible, and only ever reached from the confirm dialog above.
    private func purgeProject(_ id: UUID) {
        let name = store.trashedProjects.first { $0.id == id }?.name
        run {
            try store.purgeProject(id)
        } ok: {
            report(name.map { "Deleted \($0) permanently." } ?? "Deleted permanently.", .neutral)
        }
    }

    private func purgeItem(_ id: UUID) {
        run {
            try store.purgeItem(id, actor: .user)
        } ok: {
            report("Deleted permanently.", .neutral)
        }
    }

    /// Reports through the same toast path whether it fully succeeded or not:
    /// `emptyTrash` does not throw, because a partial empty is a real outcome
    /// that has to be described rather than swallowed.
    private func emptyTrash() {
        let outcome = store.emptyTrash(actor: .user)
        report(outcome.message, outcome.failures.isEmpty ? .neutral : .danger)
    }

    private func run(_ work: () throws -> Void, ok: () -> Void) {
        do {
            try work()
            ok()
        } catch let failure as QuestError {
            report(failure.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }
}
