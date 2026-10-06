import Foundation

/// One project's complete persisted state: `project-<id>.json`.
struct ProjectDocument: Codable, Sendable {
    var project: Project
    var items: [WorkItem]
    var activity: [ActivityEvent]

    init(project: Project, items: [WorkItem] = [], activity: [ActivityEvent] = []) {
        self.project = project
        self.items = items
        self.activity = activity
    }
}
