import AinkradAppKit
import SwiftUI

/// One row. A `struct` per row, identified by `item.id` in `ListSurface`'s `ForEach`,
/// is how the in-progress edit text below stays scoped to that row: SwiftUI
/// keys `@State` to the view's identity, not to the surface, so re-sorting or
/// re-filtering never lets one row's typing leak into another. The title field
/// is seeded from `item.title` when the editor appears, so a store-driven
/// re-render mid-edit does not clobber what the user is typing; it commits
/// explicitly on submit or on losing focus, never on every keystroke.
struct ListRow: View {
    @Environment(\.ainkradSkin) private var skin
    @Bindable var store: ProjectStore
    let document: ProjectDocument
    let item: WorkItem
    let indent: Int
    let isRenaming: Bool
    let beginRename: () -> Void
    let endRename: () -> Void
    let openEditor: () -> Void
    let report: (String, AinkradStatus) -> Void

    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack(spacing: AinkradSpacing.xs) {
            Spacer().frame(width: CGFloat(max(indent, 0)) * AinkradSpacing.lg)
            titleArea
                .frame(maxWidth: .infinity, alignment: .leading)
            // Deliberately SIBLINGS of `titleArea`, not children of either of
            // its branches, and at a fixed position in this HStack. Inside the
            // rename branch, clicking the select would blur the field, end
            // rename, and unmount the select in the very update its floating
            // panel opened — the panel is keyed to the select's own `@State`,
            // so it would never appear. Hoisted here, the branch swap changes
            // only this HStack's second child; the select and the details
            // button keep their structural identity and stay mounted through
            // the whole open -> choose -> close cycle. Keeping them out of
            // `AinkradListRow`'s trailing slot also keeps them clear of that
            // row's whole-row `onTapGesture`.
            statusSelect
            AinkradIconButton(systemName: "square.and.pencil", action: openEditor)
                .help("Details")
                .accessibilityLabel("Details")
        }
        .ainkradContextMenu([
            AinkradMenuItem(title: "Rename", systemName: "pencil", action: beginRename),
            AinkradMenuItem(title: "Details", systemName: "square.and.pencil", action: openEditor),
            AinkradMenuItem(
                title: "Delete", systemName: "trash", isDestructive: true,
                action: delete),
        ])
    }

    /// The ONLY part of the row that swaps between display and rename. The
    /// status select and the details button are siblings of this, above.
    @ViewBuilder private var titleArea: some View {
        if isRenaming {
            // Deliberately raw SwiftUI. `AinkradListRow` renders its title as
            // static `Text`, and `AinkradTextField` exposes no focus binding,
            // so the M3 inline title edit cannot be expressed through either.
            // Rather than drop the behaviour to fit a component, the editing
            // state is a hand-built row that matches the kit row's metrics.
            HStack(spacing: AinkradSpacing.md) {
                AinkradIconGlyph(systemName: itemGlyph(for: item.type))
                TextField("Title", text: $title)  // design-lint: allow raw-control kit gap: AinkradTextField focus control
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.foreground)
                    .focused($titleFocused)
                    .onSubmit { finishRename() }
                    .onChange(of: titleFocused) { wasFocused, isFocused in
                        if wasFocused, !isFocused { finishRename() }
                    }
            }
            .padding(.horizontal, AinkradSpacing.md)
            .padding(.vertical, AinkradSpacing.sm)
            // Seeded and focused on appear, not in an `onChange` of the flag:
            // the field must exist before it can take focus.
            .onAppear {
                title = item.title
                titleFocused = true
            }
        } else {
            AinkradListRow(
                onTap: beginRename,
                leading: { AinkradIconGlyph(systemName: itemGlyph(for: item.type)) },
                title: item.title,
                subtitle: item.type.rawValue.capitalized,
                trailing: {
                    HStack(spacing: AinkradSpacing.xs) {
                        ForEach(item.labels, id: \.self) { AinkradChip(label: $0) }
                    }
                })
        }
    }

    private var statusSelect: some View {
        AinkradSelect(
            items: document.project.statusScheme.statuses.map(\.id),
            selection: statusBinding
        ) { id in
            document.project.statusScheme.statuses.first { $0.id == id }?.name ?? id
        }
        .frame(width: skin.size.s140)
    }

    /// Commit first, then tear the field down — the reverse order would write
    /// into a subtree this update is about to unmount.
    private func finishRename() {
        commitTitle()
        endRename()
    }

    /// Reports failure instead of swallowing it: a delete refused by the store
    /// (e.g. a rule violation) must not look like it worked. On success the row
    /// disappears with the item, so there is nothing to clear.
    private func delete() {
        do {
            try store.deleteItem(item.id, actor: .user)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    private var statusBinding: Binding<String> {
        Binding(
            get: { item.statusID },
            set: { newStatusID in
                guard newStatusID != item.statusID else { return }
                do {
                    try withAnimation(AinkradMotion.present) {
                        try store.setStatus(item.id, statusID: newStatusID, actor: .user)
                    }
                } catch {
                    report(error.localizedDescription, .danger)
                }
            })
    }

    private func commitTitle() {
        guard let normalized = InlineEdit.normalizedTitle(title) else {
            title = item.title
            report("Title cannot be empty.", .warning)
            return
        }
        guard normalized != item.title else { return }
        var updated = item
        updated.title = normalized
        do {
            try store.updateItem(updated, actor: .user)
        } catch {
            title = item.title
            report(error.localizedDescription, .danger)
        }
    }
}
