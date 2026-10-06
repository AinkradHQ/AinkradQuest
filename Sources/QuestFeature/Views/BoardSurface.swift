import AinkradAppKit
import SwiftUI
import UniformTypeIdentifiers

struct BoardSurface: View {
    @Bindable var store: ProjectStore
    let document: ProjectDocument
    /// Owned by the shell's header, the same binding `ListSurface` reads.
    /// `QuestHeader` renders its search field on every surface, so a board
    /// that ignored it would leave a visible control silently doing nothing —
    /// worse than no control at all. The board grows no field of its own.
    @Binding var searchText: String
    let report: (String, AinkradStatus) -> Void

    /// The base the header's query is merged onto. No board UI sets its other
    /// fields yet, but it is the merge base rather than dead state — see
    /// `activeFilter`.
    @State private var filter = ItemFilter()
    @State private var editing: WorkItem?
    @Environment(\.questSurfaceModal) private var surfaceModal
    @State private var groupByEpic = false

    /// Merged at read time, exactly as `ListSurface.activeFilter` does, so the
    /// shell stays the single owner of the query and the two surfaces cannot
    /// drift on what "searching" means. Both `BoardGrouping` entry points
    /// already take an `ItemFilter`, so this needs no change to the grouping.
    private var activeFilter: ItemFilter {
        var merged = filter
        merged.text = searchText
        return merged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradFormRow(title: "Group by epic") { AinkradToggle(isOn: $groupByEpic) }
                .padding(.horizontal, AinkradSpacing.md)
                .padding(.top, AinkradSpacing.sm)
            ScrollView(.horizontal) {
                if groupByEpic {
                    // Computed once per render rather than inline inside
                    // ForEach — `groupedByEpic` keeps its orphan backstop: an
                    // item whose epic is gone lands in a trailing "No epic"
                    // group instead of vanishing off the board.
                    let groups = BoardGrouping.groupedByEpic(
                        items: document.items,
                        scheme: document.project.statusScheme,
                        filter: activeFilter)
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.lg) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                                AinkradSectionHeader(
                                    title: group.epic.title,
                                    subtitle: group.isOrphanGroup
                                        ? "Items with no live epic" : nil)
                                columnStrip(group.columns)
                            }
                        }
                    }
                    .padding(AinkradSpacing.md)
                } else {
                    let columns = BoardGrouping.columns(
                        items: document.items,
                        scheme: document.project.statusScheme,
                        filter: activeFilter)
                    columnStrip(columns)
                        .padding(AinkradSpacing.md)
                }
            }
        }
        .animation(AinkradMotion.present, value: groupByEpic)
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

    private func columnStrip(_ columns: [BoardColumn]) -> some View {
        // LazyHStack for the columns and LazyVStack for the cards within each
        // column — a board with 8 columns of 200 cards would otherwise build
        // 1,600 live views up front.
        LazyHStack(alignment: .top, spacing: AinkradSpacing.md) {
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                    HStack {
                        AinkradSectionHeader(title: column.status.name)
                        Spacer()
                        AinkradBadge(text: "\(column.items.count)")
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                            ForEach(column.items) { item in
                                card(item).draggable(item.id.uuidString)
                            }
                        }
                    }
                }
                // A deliberate fixed column width, so columns stay drop-sized
                // regardless of how much a card's title wants.
                .frame(width: 260)
                .padding(AinkradSpacing.sm)
                .ainkradPanel()
                .dropDestination(for: String.self) { payload, _ in
                    guard let raw = payload.first, let id = UUID(uuidString: raw) else {
                        return false
                    }
                    // A rejected status (not in this project's scheme) is
                    // impossible here — the column came from the scheme —
                    // so a throw means a genuinely missing item. It now
                    // reaches the user instead of being swallowed.
                    do {
                        // `withAnimation` rethrows, so the move and the
                        // animation of its result stay one statement.
                        try withAnimation(AinkradMotion.present) {
                            try store.setStatus(id, statusID: column.status.id, actor: .user)
                        }
                        return true
                    } catch let failure as QuestError {
                        report(failure.message, .danger)
                        return false
                    } catch {
                        report(error.localizedDescription, .danger)
                        return false
                    }
                }
            }
        }
        .animation(AinkradMotion.present, value: columns.flatMap { $0.items.map(\.id) })
    }

    private func card(_ item: WorkItem) -> some View {
        AinkradCard(onTap: { editing = item }) {
            VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                Text(item.title)
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradBadge(text: item.type.rawValue)
                    ForEach(item.labels, id: \.self) { AinkradChip(label: $0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
