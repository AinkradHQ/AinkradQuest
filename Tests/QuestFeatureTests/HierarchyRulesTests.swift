import Foundation
import Testing

@testable import QuestFeature

@Suite("HierarchyRules")
struct HierarchyRulesTests {
    let projectID = UUID()
    let epicID = UUID()
    let itemID = UUID()
    let subtaskID = UUID()

    var items: [WorkItem] {
        [
            WorkItem(
                id: epicID, projectID: projectID, parentID: nil, type: .epic,
                title: "Epic", statusID: "todo"),
            WorkItem(
                id: itemID, projectID: projectID, parentID: epicID, type: .task,
                title: "Item", statusID: "todo"),
            WorkItem(
                id: subtaskID, projectID: projectID, parentID: itemID, type: .task,
                title: "Subtask", statusID: "todo"),
        ]
    }

    @Test("depth counts from one at the epic")
    func depth() {
        #expect(HierarchyRules.depth(of: nil, in: items) == 0)
        #expect(HierarchyRules.depth(of: epicID, in: items) == 1)
        #expect(HierarchyRules.depth(of: subtaskID, in: items) == 3)
    }

    @Test("a fourth level is rejected")
    func depthCap() {
        #expect(throws: QuestError.depthExceeded(attempted: 4, maximum: 3)) {
            try HierarchyRules.validate(
                parentID: subtaskID, type: .task,
                movingItemID: nil, in: items)
        }
    }

    @Test("an epic may not have a parent")
    func epicAtRoot() {
        #expect(throws: QuestError.epicMustBeRoot) {
            try HierarchyRules.validate(
                parentID: epicID, type: .epic,
                movingItemID: nil, in: items)
        }
    }

    @Test("a non-epic may not sit at the top level")
    func nonEpicNeedsParent() {
        #expect(throws: QuestError.nonEpicMustHaveParent) {
            try HierarchyRules.validate(
                parentID: nil, type: .task,
                movingItemID: nil, in: items)
        }
    }

    @Test("an unknown parent is rejected")
    func unknownParent() {
        let ghost = UUID()
        #expect(throws: QuestError.parentNotFound(ghost)) {
            try HierarchyRules.validate(
                parentID: ghost, type: .task,
                movingItemID: nil, in: items)
        }
    }

    @Test("an item cannot be moved under its own descendant")
    func cycle() {
        #expect(throws: QuestError.cyclicParent) {
            try HierarchyRules.validate(
                parentID: subtaskID, type: .task,
                movingItemID: itemID, in: items)
        }
    }

    @Test("a soft-deleted parent is refused")
    func deletedParentRefused() {
        var deletedEpic = WorkItem(
            id: epicID, projectID: projectID, parentID: nil,
            type: .epic, title: "Epic", statusID: "todo")
        deletedEpic.deletedAt = Date()
        let items = [deletedEpic]

        #expect(throws: QuestError.parentIsDeleted(epicID)) {
            try HierarchyRules.validate(
                parentID: epicID, type: .task,
                movingItemID: nil, in: items)
        }
    }

    @Test("a live parent is still accepted")
    func liveParentAccepted() throws {
        try HierarchyRules.validate(
            parentID: epicID, type: .task,
            movingItemID: nil, in: items)
    }

    @Test("a legal placement throws nothing")
    func legal() throws {
        try HierarchyRules.validate(parentID: itemID, type: .bug, movingItemID: nil, in: items)
    }

    @Test("descendants are collected transitively")
    func descendants() {
        #expect(
            Set(HierarchyRules.descendants(of: epicID, in: items).map(\.id))
                == Set([itemID, subtaskID]))
    }
}
