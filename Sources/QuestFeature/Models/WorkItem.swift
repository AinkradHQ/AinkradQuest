import Foundation

enum WorkItemType: String, Codable, Sendable, CaseIterable {
    case epic, task, bug, story, chore, spike
}

enum Priority: Int, Codable, Sendable, CaseIterable, Comparable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    case urgent = 4
    static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

/// A job an item does for the app, as opposed to for the user. Distinct from
/// `type`, which the user chooses and can change freely.
///
/// Deliberately an enum rather than an `isInbox` flag: the next such role
/// (a backlog, an archive) then costs a case instead of another Bool that has
/// to be kept mutually exclusive with the first by hand.
enum WorkItemRole: String, Codable, Sendable {
    /// Where quick captures land when the user picked no epic.
    case inbox
}

struct WorkItem: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let projectID: UUID
    /// Nil means depth 0 — an epic. Enforced by `HierarchyRules`.
    var parentID: UUID?
    var type: WorkItemType
    var title: String
    var body: String
    var statusID: String
    var priority: Priority
    var labels: [String]
    var startDate: Date?
    var dueDate: Date?
    var orderIndex: Int
    var links: [Link]
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    /// Soft delete. Non-nil items are excluded from every surface and query
    /// but remain restorable — this is what makes agent-driven deletes safe.
    var deletedAt: Date?
    /// What this item is FOR, when the app needs to find it again — currently
    /// only the Inbox. Nil for everything the user made themselves.
    ///
    /// Optional, and that is load-bearing: Swift's synthesized `init(from:)`
    /// does NOT fall back to a property's default value for a missing key, so a
    /// non-optional `isInbox = false` would fail to decode every document
    /// written before this field existed. An Optional decodes as nil when
    /// absent, which is exactly the migration story wanted here.
    var role: WorkItemRole?

    init(
        id: UUID, projectID: UUID, parentID: UUID?, type: WorkItemType,
        title: String, statusID: String, body: String = "",
        priority: Priority = .none, labels: [String] = [],
        startDate: Date? = nil, dueDate: Date? = nil, orderIndex: Int = 0,
        links: [Link] = [], createdAt: Date = Date(), updatedAt: Date = Date(),
        closedAt: Date? = nil, deletedAt: Date? = nil,
        role: WorkItemRole? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.parentID = parentID
        self.type = type
        self.title = title
        self.statusID = statusID
        self.body = body
        self.priority = priority
        self.labels = labels
        self.startDate = startDate
        self.dueDate = dueDate
        self.orderIndex = orderIndex
        self.links = links
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.deletedAt = deletedAt
        self.role = role
    }

    var isDeleted: Bool { deletedAt != nil }
}
