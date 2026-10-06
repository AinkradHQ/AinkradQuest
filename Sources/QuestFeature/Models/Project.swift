import Foundation

public enum ProjectKind: String, Codable, Sendable { case software, general }
public enum ProjectState: String, Codable, Sendable { case active, paused, archived }

public struct Project: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var summaryText: String
    public var icon: String
    public var colorToken: String
    public var kind: ProjectKind
    public var state: ProjectState
    public var statusScheme: StatusScheme
    public var links: [Link]
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    /// PRE-M2 storage, still decoded so a rollback finds its data, never
    /// written by new code. The live values live in `OverlayStore` /
    /// `HubConfig`; read those, not these.
    public var legacyRepos: [AttachedRepo]
    public var legacyConnectionID: UUID?
    public var legacyRemoteProjectKey: String?

    public init(
        id: UUID, name: String, kind: ProjectKind,
        summaryText: String = "", icon: String = "folder",
        colorToken: String = "accent", state: ProjectState = .active,
        statusScheme: StatusScheme? = nil, links: [Link] = [],
        createdAt: Date = Date(), updatedAt: Date = Date(), archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.summaryText = summaryText
        self.icon = icon
        self.colorToken = colorToken
        self.state = state
        self.statusScheme = statusScheme ?? (kind == .software ? .softwareDefault : .generalDefault)
        self.links = links
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.legacyConnectionID = nil
        self.legacyRemoteProjectKey = nil
        self.legacyRepos = []
    }

    public var summary: ProjectSummary {
        ProjectSummary(
            id: id, name: name, icon: icon, colorToken: colorToken,
            kind: kind, state: state, updatedAt: updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summaryText, icon, colorToken, kind, state, statusScheme,
            links, createdAt, updatedAt, archivedAt
        case
            legacyConnectionID = "connectionID"
        case
            legacyRemoteProjectKey = "remoteProjectKey"
        case
            legacyRepos = "repos"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summaryText = try container.decode(String.self, forKey: .summaryText)
        icon = try container.decode(String.self, forKey: .icon)
        colorToken = try container.decode(String.self, forKey: .colorToken)
        kind = try container.decode(ProjectKind.self, forKey: .kind)
        state = try container.decode(ProjectState.self, forKey: .state)
        statusScheme = try container.decode(StatusScheme.self, forKey: .statusScheme)
        links = try container.decode([Link].self, forKey: .links)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        // Written before the hub existed: unbound, no repos.
        legacyConnectionID = try container.decodeIfPresent(UUID.self, forKey: .legacyConnectionID)
        legacyRemoteProjectKey = try container.decodeIfPresent(String.self, forKey: .legacyRemoteProjectKey)
        legacyRepos = try container.decodeIfPresent([AttachedRepo].self, forKey: .legacyRepos) ?? []
    }
}

/// What the index document holds. Deliberately small: the sidebar and
/// Today/Inbox read the index, so it must not require decoding every item.
public struct ProjectSummary: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var icon: String
    public var colorToken: String
    public var kind: ProjectKind
    public var state: ProjectState
    public var updatedAt: Date
    /// Whether the store has moved this project to trash. Persisted in the
    /// index so soft-deletes survive relaunch; decoded leniently so an index
    /// written before this field existed still loads.
    public var isTrashed: Bool

    public init(
        id: UUID, name: String, icon: String, colorToken: String,
        kind: ProjectKind, state: ProjectState, updatedAt: Date, isTrashed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorToken = colorToken
        self.kind = kind
        self.state = state
        self.updatedAt = updatedAt
        self.isTrashed = isTrashed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, colorToken, kind, state, updatedAt, isTrashed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        colorToken = try container.decode(String.self, forKey: .colorToken)
        kind = try container.decode(ProjectKind.self, forKey: .kind)
        state = try container.decode(ProjectState.self, forKey: .state)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isTrashed = try container.decodeIfPresent(Bool.self, forKey: .isTrashed) ?? false
    }
}
