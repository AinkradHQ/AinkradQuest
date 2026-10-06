import Foundation
import Testing

@testable import QuestFeature

@Suite("TimelineLayout")
struct TimelineLayoutTests {
    let projectID = UUID()
    let day = 86_400.0

    private func item(_ title: String, start: Double?, due: Double?) -> WorkItem {
        WorkItem(
            id: UUID(), projectID: projectID, parentID: UUID(), type: .task,
            title: title, statusID: "todo",
            startDate: start.map { Date(timeIntervalSince1970: $0) },
            dueDate: due.map { Date(timeIntervalSince1970: $0) })
    }

    @Test("overlapping bars get separate lanes; disjoint bars share one")
    func lanes() {
        let result = TimelineLayout.build(items: [
            item("A", start: 0, due: 2 * day),
            item("B", start: day, due: 3 * day),
            item("C", start: 10 * day, due: 11 * day),
        ])

        let lanes = Dictionary(uniqueKeysWithValues: result.bars.map { ($0.title, $0.lane) })
        #expect(lanes["A"] == 0)
        #expect(lanes["B"] == 1)
        #expect(lanes["C"] == 0)
    }

    @Test("an item with only a due date becomes a same-day bar")
    func dueOnly() {
        let result = TimelineLayout.build(items: [item("D", start: nil, due: day)])
        #expect(result.bars.count == 1)
        #expect(result.bars[0].start == result.bars[0].end)
    }

    @Test("dateless items go to the unscheduled rail rather than vanishing")
    func unscheduled() {
        let result = TimelineLayout.build(items: [item("U", start: nil, due: nil)])
        #expect(result.bars.isEmpty)
        #expect(result.unscheduled.map(\.title) == ["U"])
    }

    @Test("an undated epic spans its scheduled children")
    func epicSpansChildren() {
        let epicID = UUID()
        let items = [
            WorkItem(
                id: epicID, projectID: projectID, parentID: nil, type: .epic,
                title: "E", statusID: "todo"),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: epicID, type: .task,
                title: "A", statusID: "todo",
                startDate: Date(timeIntervalSince1970: day),
                dueDate: Date(timeIntervalSince1970: 2 * day)),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: epicID, type: .task,
                title: "B", statusID: "todo",
                startDate: Date(timeIntervalSince1970: 5 * day),
                dueDate: Date(timeIntervalSince1970: 6 * day)),
        ]

        let result = TimelineLayout.build(items: items)
        let epicBar = result.bars.first { $0.itemID == epicID }

        #expect(epicBar?.start == Date(timeIntervalSince1970: day))
        #expect(epicBar?.end == Date(timeIntervalSince1970: 6 * day))
        #expect(epicBar?.isDerived == true)
        #expect(!result.unscheduled.contains { $0.id == epicID })
    }

    @Test("an epic with its own dates keeps them")
    func epicKeepsOwnDates() {
        let epicID = UUID()
        let items = [
            WorkItem(
                id: epicID, projectID: projectID, parentID: nil, type: .epic,
                title: "E", statusID: "todo",
                startDate: Date(timeIntervalSince1970: 0),
                dueDate: Date(timeIntervalSince1970: day)),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: epicID, type: .task,
                title: "A", statusID: "todo",
                startDate: Date(timeIntervalSince1970: 10 * day),
                dueDate: Date(timeIntervalSince1970: 11 * day)),
        ]

        let epicBar = TimelineLayout.build(items: items).bars.first { $0.itemID == epicID }
        #expect(epicBar?.end == Date(timeIntervalSince1970: day))
        #expect(epicBar?.isDerived == false)
    }

    @Test("an epic whose children are all undated stays unscheduled")
    func epicWithoutDatedChildren() {
        let epicID = UUID()
        let items = [
            WorkItem(
                id: epicID, projectID: projectID, parentID: nil, type: .epic,
                title: "E", statusID: "todo"),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: epicID, type: .task,
                title: "A", statusID: "todo"),
        ]

        let result = TimelineLayout.build(items: items)
        #expect(result.bars.isEmpty)
        #expect(result.unscheduled.map(\.title).sorted() == ["A", "E"])
    }

    @Test("deleted descendants do not contribute to a derived span")
    func deletedChildrenExcluded() {
        let epicID = UUID()
        var deleted = WorkItem(
            id: UUID(), projectID: projectID, parentID: epicID, type: .task,
            title: "gone", statusID: "todo",
            startDate: Date(timeIntervalSince1970: 100 * day),
            dueDate: Date(timeIntervalSince1970: 101 * day))
        deleted.deletedAt = Date()
        let items = [
            WorkItem(
                id: epicID, projectID: projectID, parentID: nil, type: .epic,
                title: "E", statusID: "todo"),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: epicID, type: .task,
                title: "A", statusID: "todo",
                startDate: Date(timeIntervalSince1970: day),
                dueDate: Date(timeIntervalSince1970: 2 * day)),
            deleted,
        ]

        let epicBar = TimelineLayout.build(items: items).bars.first { $0.itemID == epicID }
        #expect(epicBar?.end == Date(timeIntervalSince1970: 2 * day))
    }
}
