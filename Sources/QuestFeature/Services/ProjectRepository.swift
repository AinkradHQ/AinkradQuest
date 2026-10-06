import Foundation

/// The seam M4 replaces. Everything above it — store, views, MCP — is written
/// against this protocol, so repointing Quest at the host-wide Ainkrad content
/// store is a new conformance rather than a rewrite.
public protocol ProjectRepository: AnyObject {
    func loadIndex() -> [ProjectSummary]
    /// Throws when the write could not be completed. A repository must never
    /// swallow a failed write: the store's only way to know a save was lost is
    /// for the repository to say so.
    func saveIndex(_ summaries: [ProjectSummary]) throws
    func loadProject(_ id: UUID) -> ProjectDocument?
    /// Throws when the write could not be completed. See `saveIndex`.
    func saveProject(_ document: ProjectDocument) throws
    func removeProject(_ id: UUID)
    /// Connections live in their own document. The project index is read on
    /// every launch to draw the sidebar; connections are not needed for that,
    /// and folding them in would mean decoding credentials-adjacent data for a
    /// list of project names.
    func loadConnections() -> [Connection]
    /// Throws when the write could not be completed. See `saveIndex`.
    func saveConnections(_ connections: [Connection]) throws

    /// Overlay documents are per-project for the same reason `ProjectDocument`
    /// is: the cockpit must not decode every overlay record ever written just
    /// to draw one project.
    ///
    /// Returns `nil` when there is genuinely no overlay for this project — the
    /// normal case for any project the user has not annotated. Throws
    /// `QuestError.overlayCorrupt` when data exists at the key but fails to
    /// decode: unlike the index or a project document, the overlay is not
    /// rebuildable, so a corrupt document must surface rather than read as
    /// empty — reading it as empty would let the next save silently overwrite
    /// the corrupt bytes with nothing.
    func loadOverlay(_ projectID: UUID) throws -> ProjectOverlay?
    /// Throws when the write could not be completed. See `saveIndex`.
    func saveOverlay(_ overlay: ProjectOverlay) throws
    func removeOverlay(_ projectID: UUID)

    func loadLinkMap() -> LinkMap
    /// Throws when the write could not be completed. See `saveIndex`.
    func saveLinkMap(_ map: LinkMap) throws

    func loadHubConfig() -> HubConfig
    /// Throws when the write could not be completed. See `saveIndex`.
    func saveHubConfig(_ config: HubConfig) throws
}

/// Test double. Keeps store tests free of encoding concerns.
public final class InMemoryProjectRepository: ProjectRepository {
    private var index: [ProjectSummary] = []
    private var documents: [UUID: ProjectDocument] = [:]
    private var connections: [Connection] = []
    private var overlays: [UUID: ProjectOverlay] = [:]
    private var linkMap = LinkMap()
    private var hubConfig = HubConfig()

    public init() {}

    public func loadIndex() -> [ProjectSummary] { index }
    public func saveIndex(_ summaries: [ProjectSummary]) { index = summaries }
    public func loadProject(_ id: UUID) -> ProjectDocument? { documents[id] }
    public func saveProject(_ document: ProjectDocument) { documents[document.project.id] = document }
    public func removeProject(_ id: UUID) { documents.removeValue(forKey: id) }
    public func loadConnections() -> [Connection] { connections }
    public func saveConnections(_ connections: [Connection]) { self.connections = connections }

    public func loadOverlay(_ projectID: UUID) throws -> ProjectOverlay? { overlays[projectID] }
    public func saveOverlay(_ overlay: ProjectOverlay) { overlays[overlay.projectID] = overlay }
    public func removeOverlay(_ projectID: UUID) { overlays.removeValue(forKey: projectID) }
    public func loadLinkMap() -> LinkMap { linkMap }
    public func saveLinkMap(_ map: LinkMap) { linkMap = map }
    public func loadHubConfig() -> HubConfig { hubConfig }
    public func saveHubConfig(_ config: HubConfig) { hubConfig = config }
}
