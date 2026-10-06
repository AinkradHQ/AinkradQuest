import Foundation

/// One logged stretch of work, entered by hand. Session time is DERIVED from
/// transcripts and never stored here — see the design's "derived layer".
public struct TimeEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var minutes: Int
    public var spentOn: Date
    public var note: String

    public init(id: UUID, minutes: Int, spentOn: Date, note: String = "") {
        self.id = id
        self.minutes = minutes
        self.spentOn = spentOn
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, minutes, spentOn, note
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        minutes = try container.decode(Int.self, forKey: .minutes)
        spentOn = try container.decode(Date.self, forKey: .spentOn)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// A Claude Code session attached to a work item.
///
/// `pathSlug` is how transcripts are addressed on disk
/// (`~/.claude/projects/<slug>/<sessionID>.jsonl`); `resolvedPath` records the
/// directory the slug was derived FROM, so moving a repo makes the orphaning
/// detectable rather than silent. `label` is stored rather than re-read,
/// because a raw UUID is unusable in a list and the transcript may be gone.
public struct SessionAttachment: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var sessionID: String
    public var pathSlug: String
    public var resolvedPath: String?
    public var label: String
    public var attachedAt: Date

    public init(
        id: UUID, sessionID: String, pathSlug: String,
        resolvedPath: String? = nil, label: String = "", attachedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.pathSlug = pathSlug
        self.resolvedPath = resolvedPath
        self.label = label
        self.attachedAt = attachedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, pathSlug, resolvedPath, label, attachedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        pathSlug = try container.decode(String.self, forKey: .pathSlug)
        resolvedPath = try container.decodeIfPresent(String.self, forKey: .resolvedPath)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        attachedAt = try container.decode(Date.self, forKey: .attachedAt)
    }
}

/// Per-item overlay: yours, never sent to a provider, irreplaceable.
public struct ItemOverlay: Codable, Sendable, Hashable {
    public var notes: String
    /// A position in YOUR ordering, independent of `WorkItem.priority`, which
    /// is the team's and becomes provider truth once a project is linked.
    /// Sparse: most items have none.
    public var personalOrder: Int?
    public var timeEntries: [TimeEntry]
    public var sessions: [SessionAttachment]

    public init(
        notes: String = "", personalOrder: Int? = nil,
        timeEntries: [TimeEntry] = [], sessions: [SessionAttachment] = []
    ) {
        self.notes = notes
        self.personalOrder = personalOrder
        self.timeEntries = timeEntries
        self.sessions = sessions
    }

    /// Whether this record carries nothing worth persisting, so the store can
    /// prune it. `personalOrder == 0` is a real position — top of the list —
    /// and must NOT read as empty.
    public var isEmpty: Bool {
        notes.isEmpty && personalOrder == nil && timeEntries.isEmpty && sessions.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case notes, personalOrder, timeEntries, sessions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        personalOrder = try container.decodeIfPresent(Int.self, forKey: .personalOrder)
        timeEntries = try container.decodeIfPresent([TimeEntry].self, forKey: .timeEntries) ?? []
        sessions = try container.decodeIfPresent([SessionAttachment].self, forKey: .sessions) ?? []
    }
}

/// Everything about one project that is yours rather than a provider's.
///
/// Backed up; the project document is not. Keyed by the project's LOCAL id,
/// never by a provider key, so linking or unlinking a project never rewrites
/// a single overlay key.
public struct ProjectOverlay: Codable, Sendable, Hashable {
    public let projectID: UUID
    public var repos: [AttachedRepo]
    public var vaultFolder: String?
    public var planFile: String?
    public var notes: String
    public var personalOrder: Int?
    /// Keyed by `UUID.uuidString`, NOT by `UUID`. Swift encodes a `[UUID: T]`
    /// dictionary as a flat array of alternating keys and values, which is both
    /// unreadable in the snapshot a person may have to inspect by hand and
    /// impossible to decode leniently from `{}`. String keys give a real JSON
    /// object. Reach items through `item(_:)` / `setItem(_:for:)`, never the
    /// raw dictionary.
    public var items: [String: ItemOverlay]

    public func item(_ itemID: UUID) -> ItemOverlay? { items[itemID.uuidString] }

    public mutating func setItem(_ overlay: ItemOverlay?, for itemID: UUID) {
        items[itemID.uuidString] = overlay
    }

    public init(projectID: UUID) {
        self.projectID = projectID
        self.repos = []
        self.vaultFolder = nil
        self.planFile = nil
        self.notes = ""
        self.personalOrder = nil
        self.items = [:]
    }

    /// True when nothing here is worth keeping. An `items` entry holding an
    /// EMPTY `ItemOverlay` does not count, or pruning could never reclaim it.
    public var isEmpty: Bool {
        repos.isEmpty && vaultFolder == nil && planFile == nil
            && notes.isEmpty && personalOrder == nil
            && items.values.allSatisfy(\.isEmpty)
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, repos, vaultFolder, planFile, notes, personalOrder, items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        repos = try container.decodeIfPresent([AttachedRepo].self, forKey: .repos) ?? []
        vaultFolder = try container.decodeIfPresent(String.self, forKey: .vaultFolder)
        planFile = try container.decodeIfPresent(String.self, forKey: .planFile)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        personalOrder = try container.decodeIfPresent(Int.self, forKey: .personalOrder)
        items = try container.decodeIfPresent([String: ItemOverlay].self, forKey: .items) ?? [:]
    }
}
