import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("ProjectStore — projects")
struct ProjectStoreProjectTests {
    private func makeStore() -> ProjectStore { makeProjectStore(InMemoryProjectRepository()) }

    @Test("creating a project indexes it and logs the creation")
    func create() {
        let store = makeStore()
        let project = store.createProject(name: "Optimus", kind: .software, actor: .user)

        #expect(store.projects.map(\.name) == ["Optimus"])
        #expect(store.activity(for: project.id).map(\.kind) == [.projectCreated])
    }

    @Test("a software project gets the software scheme")
    func scheme() {
        let store = makeStore()
        let project = store.createProject(name: "Quest", kind: .software, actor: .user)
        #expect(project.statusScheme == .softwareDefault)
    }

    @Test("updating a project persists and logs, recording the actor")
    func update() throws {
        let store = makeStore()
        var project = store.createProject(name: "Old", kind: .general, actor: .user)
        project.name = "New"

        try store.updateProject(project, actor: .agent)

        #expect(store.projects.map(\.name) == ["New"])
        #expect(store.activity(for: project.id).last?.actor == .agent)
    }

    @Test("updating an unknown project throws")
    func updateUnknown() {
        let store = makeStore()
        let ghost = Project(id: UUID(), name: "Ghost", kind: .general)
        #expect(throws: QuestError.projectNotFound(ghost.id)) {
            try store.updateProject(ghost, actor: .user)
        }
    }

    @Test("archiving hides a project from the active list without deleting it")
    func archive() throws {
        let store = makeStore()
        let project = store.createProject(name: "Done", kind: .general, actor: .user)

        try store.archiveProject(project.id, actor: .user)

        #expect(store.activeProjects.isEmpty)
        #expect(store.projects.count == 1)
        #expect(store.openProject(project.id)?.project.state == .archived)
    }

    @Test("deleting is soft and restorable")
    func softDelete() throws {
        let store = makeStore()
        let project = store.createProject(name: "Oops", kind: .general, actor: .agent)

        try store.deleteProject(project.id, actor: .agent)
        #expect(store.projects.isEmpty)
        #expect(store.trashedProjects.map(\.name) == ["Oops"])

        try store.restoreProject(project.id, actor: .user)
        #expect(store.projects.map(\.name) == ["Oops"])
    }

    @Test("a soft-deleted project stays trashed across a relaunch")
    func trashSurvivesRelaunch() throws {
        let repository = InMemoryProjectRepository()
        let store = makeProjectStore(repository)
        let project = store.createProject(name: "Persisted Oops", kind: .general, actor: .agent)

        try store.deleteProject(project.id, actor: .agent)

        let relaunched = makeProjectStore(repository)
        #expect(relaunched.projects.isEmpty)
        #expect(relaunched.trashedProjects.map(\.name) == ["Persisted Oops"])

        try relaunched.restoreProject(project.id, actor: .user)
        #expect(relaunched.projects.map(\.name) == ["Persisted Oops"])
    }

    @Test("a trashed project survives unrelated commits after a relaunch")
    func trashSurvivesUnrelatedCommitsAfterRelaunch() throws {
        let repository = InMemoryProjectRepository()
        let store = makeProjectStore(repository)
        let trashed = store.createProject(name: "Trashed A", kind: .general, actor: .user)
        let other = store.createProject(name: "Live B", kind: .general, actor: .user)
        try store.deleteProject(trashed.id, actor: .user)

        // Relaunch: nothing is open, everything comes from the index.
        let relaunched = makeProjectStore(repository)
        #expect(relaunched.trashedProjects.map(\.name) == ["Trashed A"])

        // An unrelated write must not evict the trashed project from memory…
        var renamed = other
        renamed.name = "Live B renamed"
        try relaunched.updateProject(renamed, actor: .user)
        #expect(relaunched.trashedProjects.map(\.name) == ["Trashed A"])

        // …nor from the index on disk, even after several more relaunches.
        let again = makeProjectStore(repository)
        try again.updateProject(renamed, actor: .user)
        let third = makeProjectStore(repository)
        #expect(third.trashedProjects.map(\.name) == ["Trashed A"])
        #expect(third.projects.map(\.name) == ["Live B renamed"])
        #expect(repository.loadIndex().count == 2)

        try third.restoreProject(trashed.id, actor: .user)
        #expect(third.trashedProjects.isEmpty)
        #expect(third.projects.map(\.name).sorted() == ["Live B renamed", "Trashed A"])
    }

    @Test("a dropped save to an ALREADY-CREATED project still surfaces a failure")
    func persistenceFailureOnExistingProject() throws {
        let repository = FailingSaveProjectRepository()
        repository.failSaves = false
        let store = makeProjectStore(repository)
        var project = store.createProject(name: "Saved", kind: .general, actor: .user)
        #expect(store.persistenceFailure == nil)

        // The document already exists on disk, so a stale load looks like success.
        repository.failSaves = true
        project.name = "Renamed"
        try store.updateProject(project, actor: .user)

        #expect(store.persistenceFailure != nil)
        #expect(store.projects.map(\.name) == ["Renamed"])

        repository.failSaves = false
        try store.updateProject(project, actor: .user)
        #expect(store.persistenceFailure == nil)
    }

    @Test("a failed save keeps the in-memory change and surfaces persistenceFailure")
    func persistenceFailureSurfaces() {
        let repository = FailingSaveProjectRepository()
        let store = makeProjectStore(repository)

        let project = store.createProject(name: "Unsaved", kind: .general, actor: .user)

        #expect(store.projects.map(\.name) == ["Unsaved"])
        #expect(store.persistenceFailure != nil)

        repository.failSaves = false
        try? store.updateProject(project, actor: .user)

        #expect(store.persistenceFailure == nil)
    }

    @Test("a project can be paused and appears only in the paused list")
    func pause() throws {
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "Later", kind: .general, actor: .user)

        try store.setState(project.id, state: .paused, actor: .user)

        #expect(store.activeProjects.isEmpty)
        #expect(store.projects(inState: .paused).map(\.name) == ["Later"])
        #expect(store.projects.count == 1)
        #expect(store.openProject(project.id)?.project.state == .paused)
    }

    @Test("state changes are logged with the actor")
    func stateLogged() throws {
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "P", kind: .general, actor: .user)

        try store.setState(project.id, state: .archived, actor: .agent)

        let event = store.activity(for: project.id).last
        #expect(event?.kind == .projectUpdated)
        #expect(event?.actor == .agent)
        #expect(store.projects(inState: .archived).map(\.name) == ["P"])
    }

    @Test("state survives a relaunch")
    func statePersists() throws {
        let repository = InMemoryProjectRepository()
        let store = makeProjectStore(repository)
        let project = store.createProject(name: "P", kind: .general, actor: .user)
        try store.setState(project.id, state: .paused, actor: .user)

        let reopened = makeProjectStore(repository)
        #expect(reopened.projects(inState: .paused).map(\.name) == ["P"])
    }

    @Test("setting a project back to active clears an archive stamp")
    func reactivate() throws {
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "P", kind: .general, actor: .user)
        try store.setState(project.id, state: .archived, actor: .user)

        try store.setState(project.id, state: .active, actor: .user)

        #expect(store.activeProjects.map(\.name) == ["P"])
        #expect(store.openProject(project.id)?.project.archivedAt == nil)
    }

    // MARK: - purge

    @Test("purging a trashed project removes it from the trash and from disk")
    func purge() throws {
        let repository = InMemoryProjectRepository()
        let store = makeProjectStore(repository)
        let project = store.createProject(name: "Legacy", kind: .general, actor: .user)
        try store.deleteProject(project.id, actor: .user)

        let before = store.revision
        try store.purgeProject(project.id)
        // `revision` is what every view observes to redraw. A purge that
        // removed a project without advancing it would leave the trash
        // rendering a row that no longer exists.
        #expect(store.revision > before)

        #expect(store.trashedProjects.isEmpty)
        #expect(store.projects.isEmpty)
        #expect(store.openProject(project.id) == nil)

        let relaunched = makeProjectStore(repository)
        #expect(relaunched.trashedProjects.isEmpty)
        #expect(relaunched.projects.isEmpty)
    }

    /// Purge is irreversible, so it must refuse anything the user has not
    /// already moved to the trash — a live project can never be lost to a
    /// mis-routed purge call.
    @Test("purging a live project throws and leaves it alone")
    func purgeLiveProjectRefused() throws {
        let store = makeStore()
        let project = store.createProject(name: "Optimus", kind: .general, actor: .user)

        let before = store.revision
        #expect(throws: QuestError.projectNotInTrash(project.id)) {
            try store.purgeProject(project.id)
        }
        #expect(store.projects.map(\.name) == ["Optimus"])
        // The counter's contract: it advances only for a mutation that passed
        // validation and was applied in memory. A refused purge changed
        // nothing, so a bump here would be a redraw advertising a write that
        // never happened.
        #expect(store.revision == before)
    }

    @Test("purging an unknown project throws")
    func purgeUnknown() {
        let store = makeStore()
        let id = UUID()
        #expect(throws: QuestError.projectNotInTrash(id)) {
            try store.purgeProject(id)
        }
    }
}
