import Foundation

/// What a status MEANS, independent of what it is called. Boards, progress
/// rollups and "is this finished" all read the category, so a renamed or
/// custom status never breaks completion logic.
public enum StatusCategory: String, Codable, Sendable, CaseIterable {
    case todo, active, done
}

public struct Status: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var category: StatusCategory
    /// Theme token name resolved at render time, never a literal color.
    public var colorToken: String

    public init(id: String, name: String, category: StatusCategory, colorToken: String) {
        self.id = id
        self.name = name
        self.category = category
        self.colorToken = colorToken
    }
}

/// An ordered set of statuses owned by one project. Order is board column order.
public struct StatusScheme: Codable, Sendable, Hashable {
    public var statuses: [Status]

    public init(statuses: [Status]) { self.statuses = statuses }

    public func status(id: String) -> Status? { statuses.first { $0.id == id } }

    public func isDone(_ statusID: String) -> Bool {
        status(id: statusID)?.category == .done
    }

    public static let softwareDefault = StatusScheme(statuses: [
        Status(id: "backlog", name: "Backlog", category: .todo, colorToken: "muted"),
        Status(id: "todo", name: "Todo", category: .todo, colorToken: "accentSecondary"),
        Status(id: "in_progress", name: "In Progress", category: .active, colorToken: "accentPrimary"),
        Status(id: "in_review", name: "In Review", category: .active, colorToken: "warning"),
        Status(id: "done", name: "Done", category: .done, colorToken: "success"),
    ])

    public static let generalDefault = StatusScheme(
        statuses:
            softwareDefault.statuses.filter { $0.id != "in_review" })
}
