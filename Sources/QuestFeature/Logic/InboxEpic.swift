import Foundation

/// Where a quick capture files itself. Extracted because `TodaySurface` and
/// `ListSurface` each had their own copy and they had already diverged: one
/// filtered soft-deleted epics and created an Inbox, the other fell back to
/// `epics.first` and could file a capture under a soft-deleted epic, where it
/// vanished from every list. Two surfaces disagreeing about where the user's
/// item went is worse than the duplication that caused it.
///
/// Pure and Foundation-only, like its neighbours: it decides, the caller
/// writes. Creation is the caller's job because only it holds the store and
/// the project's opening status.
enum InboxEpic {
    /// The title given to an Inbox this app creates, and the fallback used to
    /// recognise one written before `WorkItemRole` existed. It is no longer the
    /// marker — `role == .inbox` is — so renaming the Inbox now keeps it the
    /// Inbox instead of silently spawning a second one on the next capture.
    static let title = "Inbox"

    enum Resolution: Equatable, Sendable {
        /// File under this existing, live, marked Inbox epic.
        case existing(UUID)
        /// A pre-marker Inbox, recognised by title alone. The caller files under
        /// it AND stamps the role, so this is the last time that document is
        /// identified by a string the user is free to change.
        ///
        /// Adoption is lazy rather than a migration pass at load: a bulk rewrite
        /// would touch documents the user never opened, and a persist failure
        /// there would surface with no action to attach it to.
        case adopt(UUID)
        /// No live Inbox epic exists — the caller must create one titled
        /// `InboxEpic.title` at the root, marked `.inbox`. Never "use whatever
        /// epic sorts first": that puts the item somewhere the user did not
        /// choose and would not think to look.
        case create
    }

    /// `items` may include soft-deleted ones (`ProjectDocument.items` does);
    /// deleted epics are ignored, so a trashed Inbox is replaced rather than
    /// swallowing new captures.
    static func resolve(in items: [WorkItem]) -> Resolution {
        let epics = items.filter { $0.type == .epic && !$0.isDeleted }
        // The marker wins over the title, always — including when some OTHER
        // epic has since been renamed to "Inbox". A rename of a real epic must
        // not hijack where captures land.
        if let marked = epics.first(where: { $0.role == .inbox }) { return .existing(marked.id) }
        if let byTitle = epics.first(where: { $0.title == title }) { return .adopt(byTitle.id) }
        return .create
    }
}
