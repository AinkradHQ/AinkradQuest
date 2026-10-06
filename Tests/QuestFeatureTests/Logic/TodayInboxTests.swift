import Foundation
import Testing

@testable import QuestFeature

@Suite("TodayInbox")
struct TodayInboxTests {
    let projectID = UUID()
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(
        _ title: String, status: String = "todo",
        due: Date? = nil, updated: Date? = nil
    ) -> WorkItem {
        WorkItem(
            id: UUID(), projectID: projectID, parentID: UUID(), type: .task,
            title: title, statusID: status, dueDate: due,
            updatedAt: updated ?? Date(timeIntervalSince1970: 0))
    }

    @Test("an item due before now is overdue")
    func overdue() {
        let result = TodayInbox.build(
            items: [item("Late", due: now.addingTimeInterval(-86_400))],
            scheme: .softwareDefault, now: now)
        #expect(result.overdue.map(\.title) == ["Late"])
    }

    @Test("an item due on the same day is due today, not overdue")
    func dueToday() {
        let result = TodayInbox.build(
            items: [item("Now", due: now.addingTimeInterval(60))],
            scheme: .softwareDefault, now: now)
        #expect(result.dueToday.map(\.title) == ["Now"])
        #expect(result.overdue.isEmpty)
    }

    @Test("active items are those in an active-category status")
    func active() {
        let result = TodayInbox.build(
            items: [item("Doing", status: "in_progress")],
            scheme: .softwareDefault, now: now)
        #expect(result.active.map(\.title) == ["Doing"])
    }

    @Test("done items never appear in any section")
    func doneExcluded() {
        let result = TodayInbox.build(
            items: [item("Shipped", status: "done", due: now.addingTimeInterval(-86_400))],
            scheme: .softwareDefault, now: now)
        #expect(result.overdue.isEmpty)
        #expect(result.active.isEmpty)
        #expect(result.recent.isEmpty)
    }

    @Test("recent is capped at ten, most recently updated first")
    func recent() {
        let items = (0..<15).map { index in
            item("Item \(index)", updated: now.addingTimeInterval(Double(index)))
        }
        let result = TodayInbox.build(items: items, scheme: .softwareDefault, now: now)
        #expect(result.recent.count == 10)
        #expect(result.recent.first?.title == "Item 14")
    }
}
