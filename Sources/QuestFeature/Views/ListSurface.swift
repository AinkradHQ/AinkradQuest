import AinkradAppKit
import SwiftUI

/// SF Symbol per work-item type, shared by the surface and `ListRow` so the
/// two cannot become drifting copies of one table.
func itemGlyph(for type: WorkItemType) -> String {
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
