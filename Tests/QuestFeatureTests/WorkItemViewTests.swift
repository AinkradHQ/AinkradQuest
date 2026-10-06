import Foundation
import Testing

@testable import QuestFeature

@Suite("WorkItemView")
struct WorkItemViewTests {
    private func makeItem(_ projectID: UUID, title: String) -> WorkItem {
        WorkItem(
            id: UUID(), projectID: projectID, parentID: nil, type: .task,
            title: title, statusID: "todo")
    }

    @Test("a native item joins to an empty overlay and no remote ref")
    func nativeItem() {
        let projectID = UUID()
        let item = makeItem(projectID, title: "Local work")
        let views = WorkItemViewBuilder.build(
            items: [item],
            overlay: ProjectOverlay(projectID: projectID),
            linkMap: LinkMap())

        #expect(views.count == 1)
        #expect(views[0].title == "Local work")
        #expect(views[0].notes.isEmpty)
        #expect(views[0].remoteRef == nil)
        #expect(views[0].isLinked == false)
    }

    @Test("overlay content is joined onto the matching item")
    func joinsOverlay() {
        let projectID = UUID()
        let item = makeItem(projectID, title: "Has notes")
        var overlay = ProjectOverlay(projectID: projectID)
        var itemOverlay = ItemOverlay()
        itemOverlay.notes = "private thinking"
        itemOverlay.personalOrder = 1
        itemOverlay.timeEntries = [
            TimeEntry(id: UUID(), minutes: 30, spentOn: Date(timeIntervalSince1970: 1_756_000_000)),
            TimeEntry(id: UUID(), minutes: 15, spentOn: Date(timeIntervalSince1970: 1_756_000_000)),
        ]
        overlay.setItem(itemOverlay, for: item.id)

        let views = WorkItemViewBuilder.build(items: [item], overlay: overlay, linkMap: LinkMap())

        #expect(views[0].notes == "private thinking")
        #expect(views[0].personalOrder == 1)
        #expect(views[0].loggedMinutes == 45)
    }

    @Test("a mirrored item carries its remote ref")
    func joinsRemoteRef() {
        let projectID = UUID()
        let item = makeItem(projectID, title: "From Jira")
        var map = LinkMap()
        let ref = RemoteRef(connectionID: UUID(), remoteKey: "QST-42")
        map.link(ref, to: item.id)

        let views = WorkItemViewBuilder.build(
            items: [item],
            overlay: ProjectOverlay(projectID: projectID),
            linkMap: map)

        #expect(views[0].remoteRef == ref)
        #expect(views[0].isLinked)
    }

    @Test("an overlay row for an item that no longer exists is ignored")
    func orphanedOverlayRow() {
        let projectID = UUID()
        let item = makeItem(projectID, title: "Still here")
        var overlay = ProjectOverlay(projectID: projectID)
        overlay.setItem(ItemOverlay(notes: "orphan"), for: UUID())

        let views = WorkItemViewBuilder.build(items: [item], overlay: overlay, linkMap: LinkMap())

        // The join is driven by ITEMS, not by overlay rows: a purged item must
        // not resurrect as a phantom row with notes and no title.
        #expect(views.count == 1)
        #expect(views[0].title == "Still here")
    }

    @Test("item order is preserved exactly as given")
    func preservesOrder() {
        let projectID = UUID()
        let items = ["a", "b", "c"].map { makeItem(projectID, title: $0) }

        let views = WorkItemViewBuilder.build(
            items: items,
            overlay: ProjectOverlay(projectID: projectID),
            linkMap: LinkMap())

        // Ordering is the caller's business — the surfaces already sort. The
        // join must not quietly reorder.
        #expect(views.map(\.title) == ["a", "b", "c"])
    }
}
