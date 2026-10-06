import Foundation

/// Typed failures. Surfaced inline in the UI and as structured MCP errors, so
/// each case's `message` is written to be read by a person AND by the assistant.
/// `LocalizedError`, so a caller can show any error through one
/// `localizedDescription` and still get `message` for this type.
public enum QuestError: Error, Equatable, Sendable, LocalizedError {
    case projectNotFound(UUID)
    case itemNotFound(UUID)
    case parentNotFound(UUID)
    case parentIsDeleted(UUID)
    case depthExceeded(attempted: Int, maximum: Int)
    case epicMustBeRoot
    case nonEpicMustHaveParent
    case unknownStatus(String)
    /// A scheme edit would have left items pointing at a status the new scheme
    /// does not contain — the plan went stale between planning and applying.
    case schemeWouldOrphanItems(String)
    case schemeChangedUnderneath
    case cyclicParent
    case linkNotFound(String)
    case linkAlreadyExists(String)
    /// A permanent delete was asked for on something that is not in the trash.
    /// Purge is irreversible, so it refuses rather than deleting a live project.
    case projectNotInTrash(UUID)
    /// The item equivalent. Same reasoning: a purge that would accept a live
    /// item is one mis-passed id away from destroying work nobody deleted.
    case itemNotInTrash(UUID)
    case duplicateConnection(String)
    case connectionNotFound(UUID)
    case connectionInUse(UUID, Int)
    case duplicateRepo(String)
    case repoNotFound(UUID)
    /// A provider key that is not even shaped like a valid id for this
    /// provider — distinct from `projectNotFound`, which names a real id that
    /// does not resolve. Reusing `projectNotFound` here would have to
    /// fabricate an id, naming something that never existed.
    case malformedProjectKey(String)
    /// The overlay document exists but failed to decode. Unlike the index or
    /// a project document, the overlay is not rebuildable, so this must
    /// surface rather than read as an empty overlay — reading it as empty
    /// would let the next save overwrite the corrupt bytes with nothing,
    /// destroying whatever might have been salvageable by hand.
    case overlayCorrupt(UUID)
    /// A document failed to decode and its bytes could not be verified aside,
    /// so the original was kept and saving is turned off for that key — the
    /// matching save throws this rather than overwriting the only copy.
    case documentCorrupt(String)

    public var message: String {
        switch self {
        case .projectNotFound(let id): "No project with id \(id)."
        case .itemNotFound(let id): "No work item with id \(id)."
        case .parentNotFound(let id): "No parent work item with id \(id)."
        case .parentIsDeleted(let id):
            "Work item \(id) is in the trash. Restore it before filing work under it."
        case .depthExceeded(let attempted, let maximum):
            "Hierarchy is capped at \(maximum) levels (epic → item → subtask); this would make \(attempted)."
        case .epicMustBeRoot: "An epic cannot have a parent."
        case .nonEpicMustHaveParent: "Only epics may sit at the top level of a project."
        case .unknownStatus(let id): "Status '\(id)' is not in this project's status scheme."
        case .schemeWouldOrphanItems(let id):
            "Items still hold status '\(id)', which the new scheme does not contain — "
                + "the project changed since this scheme edit was worked out. "
                + "Nothing was changed; review the scheme again."
        case .schemeChangedUnderneath:
            "This project's statuses changed since these edits were planned. "
                + "Review the current statuses and apply again."
        case .cyclicParent: "An item cannot be moved under its own descendant."
        case .linkNotFound(let id): "No link \(id) on that project or item."
        case .linkAlreadyExists(let id):
            "Link \(id) is already attached to that project or item."
        case .projectNotInTrash(let id):
            "Project \(id) is not in the trash, so there is nothing to delete permanently."
        case .itemNotInTrash(let id):
            "Work item \(id) is not in the trash, so there is nothing to delete permanently."
        case .duplicateConnection(let identifier):
            "An account named \(identifier) is already connected to this provider."
        case .connectionNotFound(let id):
            "No connection with id \(id)."
        case .connectionInUse(_, let count):
            "\(count) project\(count == 1 ? " is" : "s are") still bound to this connection. Unbind them first."
        case .duplicateRepo(let slug):
            "\(slug) is already attached to this project on that connection."
        case .repoNotFound(let id):
            "No attached repo with id \(id)."
        case .malformedProjectKey(let key):
            "'\(key)' is not a valid local project key (expected a UUID)."
        case .overlayCorrupt(let id):
            "The overlay for project \(id) could not be read and was not overwritten."
        case .documentCorrupt(let key):
            "The document '\(key)' could not be read and was not overwritten."
        }
    }

    public var errorDescription: String? { message }
}
