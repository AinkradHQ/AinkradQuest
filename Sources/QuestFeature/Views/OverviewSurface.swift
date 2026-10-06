import AinkradAppKit
import SwiftUI

struct OverviewSurface: View {
    @Bindable var store: ProjectStore
    let document: ProjectDocument
    /// The shell's single reporting path, forwarded to the link views below.
    /// The `theme: HostTheme` this surface used to carry is gone: every view it
    /// forwarded it to now reads `\.ainkradTheme` from the environment
    /// (Task 12).
    let report: (String, AinkradStatus) -> Void

    @Environment(\.ainkradTheme) private var ainkradTheme

    var body: some View {
        // Computed once per render rather than as a computed property
        // re-filtered on every access (count, isEmpty, and ForEach each read
        // it below).
        let epics = document.items.filter { $0.type == .epic && !$0.isDeleted }
        ScrollView {
            VStack(alignment: .leading, spacing: AinkradSpacing.lg) {
                header

                AinkradSectionFrame(title: "Counts") {
                    VStack(spacing: AinkradSpacing.xs) {
                        AinkradStatRow(label: "Items", value: "\(document.items.count)")
                        AinkradStatRow(label: "Epics", value: "\(epics.count)")
                        AinkradStatRow(label: "Links", value: "\(document.project.links.count)")
                    }
                }

                AinkradSectionFrame(title: "Links") {
                    VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                        LinkListView(
                            store: store, target: .project(document.project.id),
                            links: document.project.links, report: report)
                        LinkEditor(
                            store: store, target: .project(document.project.id),
                            report: report)
                        // Always reachable, independent of any root grant and of
                        // whether a suggestion sheet ever fired for this project —
                        // see `FolderAttachButton`'s doc comment.
                        FolderAttachButton(
                            store: store, projectID: document.project.id,
                            report: report)
                    }
                }

                AinkradSectionFrame(title: "Epics") {
                    if epics.isEmpty {
                        AinkradEmptyState(
                            icon: "flag", title: "No epics",
                            message: "Group work under an epic to track progress here.")
                    } else {
                        LazyVStack(alignment: .leading, spacing: AinkradSpacing.md) {
                            ForEach(epics) { epic in
                                let progress = EpicProgress.rollup(
                                    epicID: epic.id, in: document.items,
                                    scheme: document.project.statusScheme)
                                AinkradCard {
                                    HStack(spacing: AinkradSpacing.md) {
                                        AinkradMeter(
                                            value: Double(progress.done), total: Double(progress.total),
                                            label: epic.title, size: 64)
                                        Spacer()
                                        AinkradBadge(text: "\(progress.done)/\(progress.total)")
                                    }
                                }
                            }
                        }
                    }
                }

                AinkradSectionFrame(title: "Recent activity") {
                    VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                        ForEach(document.activity.suffix(20).reversed()) { event in
                            AinkradListRow(
                                leading: {
                                    AinkradIconGlyph(systemName: event.actor == .agent ? "sparkles" : "person")
                                },
                                title: event.summary,
                                trailing: {
                                    Text(event.at, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(ainkradTheme.foreground.opacity(0.55))
                                }
                            )
                        }
                    }
                }
            }
            .padding(AinkradSpacing.lg)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            Text(document.project.name).font(.title2)
                .foregroundStyle(ainkradTheme.foreground)
            if !document.project.summaryText.isEmpty {
                Text(document.project.summaryText)
                    .foregroundStyle(ainkradTheme.foreground.opacity(0.7))
            }
        }
    }
}
