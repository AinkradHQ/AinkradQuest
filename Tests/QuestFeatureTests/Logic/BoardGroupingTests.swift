import Foundation
import Testing

@testable import QuestFeature

@Suite("BoardGrouping")
struct BoardGroupingTests {
    let projectID = UUID()

    private func item(_ title: String, status: String) -> WorkItem {
        WorkItem(
            id: UUID(), projectID: projectID, parentID: UUID(), type: .task,
            title: title, statusID: status)
    }

    @Test("columns follow scheme order, including empty ones")
    func columnOrder() {
        let columns = BoardGrouping.columns(
            items: [item("A", status: "done")],
            scheme: .softwareDefault, filter: ItemFilter())
        #expect(columns.map(\.status.id) == ["backlog", "todo", "in_progress", "in_review", "done"])
        #expect(columns.last?.items.map(\.title) == ["A"])
        #expect(columns.first?.items.isEmpty == true)
    }

    @Test("an item whose status is not in the scheme is dropped rather than crashing")
    func orphanStatus() throws {
        let columns = BoardGrouping.columns(
            items: [item("Orphan", status: "ghost")],
            scheme: .softwareDefault, filter: ItemFilter())
        try #expect(columns.allSatisfy(\.items.isEmpty))
    }

    @Test("epics are excluded — the board shows work, not containers")
    func epicsExcluded() throws {
        let epic = WorkItem(
            id: UUID(), projectID: projectID, parentID: nil, type: .epic,
            title: "E", statusID: "todo")
        let columns = BoardGrouping.columns(
            items: [epic], scheme: .softwareDefault,
            filter: ItemFilter())
        try #expect(columns.allSatisfy(\.items.isEmpty))
    }

    @Test("grouping returns one group per epic, each with the full column set")
    func groupsByEpic() {
        let epicA = UUID()
        let epicB = UUID()
        let items = [
            WorkItem(
                id: epicA, projectID: projectID, parentID: nil, type: .epic,
                title: "A", statusID: "todo"),
            WorkItem(
                id: epicB, projectID: projectID, parentID: nil, type: .epic,
                title: "B", statusID: "todo"),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: epicA, type: .task,
                title: "A1", statusID: "in_progress"),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: epicB, type: .task,
                title: "B1", statusID: "done"),
        ]

        let groups = BoardGrouping.groupedByEpic(
            items: items, scheme: .softwareDefault,
            filter: ItemFilter())

        #expect(groups.map(\.epic.title) == ["A", "B"])
        #expect(groups[0].columns.count == StatusScheme.softwareDefault.statuses.count)
        #expect(
            groups[0].columns.first { $0.status.id == "in_progress" }?.items.map(\.title)
                == ["A1"])
        #expect(groups[1].columns.first { $0.status.id == "done" }?.items.map(\.title) == ["B1"])
    }

    @Test("an epic with no children still appears, with empty columns")
    func emptyEpicAppears() throws {
        let epic = UUID()
        let groups = BoardGrouping.groupedByEpic(
            items: [
                WorkItem(
                    id: epic, projectID: projectID, parentID: nil, type: .epic,
                    title: "Lonely", statusID: "todo")
            ],
            scheme: .softwareDefault, filter: ItemFilter())

        #expect(groups.map(\.epic.title) == ["Lonely"])
        try #expect(groups[0].columns.allSatisfy(\.items.isEmpty))
    }

    @Test("a subtask appears under its epic, not its parent item")
    func subtaskGroupsUnderEpic() {
        let epic = UUID()
        let item = UUID()
        let items = [
            WorkItem(
                id: epic, projectID: projectID, parentID: nil, type: .epic,
                title: "E", statusID: "todo"),
            WorkItem(
                id: item, projectID: projectID, parentID: epic, type: .task,
                title: "I", statusID: "todo"),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: item, type: .task,
                title: "S", statusID: "todo"),
        ]

        let groups = BoardGrouping.groupedByEpic(
            items: items, scheme: .softwareDefault,
            filter: ItemFilter())

        #expect(groups.count == 1)
        #expect(
            groups[0].columns.first { $0.status.id == "todo" }?.items.map(\.title).sorted()
                == ["I", "S"])
    }

    @Test("soft-deleted epics are not grouped")
    func deletedEpicExcluded() {
        var epic = WorkItem(
            id: UUID(), projectID: projectID, parentID: nil, type: .epic,
            title: "Gone", statusID: "todo")
        epic.deletedAt = Date()
        #expect(
            BoardGrouping.groupedByEpic(
                items: [epic], scheme: .softwareDefault,
                filter: ItemFilter()
            ).isEmpty)
    }

    @Test("a live item left under a soft-deleted epic surfaces in a trailing No-epic group, not dropped")
    func liveItemUnderDeletedEpicSurfacesAsOrphan() throws {
        var epic = WorkItem(
            id: UUID(), projectID: projectID, parentID: nil, type: .epic,
            title: "Gone", statusID: "todo")
        epic.deletedAt = Date()
        let orphan = WorkItem(
            id: UUID(), projectID: projectID, parentID: epic.id, type: .task,
            title: "Orphan", statusID: "todo")

        let groups = BoardGrouping.groupedByEpic(
            items: [epic, orphan], scheme: .softwareDefault,
            filter: ItemFilter())

        #expect(groups.count == 1)
        #expect(groups[0].isOrphanGroup)
        #expect(groups[0].epic.id != epic.id)
        #expect(groups[0].epic.title == "No epic")
        try #expect(
            groups[0].columns.first { $0.status.id == "todo" }?.items.map(\.title)
                == ["Orphan"])
    }
}
