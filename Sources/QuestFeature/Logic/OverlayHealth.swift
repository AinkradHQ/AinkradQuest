import Foundation

/// What state the overlay store is in, as a TYPE rather than a string.
///
/// `persistenceFailure` carried three conditions distinguishable only by their
/// message text, and any later successful write cleared it — so a warning about
/// an unresolved problem could vanish before the user acted on it. A surface
/// that must disable editing needs to ask a question, not parse prose.
///
/// `.unreadable`/`.writeBlocked` carry a SET of project ids, not a single one:
/// a second corrupt project used to overwrite the first, so a cockpit asking
/// "is project X editable?" could not answer correctly from this type alone
/// and had to fall back to `OverlayStore.isUnreadable(_:)`. The set makes the
/// per-project question answerable here directly, via `isReadOnly(_:)`.
enum OverlayHealth: Equatable, Sendable {
    case healthy
    /// Project overlay documents that exist but could not be decoded. Writes
    /// for them are blocked so the corrupt bytes are not overwritten with
    /// empty state.
    case unreadable(Set<UUID>)
    /// Writes were refused because these projects are unreadable.
    case writeBlocked(Set<UUID>)
    /// An ordinary write failure. Retryable, unlike the two above, and not
    /// scoped to a single project.
    case writeFailed(String)

    /// Whether THIS project's editing should be disabled. Only an unreadable
    /// overlay is genuinely read-only; a failed write keeps the change in
    /// memory and can be retried.
    func isReadOnly(_ projectID: UUID) -> Bool {
        switch self {
        case .unreadable(let ids), .writeBlocked(let ids): ids.contains(projectID)
        case .healthy, .writeFailed: false
        }
    }

    /// Whether ANY project is currently read-only because of this state.
    /// `healthy`/`writeFailed` stay non-project-scoped, as before.
    var isReadOnly: Bool {
        switch self {
        case .unreadable(let ids), .writeBlocked(let ids): !ids.isEmpty
        case .healthy, .writeFailed: false
        }
    }

    /// Every project id this state concerns. Empty for `.healthy`/`.writeFailed`.
    var affectedProjects: Set<UUID> {
        switch self {
        case .unreadable(let ids), .writeBlocked(let ids): ids
        case .healthy, .writeFailed: []
        }
    }

    var message: String? {
        switch self {
        case .healthy: nil
        case .unreadable(let ids):
            if ids.count == 1, let only = ids.first {
                QuestError.overlayCorrupt(only).message
            } else {
                "\(ids.count) projects' saved notes could not be read and were not overwritten. "
                    + "Restore them from a backup, or discard each to start fresh."
            }
        case .writeBlocked:
            "That project's saved notes could not be read, so nothing new was saved over them. "
                + "Restore it from a backup in Quest's settings, or discard it to start fresh."
        case .writeFailed(let reason):
            "Your notes and priorities could not be saved: \(reason)"
        }
    }
}
