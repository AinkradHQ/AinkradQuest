import Foundation

public enum ActivityActor: String, Codable, Sendable { case user, agent }

public enum ActivityKind: String, Codable, Sendable {
    case projectCreated, projectUpdated, projectDeleted, projectRestored
    case itemCreated, itemUpdated, itemMoved, itemStatusChanged
    case itemDeleted, itemRestored
    /// Emitted by the store's link API for both projects and items.
    case linkAdded, linkRemoved
    /// Emitted by `ProjectStore.applyScheme` when a validated `SchemePlan.Plan`
    /// is committed.
    case schemeUpdated
}

/// Append-only. This is the record that makes full agent control livable: a bad
/// agent call is visible and undoable rather than prevented.
public struct ActivityEvent: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let projectID: UUID
    public let itemID: UUID?
    public let actor: ActivityActor
    public let kind: ActivityKind
    public let summary: String
    public let at: Date

    public init(
        id: UUID = UUID(), projectID: UUID, itemID: UUID? = nil,
        actor: ActivityActor, kind: ActivityKind, summary: String, at: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.itemID = itemID
        self.actor = actor
        self.kind = kind
        self.summary = summary
        self.at = at
    }
}
