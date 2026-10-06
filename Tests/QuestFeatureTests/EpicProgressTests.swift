import Foundation
import Testing

@testable import QuestFeature

@Suite("EpicProgress")
struct EpicProgressTests {
    let projectID = UUID()

    @Test("progress counts done descendants against all descendants")
    func rollup() {
        let epicID = UUID()
        let childID = UUID()
        let items = [
            WorkItem(
                id: epicID, projectID: projectID, parentID: nil, type: .epic,
                title: "E", statusID: "todo"),
            WorkItem(
                id: childID, projectID: projectID, parentID: epicID, type: .task,
                title: "A", statusID: "done"),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: epicID, type: .task,
                title: "B", statusID: "todo"),
            WorkItem(
                id: UUID(), projectID: projectID, parentID: childID, type: .task,
                title: "A1", statusID: "done"),
        ]

        let progress = EpicProgress.rollup(epicID: epicID, in: items, scheme: .softwareDefault)
        #expect(progress.done == 2)
        #expect(progress.total == 3)
    }

    @Test("an epic with no children reports zero of zero and a zero fraction")
    func empty() {
        let epicID = UUID()
        let items = [
            WorkItem(
                id: epicID, projectID: projectID, parentID: nil, type: .epic,
                title: "E", statusID: "todo")
        ]
        let progress = EpicProgress.rollup(epicID: epicID, in: items, scheme: .softwareDefault)
        #expect(progress.total == 0)
        #expect(progress.fraction == 0)
    }

    @Test("deleted children are excluded from both counts")
    func deleted() {
        let epicID = UUID()
        var gone = WorkItem(
            id: UUID(), projectID: projectID, parentID: epicID, type: .task,
            title: "gone", statusID: "todo")
        gone.deletedAt = Date()
        let items = [
            WorkItem(
                id: epicID, projectID: projectID, parentID: nil, type: .epic,
                title: "E", statusID: "todo"),
            gone,
        ]
        #expect(EpicProgress.rollup(epicID: epicID, in: items, scheme: .softwareDefault).total == 0)
    }
}
