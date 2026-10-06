import AinkradAppKit
import SwiftUI

/// One-line capture syntax: `bug: title #label #label !!`. Deliberately tiny —
/// anything richer belongs in the editor, and a capture box you have to think
/// about is one you stop using.
public enum QuickCapture {
    public struct Parsed: Sendable, Equatable {
        public let title: String
        public let type: WorkItemType
        public let labels: [String]
        public let priority: Priority
    }

    public static func parse(_ raw: String) -> Parsed {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var type = WorkItemType.task

        for candidate in WorkItemType.allCases where candidate != .epic {
            let prefix = "\(candidate.rawValue): "
            if text.lowercased().hasPrefix(prefix) {
                type = candidate
                text = String(text.dropFirst(prefix.count))
                break
            }
        }

        var priority = Priority.none
        if text.hasSuffix("!!") {
            priority = .urgent
            text = String(text.dropLast(2))
        } else if text.hasSuffix("!") {
            priority = .high
            text = String(text.dropLast(1))
        }

        var labels: [String] = []
        let words = text.split(separator: " ")
        var titleWords: [Substring] = []
        for word in words {
            if word.hasPrefix("#"), word.count > 1 {
                labels.append(String(word.dropFirst()))
            } else {
                titleWords.append(word)
            }
        }

        return Parsed(
            title: titleWords.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            type: type, labels: labels, priority: priority)
    }
}

struct TodaySurface: View {
    @Bindable var store: ProjectStore
    let report: (String, AinkradStatus) -> Void
    let onOpen: (WorkItem) -> Void

    @State private var captureText = ""
    /// `AinkradSelect` needs a non-optional binding, so this starts as a UUID
    /// that matches no project and is seeded from the active list below. An
    /// unseeded value is not a failure: `submitCapture` falls back to the first
    /// active project rather than silently doing nothing.
    @State private var captureTargetID = UUID()

    /// Cached because building this opens every active project's document and
    /// sorts four arrays. As a computed property it re-ran on every body pass —
    /// once per keystroke in the capture field.
    ///
    /// `store.revision` is the right key: it counts *in-memory* mutations, and
    /// bumps even when the disk write failed (M1 keeps the in-memory change
    /// authoritative behind a persistent banner). Skipping invalidation on a
    /// failed persist would make Today show stale data while the banner
    /// promised the change was kept.
    ///
    /// Invalidation is push-only: `.onChange(of: store.revision, initial: true)`
    /// below overwrites this, and the read below does NOT re-check the revision.
    /// That is deliberate, not an oversight — a read-side staleness guard would
    /// have to return the empty result for the one body pass between a mutation
    /// and the `onChange`, flashing the "Nothing needs you" empty state on every
    /// capture. The cache therefore stores the result alone: a recorded revision
    /// nothing compares would only imply a guard that is not here.
    @State private var cache: TodayInbox.Result?

    private var result: TodayInbox.Result {
        cache ?? TodayInbox.Result(overdue: [], dueToday: [], active: [], recent: [])
    }

    /// Merged per-project inbox results. Each project is judged against its
    /// OWN status scheme — a general-kind project's items must never be
    /// evaluated against the software ladder, or their done-ness is a lie.
    private func rebuild() -> TodayInbox.Result {
        var overdue: [WorkItem] = []
        var dueToday: [WorkItem] = []
        var active: [WorkItem] = []
        var recent: [WorkItem] = []

        for project in store.activeProjects {
            guard let document = store.openProject(project.id) else { continue }
            let partial = TodayInbox.build(
                items: store.items(in: project.id),
                scheme: document.project.statusScheme, now: Date())
            overdue += partial.overdue
            dueToday += partial.dueToday
            active += partial.active
            recent += partial.recent
        }

        overdue.sort { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        dueToday.sort { $0.priority > $1.priority }
        active.sort { $0.priority > $1.priority }
        recent = Array(recent.sorted { $0.updatedAt > $1.updatedAt }.prefix(10))

        return TodayInbox.Result(
            overdue: overdue, dueToday: dueToday,
            active: active, recent: recent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AinkradSpacing.lg) {
                capture
                if isEmpty {
                    // Previously every bucket being empty rendered as a capture
                    // box above blank space, with nothing explaining why.
                    AinkradEmptyState(
                        icon: "checkmark.circle",
                        title: "Nothing needs you",
                        message: "No overdue, due-today, or in-progress work "
                            + "across your active projects."
                    )
                    .padding(.top, AinkradSpacing.xl)
                } else {
                    section("Overdue", result.overdue, status: .danger)
                    section("Due today", result.dueToday, status: .warning)
                    section("In progress", result.active, status: .neutral)
                    section("Recently touched", result.recent, status: .neutral)
                }
            }
            .padding(AinkradSpacing.lg)
        }
        .onChange(of: store.revision, initial: true) { _, _ in
            cache = rebuild()
            // Re-seed only when the current target has left the active list, so
            // a deliberate choice survives unrelated mutations.
            if !store.activeProjects.contains(where: { $0.id == captureTargetID }),
                let first = store.activeProjects.first?.id
            {
                captureTargetID = first
            }
        }
    }

