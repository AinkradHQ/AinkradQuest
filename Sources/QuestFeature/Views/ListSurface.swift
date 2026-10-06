import AinkradAppKit
import SwiftUI

/// The rule an inline row edit must satisfy. Pure so it is testable without a
/// view, and shared with nothing else — an empty title from an inline field is
/// the same mistake `ProjectSidebar.create()` and the settings sheet already
/// guard against, so a row must not be able to lose its name either.
enum InlineEdit {
    static func normalizedTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// SF Symbol per work-item type. File-private so it stays beside the rows that
/// use it rather than becoming a second, drifting copy of a shared table.
private func itemGlyph(for type: WorkItemType) -> String {
    switch type {
    case .epic: "flag"
    case .bug: "ant"
    case .story: "book"
    case .chore: "wrench"
    case .spike: "magnifyingglass"
    case .task: "circle"
    }
}

struct ListSurface: View {
    @Bindable var store: ProjectStore
    let document: ProjectDocument
    /// Owned by the shell's header. This surface has NO search box of its own:
    /// a second field would give the user two places to type one query, and
    /// the header's is the one the ⌘F chord focuses.
    @Binding var searchText: String
    let report: (String, AinkradStatus) -> Void

    @State private var filter = ItemFilter()
    @State private var sort: ItemSort = .manual
    @State private var editing: WorkItem?
    @Environment(\.questSurfaceModal) private var surfaceModal
    /// Which row is currently in inline title edit. Held here, not per row, so
    /// only one field is live at a time; the in-progress TEXT still lives in
    /// the row (see `ListRow`), so it can never leak between rows.
    @State private var renaming: UUID?

    /// One epic and the descendants visible beneath it.
    private struct Group {
        let epic: WorkItem
        let items: [WorkItem]
    }

    var body: some View {
        let visible = tree(activeFilter)
        // Classified against the SAME tree with no filter applied, so
        // "this project has no items" and "your filter hid them all" are
        // distinguished by the filter and not by an unrelated count.
        let reason = EmptyReason.classify(
            totalCount: total(tree(ItemFilter())),
            visibleCount: total(visible),
            hasProject: true)
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            controls
            if reason == .notEmpty {
                list(visible)
            } else {
                AinkradEmptyState(
                    icon: reason.icon, title: reason.title,
                    message: reason.message,
                    actionTitle: reason.actionTitle,
                    action: action(for: reason)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(AinkradSpacing.md)
        // `ItemEditor` no longer reaches for `@Environment(\.dismiss)` — an
        // overlay-based `.ainkradModal` injects none — so this presenter owns
        // closing it, via `onClose`. Keyed by `.id(item.id)` because the modal
        // content view is REUSED across a change of `editing`: without the id,
        // tapping a second row would keep the first item's `@State draft`.
        .ainkradModal(
            isPresented: Binding(
                get: { editing != nil },
                set: { if !$0 { editing = nil } })
        ) {
            if let item = editing {
                ItemEditor(
                    store: store, document: document,
                    // Re-resolved so an edit made elsewhere since the row
                    // was tapped is not overwritten by a stale snapshot.
                    item: document.items.first { $0.id == item.id } ?? item,
                    report: report,
                    onClose: { editing = nil }
                )
                .id(item.id)
            }
        }
        // The editor is an overlay scoped to this pane, so the header above it
        // stays live unless the shell is told to switch itself off.
        .onChange(of: editing != nil) { _, isOpen in surfaceModal(isOpen) }
    }

    // MARK: - Query

    /// The header's query is merged in here rather than stored, so the shell
    /// stays the single owner of the search string.
    private var activeFilter: ItemFilter {
        var merged = filter
        merged.text = searchText
        return merged
    }

    private func tree(_ query: ItemFilter) -> [Group] {
        let scheme = document.project.statusScheme
        return ItemQuery.apply(
            query, sort: sort,
            to: document.items.filter { $0.type == .epic },
            scheme: scheme
        )
        .map { epic in
            Group(
                epic: epic,
                items: ItemQuery.apply(
                    query, sort: sort,
                    to: HierarchyRules.descendants(
                        of: epic.id,
                        in: document.items),
                    scheme: scheme))
        }
    }

    private func total(_ groups: [Group]) -> Int {
        groups.count + groups.reduce(0) { $0 + $1.items.count }
    }

    // MARK: - Controls

    private static let sorts: [ItemSort] = [.manual, .priority, .dueDate, .updated, .title]

    private static func sortLabel(_ sort: ItemSort) -> String {
        switch sort {
        case .manual: "Manual"
        case .priority: "Priority"
        case .dueDate: "Due"
        case .updated: "Updated"
        case .title: "Title"
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradSegmentedPicker(
                    items: Self.sorts, selection: $sort,
                    label: Self.sortLabel)
                AinkradCheckbox(isOn: $filter.includeDone, label: "Show done")
                Spacer(minLength: AinkradSpacing.sm)
            }
            if !chips.isEmpty {
                // Every narrowing currently in force, each removable on its
                // own — the old surface could only show you the text box.
                HStack(spacing: AinkradSpacing.xs) {
                    ForEach(chips, id: \.label) { chip in
                        AinkradChip(
                            label: chip.label, systemName: chip.icon,
                            onRemove: chip.clear)
                    }
                }
            }
        }
    }

    private struct FilterChip {
        let label: String
        let icon: String
        let clear: () -> Void
    }

    private var chips: [FilterChip] {
        var result: [FilterChip] = []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result.append(
                FilterChip(
                    label: "“\(query)”", icon: "magnifyingglass",
                    clear: { searchText = "" }))
        }
        for type in filter.types.sorted(by: { $0.rawValue < $1.rawValue }) {
            result.append(
                FilterChip(
                    label: type.rawValue.capitalized,
                    icon: itemGlyph(for: type),
                    clear: { filter.types.remove(type) }))
        }
        for label in filter.labels.sorted() {
            result.append(
                FilterChip(
                    label: "#\(label)", icon: "tag",
                    clear: { filter.labels.remove(label) }))
        }
        if !filter.includeDone {
            result.append(
                FilterChip(
                    label: "Done hidden", icon: "checkmark.circle",
                    clear: { filter.includeDone = true }))
        }
        return result
    }

