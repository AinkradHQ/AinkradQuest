import Foundation
import Testing

@testable import QuestFeature

@Suite("ItemQuery")
struct ItemQueryTests {
    let projectID = UUID()

    private func item(
        _ title: String, type: WorkItemType = .task, status: String = "todo",
        priority: Priority = .none, labels: [String] = [],
        due: Date? = nil
    ) -> WorkItem {
        WorkItem(
            id: UUID(), projectID: projectID, parentID: UUID(), type: type,
            title: title, statusID: status, priority: priority, labels: labels, dueDate: due)
    }

    @Test("an empty filter returns everything")
    func empty() {
        let items = [item("A"), item("B")]
        #expect(ItemQuery.apply(ItemFilter(), sort: .manual, to: items, scheme: .softwareDefault).count == 2)
    }

    @Test("text matches title case-insensitively")
    func text() {
        let items = [item("Fix auth refresh"), item("Ship board")]
        var filter = ItemFilter()
        filter.text = "AUTH"
        #expect(
            ItemQuery.apply(filter, sort: .manual, to: items, scheme: .softwareDefault).map(\.title) == [
                "Fix auth refresh"
            ])
    }

    @Test("type, status and label filters intersect")
    func intersect() {
        let items = [
            item("A", type: .bug, status: "in_progress", labels: ["backend"]),
            item("B", type: .bug, status: "todo", labels: ["backend"]),
            item("C", type: .task, status: "in_progress", labels: ["backend"]),
        ]
        var filter = ItemFilter()
        filter.types = [.bug]
        filter.statusIDs = ["in_progress"]
        filter.labels = ["backend"]
        #expect(ItemQuery.apply(filter, sort: .manual, to: items, scheme: .softwareDefault).map(\.title) == ["A"])
    }

    @Test("deleted items never appear")
    func deleted() {
        var gone = item("Gone")
        gone.deletedAt = Date()
        #expect(ItemQuery.apply(ItemFilter(), sort: .manual, to: [gone], scheme: .softwareDefault).isEmpty)
    }

    @Test("priority sort is descending, urgent first")
    func prioritySort() {
        let items = [item("low", priority: .low), item("urgent", priority: .urgent)]
        #expect(
            ItemQuery.apply(ItemFilter(), sort: .priority, to: items, scheme: .softwareDefault).map(\.title)
                == ["urgent", "low"])
    }

    @Test("due-date sort puts dated items first, earliest at the top")
    func dueSort() {
        let soon = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 9_000)
        let items = [item("undated"), item("later", due: later), item("soon", due: soon)]
        #expect(
            ItemQuery.apply(ItemFilter(), sort: .dueDate, to: items, scheme: .softwareDefault).map(\.title)
                == ["soon", "later", "undated"])
    }
}
