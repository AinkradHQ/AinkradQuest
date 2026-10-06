import AinkradAppKit
import SwiftUI

/// Shared editor used by every surface that opens a single item.
///
/// Presented through `.ainkradModal`, an OVERLAY modifier that injects no
/// `DismissAction`. `@Environment(\.dismiss)` would therefore resolve to the
/// enclosing window's action (or nothing) and leave Cancel/Save inert while
/// still compiling — so closing is the presenter's job, requested via
/// `onClose`.
struct ItemEditor: View {
    @Bindable var store: ProjectStore
    let document: ProjectDocument
    /// The shell's single reporting path, replacing this view's `error` string.
    let report: (String, AinkradStatus) -> Void
    /// Asks the presenter to take this editor down. Always the LAST statement
    /// on its path: it unmounts this subtree, so any `@State` write after it
    /// would land in a view that no longer exists.
    let onClose: () -> Void

    @State private var draft: WorkItem
    @State private var hasStartDate: Bool
    @State private var hasDueDate: Bool

    @Environment(\.ainkradTheme) private var theme

    init(
        store: ProjectStore, document: ProjectDocument, item: WorkItem,
        report: @escaping (String, AinkradStatus) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.document = document
        self.report = report
        self.onClose = onClose
        _draft = State(initialValue: item)
        _hasStartDate = State(initialValue: item.startDate != nil)
        _hasDueDate = State(initialValue: item.dueDate != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "Item", subtitle: draft.title)

            ScrollView {
                VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    fields
                    links
                }
                .padding(.trailing, AinkradSpacing.xs)
            }
            // A deliberate cap so a long body or a long link list scrolls
            // inside the modal instead of pushing its buttons off-screen.
            .frame(maxHeight: 420)

            HStack {
                AinkradButton(title: "Cancel", style: .secondary, action: onClose)
                Spacer()
                AinkradButton(title: "Save", style: .primary, action: save)
            }
        }
        // A deliberate fixed editor width, inside `.ainkradModal`'s 480pt cap.
        .frame(width: 440)
        .foregroundStyle(theme.foreground)
        .onSubmit(save)
        // `AinkradButton` carries no keyboard shortcut, so the `.defaultAction`
        // the old `Button("Save")` had would otherwise be lost: with no text
        // field focused there would be nothing for Return to do at all.
        .background(defaultActionSave)
    }

    /// Return-with-nothing-focused commits, exactly as the pre-kit
    /// `Button("Save").keyboardShortcut(.defaultAction)` did.
    private var defaultActionSave: some View {
        Button("") { save() }
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var fields: some View {
        AinkradFormRow(title: "Title") {
            AinkradTextField(text: $draft.title, placeholder: "Title")
        }
        AinkradFormRow(title: "Type") {
            AinkradSelect(
                items: WorkItemType.allCases,
                selection: $draft.type
            ) { $0.rawValue.capitalized }
        }
        AinkradFormRow(title: "Status") {
            AinkradSelect(items: statusIDs, selection: $draft.statusID) { statusName($0) }
        }
        AinkradFormRow(title: "Priority") {
            AinkradSegmentedPicker(
                items: Priority.allCases,
                selection: $draft.priority
            ) { priorityLabel($0) }
        }
        dateRow(label: "Start", has: $hasStartDate, date: $draft.startDate)
        dateRow(label: "Due", has: $hasDueDate, date: $draft.dueDate)
        AinkradFormRow(title: "Notes") {
            AinkradTextArea(text: $draft.body, placeholder: "Notes")
        }
    }

    /// Wrapped in its OWN submit scope. SwiftUI runs submit actions
    /// innermost-first and then PROPAGATES OUTWARD unless a scope blocks it —
    /// it does not shadow. Without `.submitScope()`, Return in the link
    /// identifier field would run `LinkEditor.add()` and then fall through to
    /// this editor's `.onSubmit(save)`, adding the link and immediately saving
    /// and closing the whole editor. Return here must add a link and stop.
    private var links: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "Links")
            LinkListView(
                store: store, target: .item(draft.id),
                links: currentLinks, report: report)
            LinkEditor(store: store, target: .item(draft.id), report: report)
        }
        .submitScope()
    }

    private var statusIDs: [String] { document.project.statusScheme.statuses.map(\.id) }

    /// Falls back to the raw id rather than rendering blank: a document whose
    /// item points at a status the scheme no longer has must still show WHICH
    /// status, or the editor looks like it lost the value.
    private func statusName(_ id: String) -> String {
        document.project.statusScheme.statuses.first { $0.id == id }?.name ?? id
    }

    private func priorityLabel(_ priority: Priority) -> String {
        switch priority {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }

    /// A toggle gates each date field so the underlying date stays nil unless
    /// the user explicitly opts in — Timeline's "unscheduled" rail depends on
    /// that nil surviving a trip through the editor untouched.
    ///
    /// `DatePicker` is deliberately raw SwiftUI: the kit ships no date control
    /// at this revision, and dropping the calendar for a text field would lose
    /// behaviour to fit a component.
    @ViewBuilder
    private func dateRow(label: String, has: Binding<Bool>, date: Binding<Date?>) -> some View {
        AinkradFormRow(title: "\(label) date") {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradToggle(isOn: has)
                    .onChange(of: has.wrappedValue) { _, newValue in
                        date.wrappedValue = newValue ? (date.wrappedValue ?? Date()) : nil
                    }
                if has.wrappedValue {
                    DatePicker(
                        label,
                        selection: Binding(
                            get: { date.wrappedValue ?? Date() },
                            set: { date.wrappedValue = $0 }), displayedComponents: .date
                    )
                    .labelsHidden()
                }
            }
        }
    }

    /// Read links from the STORE rather than the draft: the link editor commits
    /// immediately through the store, while the rest of this sheet is a draft
    /// saved on Save. Reading the draft would show stale links.
    private var currentLinks: [Link] {
        store.allItems(in: document.project.id).first { $0.id == draft.id }?.links ?? []
    }

    private func save() {
        // The link editor above already committed any link changes directly
        // through the store. draft.links is stale from init time, so pull the
        // store's current copy immediately before saving — otherwise this
        // overwrite would silently delete links added since the sheet opened.
        draft.links = currentLinks
        do {
            try store.updateItem(draft, actor: .user)
            // LAST statement on this path — see `onClose`.
            onClose()
        } catch let failure as QuestError {
            report(failure.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }
}
