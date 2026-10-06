import Foundation

/// What ⌘K offers. `CommandAction` is a value, not a closure, because
/// `AinkradCommandMenu<T: Hashable>` requires `Hashable` rows — the shell
/// switches on the action instead of the menu carrying behaviour.
public enum CommandAction: Hashable, Sendable {
    case openSurface(QuestSurface)
    case selectProject(UUID)
    case setStatus(String)
    case newItem
    case newProject
    case openTrash
    case openSettings
}

public struct QuestCommand: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let icon: String
    public let detail: String?
    public let action: CommandAction

    public init(
        id: String, title: String, icon: String, detail: String? = nil,
        action: CommandAction
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.detail = detail
        self.action = action
    }
}

public enum CommandCatalog {
    /// Order matters — it is the order rows appear. Project-scoped commands
    /// are omitted entirely when nothing is selected rather than offered and
    /// failing, which is the difference between a menu and a trap.
    public static func entries(
        projects: [ProjectSummary],
        hasProject: Bool,
        statuses: [Status]
    ) -> [QuestCommand] {
        var entries: [QuestCommand] = []

        if hasProject {
            entries.append(
                QuestCommand(
                    id: "newItem", title: "New item",
                    icon: "plus.circle", detail: "In this project",
                    action: .newItem))
            // Project-scoped, like the rest of this block: it opens the
            // SELECTED project's settings, so with nothing selected choosing it
            // did nothing at all — not even a toast. It used to be appended
            // below, outside this gate.
            entries.append(
                QuestCommand(
                    id: "openSettings", title: "Project settings",
                    icon: "gearshape", detail: "This project",
                    action: .openSettings))
            for surface in SurfaceVisibility.offered(hasProject: true) {
                entries.append(
                    QuestCommand(
                        id: "surface.\(surface.rawValue)",
                        title: "Go to \(surface.title)",
                        icon: surface.icon, detail: "Surface",
                        action: .openSurface(surface)))
            }
            for status in statuses {
                entries.append(
                    QuestCommand(
                        id: "status.\(status.id)",
                        title: "Set status: \(status.name)",
                        icon: "circle.dashed", detail: "Selected item",
                        action: .setStatus(status.id)))
            }
        }

        entries.append(
            QuestCommand(
                id: "newProject", title: "New project",
                icon: "folder.badge.plus", action: .newProject))
        for project in projects {
            entries.append(
                QuestCommand(
                    id: "project.\(project.id.uuidString)",
                    title: project.name, icon: project.icon,
                    detail: "Project",
                    action: .selectProject(project.id)))
        }
        entries.append(
            QuestCommand(
                id: "openTrash", title: "Trash",
                icon: "trash", action: .openTrash))
        return entries
    }

    public static func filtered(_ entries: [QuestCommand], query: String) -> [QuestCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.title.lowercased().contains(needle)
                || ($0.detail?.lowercased().contains(needle) ?? false)
        }
    }
}