    private var isEmpty: Bool {
        result.overdue.isEmpty && result.dueToday.isEmpty
            && result.active.isEmpty && result.recent.isEmpty
    }

    private var capture: some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradTextField(
                text: $captureText,
                placeholder: "Capture — e.g. bug: auth loops #backend !!"
            )
            .onSubmit(submitCapture)
            AinkradSelect(
                items: store.activeProjects.map(\.id),
                selection: $captureTargetID
            ) { id in
                // Also the zero-active-projects label: nothing matches, so the
                // trigger reads "Project", as the old Picker's placeholder tag did.
                store.activeProjects.first { $0.id == id }?.name ?? "Project"
            }
            .frame(width: 160)
            // No-`size` initializer: the frame comes from the kit default, not
            // a literal. That overload has no `tooltip:`, so the hint is
            // attached here along with the VoiceOver label `.help` cannot give.
            AinkradIconButton(systemName: "return") { submitCapture() }
                .help("Capture")
                .accessibilityLabel("Capture")
        }
    }

    private func submitCapture() {
        let parsed = QuickCapture.parse(captureText)
        guard !parsed.title.isEmpty else { return }
        // Selection first, then the first active project — an unseeded target
        // still captures somewhere. With no active project at all there is
        // nowhere to put it, and silence would look like a dropped capture.
        guard
            let projectID = store.activeProjects.first(where: { $0.id == captureTargetID })?.id
                ?? store.activeProjects.first?.id
        else {
            report("Create a project before capturing.", .danger)
            return
        }
        // Capture files under the project's Inbox epic, creating one when there
        // is none — a captured task with no parent would violate the
        // epic-at-root rule and be rejected.
        //
        // The opening status comes from the target project's OWN scheme:
        // `StatusSchemeEditor` lets the user remove or rename `todo`, and the
        // store rejects an unknown status, so a hardcoded id would turn every
        // submit into a danger toast with no way to capture into that project.
        guard let document = store.openProject(projectID),
            let statusID = document.project.statusScheme.openingStatusID
        else {
            report("This project has no statuses to open an item in.", .danger)
            return
        }
        do {
            let epicID = try inboxEpic(in: projectID, statusID: statusID)
            var item = try store.createItem(
                projectID: projectID, parentID: epicID,
                type: parsed.type, title: parsed.title,
                statusID: statusID, actor: .user)
            item.labels = parsed.labels
            item.priority = parsed.priority
            try store.updateItem(item, actor: .user)
            captureText = ""
        } catch let error as QuestError {
            report(error.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    /// Identical resolution to `ListSurface`'s add-item, by construction: both
    /// call `InboxEpic`. This copy used to fall back to an arbitrary first epic
    /// and skipped the soft-delete filter, so a capture could land under a
    /// trashed epic and disappear.
    private func inboxEpic(in projectID: UUID, statusID: String) throws -> UUID {
        switch InboxEpic.resolve(in: store.allItems(in: projectID)) {
        case .existing(let id):
            return id
        case .adopt(let id):
            // Pre-marker document: mark it now, so this is the last capture
            // that depended on the epic still being called "Inbox".
            try store.setRole(.inbox, on: id)
            return id
        case .create:
            return try store.createItem(
                projectID: projectID, parentID: nil, type: .epic,
                title: InboxEpic.title, statusID: statusID,
                actor: .user, role: .inbox
            ).id
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [WorkItem], status: AinkradStatus) -> some View {
        if !items.isEmpty {
            AinkradSectionFrame(title: title) {
                LazyVStack(spacing: AinkradSpacing.xs) {
                    ForEach(items) { item in
                        AinkradListRow(
                            onTap: { onOpen(item) },
                            leading: {
                                AinkradIconGlyph(systemName: icon(for: item.type))
                            },
                            title: item.title,
                            trailing: {
                                HStack(spacing: AinkradSpacing.xs) {
                                    AinkradBadge(
                                        text: item.type.rawValue,
                                        status: status)
                                    ForEach(item.labels, id: \.self) {
                                        AinkradChip(label: $0)
                                    }
                                }
                            })
                    }
                }
            }
        }
    }

    private func icon(for type: WorkItemType) -> String {
        switch type {
        case .epic: "flag"
        case .bug: "ant"
        case .story: "book"
        case .chore: "wrench"
        case .spike: "magnifyingglass"
        case .task: "circle"
        }
    }
}
