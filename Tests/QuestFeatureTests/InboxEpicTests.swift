import Foundation
import Testing

@testable import QuestFeature

@Suite("InboxEpic")
struct InboxEpicTests {
    private let projectID = UUID()

    private func epic(
        _ title: String, deleted: Bool = false,
        role: WorkItemRole? = nil
    ) -> WorkItem {
        WorkItem(
            id: UUID(), projectID: projectID, parentID: nil, type: .epic,
            title: title, statusID: "todo",
            deletedAt: deleted ? Date() : nil, role: role)
    }

    private func task(_ title: String, parent: UUID?) -> WorkItem {
        WorkItem(
            id: UUID(), projectID: projectID, parentID: parent, type: .task,
            title: title, statusID: "todo")
    }

    @Test("with no items at all, the caller must create the Inbox")
    func noEpics() {
        #expect(InboxEpic.resolve(in: []) == .create)
    }

    @Test("a project with tasks but no epic still creates one")
    func tasksOnly() {
        #expect(InboxEpic.resolve(in: [task("stray", parent: nil)]) == .create)
    }

    @Test("a marked Inbox is reused")
    func markedInbox() {
        let inbox = epic(InboxEpic.title, role: .inbox)
        #expect(InboxEpic.resolve(in: [epic("Platform"), inbox]) == .existing(inbox.id))
    }

    /// The whole point of the marker: the Inbox stays the Inbox after a rename,
    /// where the title-only version silently created a second one on the next
    /// capture and split the user's items across two epics.
    @Test("a marked Inbox is still found after it is renamed")
    func markedInboxSurvivesRename() {
        let inbox = epic("Captured", role: .inbox)
        #expect(InboxEpic.resolve(in: [inbox]) == .existing(inbox.id))
    }

    /// Documents written before the marker existed. Recognised by title ONCE,
    /// and the caller stamps it on the way past.
    @Test("an unmarked epic titled Inbox is adopted, not blindly reused")
    func adoptsPreMarkerInbox() {
        let inbox = epic(InboxEpic.title)
        #expect(InboxEpic.resolve(in: [epic("Platform"), inbox]) == .adopt(inbox.id))
    }

    /// Otherwise renaming a real epic to "Inbox" would hijack every capture
    /// away from the actual Inbox.
    @Test("the marker beats the title when they disagree")
    func markerBeatsTitle() {
        let marked = epic("Captured", role: .inbox)
        let impostor = epic(InboxEpic.title)
        #expect(InboxEpic.resolve(in: [impostor, marked]) == .existing(marked.id))
    }

    @Test("a soft-deleted Inbox is ignored, not reused")
    func deletedInbox() {
        #expect(InboxEpic.resolve(in: [epic(InboxEpic.title, deleted: true, role: .inbox)]) == .create)
    }

    @Test("a live Inbox wins over a soft-deleted one")
    func deletedAndLiveInbox() {
        let live = epic(InboxEpic.title, role: .inbox)
        let dead = epic(InboxEpic.title, deleted: true, role: .inbox)
        #expect(InboxEpic.resolve(in: [dead, live]) == .existing(live.id))
    }

    /// A capture must never land under a trashed epic and vanish from the list.
    @Test("a project whose only epic is soft-deleted creates a new Inbox")
    func onlyEpicDeleted() {
        #expect(InboxEpic.resolve(in: [epic("Platform", deleted: true)]) == .create)
    }

    @Test("an unrelated live epic is never borrowed as the capture target")
    func neverAnArbitraryEpic() {
        #expect(InboxEpic.resolve(in: [epic("Platform"), epic("Design")]) == .create)
    }
}

/// The migration claim, asserted rather than assumed: `role` is Optional
/// specifically so documents written before it existed still decode. Swift's
/// synthesized `init(from:)` does NOT fall back to a property's default value
/// for a missing key, so a non-optional `isInbox = false` would have made every
/// existing project file unreadable.
@Suite("WorkItem — decoding documents written before `role` existed")
struct WorkItemRoleDecodingTests {
    @Test("an item JSON with no role key decodes, with a nil role")
    func decodesWithoutRole() throws {
        let json = """
            {"id":"\(UUID().uuidString)","projectID":"\(UUID().uuidString)","type":"epic",
             "title":"Inbox","body":"","statusID":"todo","priority":0,"labels":[],
             "orderIndex":0,"links":[],
             "createdAt":0,"updatedAt":0}
            """
        let item = try JSONDecoder().decode(WorkItem.self, from: Data(json.utf8))
        #expect(item.role == nil)
        #expect(item.title == "Inbox")
    }

    @Test("a role round-trips")
    func roundTrips() throws {
        let item = WorkItem(
            id: UUID(), projectID: UUID(), parentID: nil, type: .epic,
            title: "Captured", statusID: "todo", role: .inbox)
        let decoded = try JSONDecoder().decode(
            WorkItem.self,
            from: JSONEncoder().encode(item))
        #expect(decoded.role == .inbox)
    }
}

@Suite("StatusScheme.openingStatusID")
struct OpeningStatusTests {
    @Test("the first not-done status opens a new item")
    func firstNotDone() {
        #expect(StatusScheme.softwareDefault.openingStatusID == "backlog")
    }

    @Test("a scheme without 'todo' still resolves — the editor can remove it")
    func todoRemoved() {
        let scheme = StatusScheme(
            statuses: StatusScheme.softwareDefault.statuses
                .filter { $0.id != "todo" && $0.id != "backlog" })
        #expect(scheme.openingStatusID == "in_progress")
    }

    @Test("an all-done scheme falls back to the first status")
    func allDone() {
        let scheme = StatusScheme(statuses: [
            Status(id: "shipped", name: "Shipped", category: .done, colorToken: "success")
        ])
        #expect(scheme.openingStatusID == "shipped")
    }

    @Test("an empty scheme has none, so the caller withholds the action")
    func empty() {
        #expect(StatusScheme(statuses: []).openingStatusID == nil)
    }
}
