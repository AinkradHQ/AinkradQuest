import Foundation
import Testing

@testable import QuestFeature

@Suite("ProjectStore.revision")
@MainActor
struct StoreRevisionTests {
    @Test("a fresh store starts at zero")
    func initial() {
        #expect(makeProjectStore(InMemoryProjectRepository()).revision == 0)
    }

    @Test("creating a project bumps the revision")
    func createProject() {
        let store = makeProjectStore(InMemoryProjectRepository())
        let before = store.revision
        _ = store.createProject(name: "A", kind: .software, actor: .user)
        #expect(store.revision > before)
    }

    @Test("editing an item inside a loaded document bumps the revision")
    func editItem() throws {
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "A", kind: .software, actor: .user)
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        let before = store.revision
        try store.setStatus(epic.id, statusID: "done", actor: .user)
        #expect(store.revision > before)
    }

    @Test("the revision never decreases across a mixed sequence of writes")
    func monotonic() throws {
        let store = makeProjectStore(InMemoryProjectRepository())
        var seen = store.revision
        let project = store.createProject(name: "A", kind: .software, actor: .user)
        for index in 0..<5 {
            _ = try store.createItem(
                projectID: project.id, parentID: nil, type: .epic,
                title: "E\(index)", statusID: "todo", actor: .user)
            #expect(store.revision >= seen)
            seen = store.revision
        }
    }

    @Test("a rejected write does not bump the revision")
    func rejectedWrite() {
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "A", kind: .software, actor: .user)
        let before = store.revision
        // A task at root has no parent, which `HierarchyRules.validate` refuses
        // via `nonEpicMustHaveParent` — a genuinely-rejected write.
        #expect(throws: (any Error).self) {
            _ = try store.createItem(
                projectID: project.id, parentID: nil, type: .task,
                title: "orphan", statusID: "todo", actor: .user)
        }
        #expect(store.revision == before)
    }

    @Test("a mutation whose persist fails still bumps the revision")
    func failedPersistStillBumps() {
        let repository = FailingSaveProjectRepository()
        let store = makeProjectStore(repository)
        let before = store.revision
        _ = store.createProject(name: "A", kind: .software, actor: .user)
        #expect(store.revision > before)
        #expect(store.persistenceFailure != nil)
    }
}
