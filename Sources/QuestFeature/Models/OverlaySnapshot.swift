import Foundation

/// One backup of everything the user cannot get back.
///
/// Holds the overlay documents, the link map, and `HubConfig`'s MIGRATION
/// MARKERS — but deliberately NOT its bindings. Markers are machine-independent
/// facts ("this project's repos already moved"); bindings are machine-specific
/// routing, and restoring them elsewhere would resurrect connections that do
/// not exist on that machine. Project documents are excluded too: they are the
/// mirror, and a re-sync rebuilds them.
public struct OverlaySnapshot: Codable, Sendable {
    /// Bumped when the payload's shape changes incompatibly. Read on restore so
    /// a future Quest can refuse a snapshot it does not understand rather than
    /// decoding it wrongly.
    public let version: Int
    public let takenAt: Date
    public let overlays: [ProjectOverlay]
    public let linkMap: LinkMap
    public let migratedRepoProjects: Set<String>
    public let migratedBindingProjects: Set<String>

    public static let currentVersion = 1

    public init(
        version: Int = OverlaySnapshot.currentVersion, takenAt: Date,
        overlays: [ProjectOverlay], linkMap: LinkMap,
        migratedRepoProjects: Set<String>, migratedBindingProjects: Set<String>
    ) {
        self.version = version
        self.takenAt = takenAt
        self.overlays = overlays
        self.linkMap = linkMap
        self.migratedRepoProjects = migratedRepoProjects
        self.migratedBindingProjects = migratedBindingProjects
    }

    private enum CodingKeys: String, CodingKey {
        case version, takenAt, overlays, linkMap, migratedRepoProjects, migratedBindingProjects
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `version` and `takenAt` are REQUIRED: a snapshot without them cannot
        // be judged for age or compatibility, and guessing either would be
        // worse than refusing the file.
        version = try container.decode(Int.self, forKey: .version)
        takenAt = try container.decode(Date.self, forKey: .takenAt)
        overlays = try container.decodeIfPresent([ProjectOverlay].self, forKey: .overlays) ?? []
        linkMap = try container.decodeIfPresent(LinkMap.self, forKey: .linkMap) ?? LinkMap()
        migratedRepoProjects =
            try container
            .decodeIfPresent(Set<String>.self, forKey: .migratedRepoProjects) ?? []
        migratedBindingProjects =
            try container
            .decodeIfPresent(Set<String>.self, forKey: .migratedBindingProjects) ?? []
    }
}