    // MARK: - Rows

    private func list(_ groups: [Group]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AinkradSpacing.md) {
                ForEach(groups, id: \.epic.id) { group in
                    VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                        header(group.epic)
                        ForEach(group.items) { item in
                            ListRow(
                                store: store, document: document, item: item,
                                indent: HierarchyRules.depth(
                                    of: item.id,
                                    in: document.items) - 2,
                                isRenaming: renaming == item.id,
                                beginRename: { renaming = item.id },
                                endRename: { if renaming == item.id { renaming = nil } },
                                openEditor: { editing = item },
                                report: report)
                        }
                    }
                }
            }
            .animation(AinkradMotion.present, value: groups.flatMap { $0.items.map(\.id) })
        }
    }

    private func header(_ epic: WorkItem) -> some View {
        let progress = EpicProgress.rollup(
            epicID: epic.id, in: document.items,
            scheme: document.project.statusScheme)
        return AinkradSectionHeader(
            title: epic.title,
            subtitle: "\(progress.done)/\(progress.total) done")
    }

    // MARK: - Empty-state actions

    /// `nil` for `.notEmpty`/`.noProjectSelected`, which carry no action title —
    /// handing `AinkradEmptyState` an action with no title renders no button.
    ///
    /// `.noItems` also yields `nil` when the project's scheme has no status to
    /// file a new item under. Offering "Add an item" there would guarantee a
    /// failure toast from the button that promised to add one; no button at all
    /// is the honest state.
    private func action(for reason: EmptyReason) -> (() -> Void)? {
        switch reason {
        case .noItems:
            guard openingStatusID != nil else { return nil }
            return { addItem() }
        case .filteredOut:
            return { clearFilters() }
        case .notEmpty, .noProjectSelected:
            return nil
        }
    }

    private func clearFilters() {
        withAnimation(AinkradMotion.present) {
            filter = ItemFilter()
            searchText = ""
        }
    }

    /// The status a newly created item opens in, derived from THIS project's
    /// own scheme. `nil` when the scheme is empty, which suppresses the action
    /// entirely. Shared with `TodaySurface`'s quick capture — see
    /// `StatusScheme.openingStatusID`.
    private var openingStatusID: String? { document.project.statusScheme.openingStatusID }

    /// Creates a real item and opens it, rather than merely pointing at a
    /// control the surface does not have. Filed under an epic because the
    /// epic-at-root rule rejects a parentless task.
    private func addItem() {
        // Guaranteed non-nil: `action(for:)` withholds this action otherwise.
        guard let statusID = openingStatusID else { return }
        do {
            let epicID = try inboxEpic(statusID: statusID)
            editing = try store.createItem(
                projectID: document.project.id, parentID: epicID,
                type: .task, title: "New item",
                statusID: statusID, actor: .user)
        } catch let failure as QuestError {
            report(failure.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    /// CREATES the Inbox epic when there is none. The resolution itself lives in
    /// `InboxEpic` so this surface and `TodaySurface`'s quick capture cannot
    /// disagree about where an item went — they had already diverged once.
    private func inboxEpic(statusID: String) throws -> UUID {
        switch InboxEpic.resolve(in: document.items) {
        case .existing(let id):
            return id
        case .adopt(let id):
            // Pre-marker document: mark it now, so this is the last add that
            // depended on the epic still being called "Inbox".
            try store.setRole(.inbox, on: id)
            return id
        case .create:
            return try store.createItem(
                projectID: document.project.id, parentID: nil, type: .epic,
                title: InboxEpic.title, statusID: statusID,
                actor: .user, role: .inbox
            ).id
        }
    }
}

/// One row. A `struct` per row, identified by `item.id` in the `ForEach` above,
/// is how the in-progress edit text below stays scoped to that row: SwiftUI
/// keys `@State` to the view's identity, not to the surface, so re-sorting or
/// re-filtering never lets one row's typing leak into another. The title field
/// is seeded from `item.title` when the editor appears, so a store-driven
/// re-render mid-edit does not clobber what the user is typing; it commits
/// explicitly on submit or on losing focus, never on every keystroke.
private struct ListRow: View {
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
                TextField("Title", text: $title)
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
        .frame(width: 140)
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
        } catch let failure as QuestError {
            report(failure.message, .danger)
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
                } catch let failure as QuestError {
                    report(failure.message, .danger)
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
        } catch let failure as QuestError {
            title = item.title
            report(failure.message, .danger)
        } catch {
            title = item.title
            report(error.localizedDescription, .danger)
        }
    }
}
