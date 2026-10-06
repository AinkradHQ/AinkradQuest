import Foundation
import Testing

@testable import QuestFeature

@Suite("TrashListing")
struct TrashListingTests {
    private func project(_ name: String, isTrashed: Bool) -> ProjectSummary {
        ProjectSummary(
            id: UUID(), name: name, icon: "folder", colorToken: "blue",
            kind: .software, state: .active, updatedAt: Date(), isTrashed: isTrashed)
    }

    private func item(projectID: UUID, title: String, deleted: Bool) -> WorkItem {
        WorkItem(
            id: UUID(), projectID: projectID, parentID: nil, type: .task,
            title: title, statusID: "todo", deletedAt: deleted ? Date() : nil)
    }

    @Test("a trashed item whose project is still live is listed, unmarked")
    func itemInLiveProject() {
        let live = project("Optimus", isTrashed: false)
        let trashedItem = item(projectID: live.id, title: "Fix login", deleted: true)
        let liveItem = item(projectID: live.id, title: "Ship it", deleted: false)

        let entries = TrashListing.itemEntries(
            projects: [live], trashedProjects: [],
            allItems: { $0 == live.id ? [trashedItem, liveItem] : [] })

        #expect(entries.count == 1)
        #expect(entries[0].id == trashedItem.id)
        #expect(entries[0].label == "Optimus: Fix login")
    }

    @Test("a trashed item whose project is also trashed is still listed, and marked as such")
    func itemInTrashedProjectIsReachable() {
        let trashedProject = project("Legacy", isTrashed: true)
        let trashedItem = item(projectID: trashedProject.id, title: "Old bug", deleted: true)

        let entries = TrashListing.itemEntries(
            projects: [], trashedProjects: [trashedProject],
            allItems: { $0 == trashedProject.id ? [trashedItem] : [] })

        #expect(entries.count == 1)
        #expect(entries[0].id == trashedItem.id)
        #expect(entries[0].label == "Legacy (trashed): Old bug")
    }

    @Test("live items and items in projects with no deletions produce no entries")
    func noFalsePositives() {
        let live = project("Optimus", isTrashed: false)
        let liveItem = item(projectID: live.id, title: "Ship it", deleted: false)

        let entries = TrashListing.itemEntries(
            projects: [live], trashedProjects: [],
            allItems: { $0 == live.id ? [liveItem] : [] })

        #expect(entries.isEmpty)
    }

    // MARK: - through the real store

    /// Hand-built `ProjectSummary(isTrashed: true)` fixtures (above) pass even
    /// if the store never actually stamps `isTrashed` on its in-memory
    /// `trashedProjects`. These tests go through a real `ProjectStore` so a
    /// regression in that stamping — the store returning trashed summaries
    /// with `isTrashed == false` — fails here even though the pure-helper
    /// tests above would stay green.
    @MainActor
    @Test("a soft-deleted project's in-memory summary is stamped isTrashed, and its trashed item is labeled as such")
    func realStoreStampsTrashedProjectSummary() throws {
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "Legacy", kind: .general, actor: .user)
        let item = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "Old bug", statusID: "todo", actor: .user)

        try store.deleteItem(item.id, actor: .user)
        try store.deleteProject(project.id, actor: .user)

        let trashed = try #require(store.trashedProjects.first { $0.id == project.id })
        #expect(trashed.isTrashed == true)

        let entries = TrashListing.itemEntries(
            projects: store.projects,
            trashedProjects: store.trashedProjects,
            allItems: store.allItems(in:))
        let entry = try #require(entries.first { $0.id == item.id })
        #expect(entry.label == "Legacy (trashed): Old bug")
    }

    @MainActor
    @Test("the isTrashed stamp on a trashed project summary survives a relaunch")
    func relaunchStampsTrashedProjectSummary() throws {
        let repository = InMemoryProjectRepository()
        let store = makeProjectStore(repository)
        let project = store.createProject(name: "Legacy", kind: .general, actor: .user)
        try store.deleteProject(project.id, actor: .user)

        let relaunched = makeProjectStore(repository)
        let trashed = try #require(relaunched.trashedProjects.first { $0.id == project.id })
        #expect(trashed.isTrashed == true)
    }
}
