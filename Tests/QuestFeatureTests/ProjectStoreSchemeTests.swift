import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("ProjectStore — scheme")
struct ProjectStoreSchemeTests {
    private func makeStore() -> (ProjectStore, Project) {
        let store = makeProjectStore(InMemoryProjectRepository())
        return (store, store.createProject(name: "Quest", kind: .software, actor: .user))
    }

    private func planRemovingReview(_ store: ProjectStore, _ project: Project)
        -> SchemePlan.Plan?
    {
        var proposed = StatusScheme.softwareDefault
        proposed.statuses.removeAll { $0.id == "in_review" }
        return SchemePlan.plan(
            current: .softwareDefault, proposed: proposed,
            reassignments: ["in_review": "todo"],
            items: store.allItems(in: project.id)
        ).value
    }

    @Test("applying a plan rewrites the scheme and reassigns items")
    func apply() throws {
        let (store, project) = makeStore()
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        let item = try store.createItem(
            projectID: project.id, parentID: epic.id, type: .task,
            title: "T", statusID: "in_review", actor: .user)
        let plan = try #require(planRemovingReview(store, project))

        try store.applyScheme(plan, to: project.id, actor: .user)

        let scheme = try #require(store.openProject(project.id)?.project.statusScheme)
        #expect(scheme.status(id: "in_review") == nil)
        #expect(store.items(in: project.id).first { $0.id == item.id }?.statusID == "todo")
    }

    @Test("exactly one activity event is appended, of kind schemeUpdated")
    func logsOnce() throws {
        let (store, project) = makeStore()
        let before = store.activity(for: project.id).count
        let plan = try #require(planRemovingReview(store, project))

        try store.applyScheme(plan, to: project.id, actor: .agent)

        let events = store.activity(for: project.id)
        #expect(events.count == before + 1)
        #expect(events.last?.kind == .schemeUpdated)
        #expect(events.last?.actor == .agent)
    }

    @Test("moving a status into done stamps closedAt; moving out clears it")
    func categoryRestamp() throws {
        let (store, project) = makeStore()
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)

        var toDone = StatusScheme.softwareDefault
        toDone.statuses[3] = Status(
            id: "in_review", name: "In Review",
            category: .done, colorToken: "success")
        let closing = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: toDone, reassignments: [:],
                items: store.allItems(in: project.id)
            ).value)
        try store.applyScheme(closing, to: project.id, actor: .user)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.closedAt != nil)

        let backOut = try #require(
            SchemePlan.plan(
                current: toDone, proposed: .softwareDefault, reassignments: [:],
                items: store.allItems(in: project.id)
            ).value)
        try store.applyScheme(backOut, to: project.id, actor: .user)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.closedAt == nil)
    }

    @Test("soft-deleted items are reassigned too, so a restore cannot dangle")
    func reassignsDeletedItems() throws {
        let (store, project) = makeStore()
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)
        try store.deleteItem(epic.id, actor: .user)
        let plan = try #require(planRemovingReview(store, project))

        try store.applyScheme(plan, to: project.id, actor: .user)

        #expect(store.allItems(in: project.id).first { $0.id == epic.id }?.statusID == "todo")
    }

    @Test("the change survives a relaunch")
    func persists() throws {
        let repository = InMemoryProjectRepository()
        let store = makeProjectStore(repository)
        let project = store.createProject(name: "Q", kind: .software, actor: .user)
        let plan = try #require(planRemovingReview(store, project))
        try store.applyScheme(plan, to: project.id, actor: .user)

        let reopened = makeProjectStore(repository)
        #expect(reopened.openProject(project.id)?.project.statusScheme.status(id: "in_review") == nil)
    }

    @Test("a revert plan diffs against the CURRENT store scheme, not a stale pre-session copy")
    func revertPlansAgainstCurrentScheme() throws {
        let (store, project) = makeStore()
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)

        // First apply: move in_review into .done.
        var toDone = StatusScheme.softwareDefault
        toDone.statuses[3] = Status(
            id: "in_review", name: "In Review",
            category: .done, colorToken: "success")
        let closing = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: toDone, reassignments: [:],
                items: store.allItems(in: project.id)
            ).value)
        try store.applyScheme(closing, to: project.id, actor: .user)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.closedAt != nil)

        // Second plan, in the SAME session, must diff against what the store
        // now holds (in_review == .done) — not the pre-session original
        // (in_review == .active). Planning against the stale original would
        // see no category change at all, and `reopening` would stay empty
        // even though this apply reverts the category and must reopen items.
        let currentScheme = try #require(store.openProject(project.id)?.project.statusScheme)
        let revert = try #require(
            SchemePlan.plan(
                current: currentScheme, proposed: .softwareDefault, reassignments: [:],
                items: store.allItems(in: project.id)
            ).value)
        #expect(!revert.reopening.isEmpty)

        try store.applyScheme(revert, to: project.id, actor: .user)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.closedAt == nil)
    }

    @Test("reassigning into a done status stamps closedAt")
    func reassignmentIntoDoneStamps() throws {
        let (store, project) = makeStore()
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)

        var proposed = StatusScheme.softwareDefault
        proposed.statuses.removeAll { $0.id == "in_review" }
        let plan = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: proposed,
                reassignments: ["in_review": "done"],
                items: store.allItems(in: project.id)
            ).value)

        try store.applyScheme(plan, to: project.id, actor: .user)

        let moved = try #require(store.items(in: project.id).first { $0.id == epic.id })
        #expect(moved.statusID == "done")
        #expect(moved.closedAt != nil)
    }

    @Test("reassigning out of a done status clears closedAt")
    func reassignmentOutOfDoneClears() throws {
        let (store, project) = makeStore()
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)
        try store.setStatus(epic.id, statusID: "done", actor: .user)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.closedAt != nil)

        // Remove `done` while adding another done status, so the scheme still
        // has one, and send the items to a non-done status.
        var proposed = StatusScheme.softwareDefault
        proposed.statuses.removeAll { $0.id == "done" }
        proposed.statuses.append(
            Status(
                id: "shipped", name: "Shipped",
                category: .done, colorToken: "success"))
        let plan = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: proposed,
                reassignments: ["done": "todo"],
                items: store.allItems(in: project.id)
            ).value)

        try store.applyScheme(plan, to: project.id, actor: .user)

        let moved = try #require(store.items(in: project.id).first { $0.id == epic.id })
        #expect(moved.statusID == "todo")
        #expect(moved.closedAt == nil)
    }

    @Test("an item created into a removed status AFTER planning makes the apply throw, writing nothing")
    func staleplanIsRefused() throws {
        let (store, project) = makeStore()
        // Plan removing in_review while it is EMPTY, so the plan carries no
        // reassignment for it at all.
        let plan = try #require(planRemovingReviewEmpty(store))

        // Between planning and applying — the UI's confirm gap, or an MCP call
        // on the same @MainActor store — an item lands in the doomed status.
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)
        let before = try #require(store.openProject(project.id))

        #expect(throws: QuestError.schemeWouldOrphanItems("in_review")) {
            try store.applyScheme(plan, to: project.id, actor: .user)
        }

        let after = try #require(store.openProject(project.id))
        #expect(after.project.statusScheme == .softwareDefault)
        #expect(after.items.first { $0.id == epic.id }?.statusID == "in_review")
        #expect(after.activity.count == before.activity.count)
    }

    /// A plan that removes `in_review` with NO reassignment entry — valid only
    /// because the status held no items at plan time.
    private func planRemovingReviewEmpty(_ store: ProjectStore) -> SchemePlan.Plan? {
        var proposed = StatusScheme.softwareDefault
        proposed.statuses.removeAll { $0.id == "in_review" }
        return SchemePlan.plan(
            current: .softwareDefault, proposed: proposed,
            reassignments: [:], items: []
        ).value
    }

    @Test("a plan that changes nothing is not committed and logs no event")
    func noOpPlanDoesNotWrite() throws {
        let (store, project) = makeStore()
        let before = try #require(store.openProject(project.id))
        let plan = try #require(
            SchemePlan.plan(
                current: .softwareDefault,
                proposed: .softwareDefault,
                reassignments: [:], items: []
            ).value)
        #expect(plan.changesNothing)

        try store.applyScheme(plan, to: project.id, actor: .user)

        let after = try #require(store.openProject(project.id))
        #expect(after.activity.count == before.activity.count)
        #expect(after.project.updatedAt == before.project.updatedAt)
    }

    @Test("a trashed project is refused")
    func refusesTrashed() throws {
        let (store, project) = makeStore()
        let plan = try #require(planRemovingReview(store, project))
        try store.deleteProject(project.id, actor: .user)

        #expect(throws: QuestError.projectNotFound(project.id)) {
            try store.applyScheme(plan, to: project.id, actor: .user)
        }
    }

    @Test("every item still points at a status that exists")
    func invariantHolds() throws {
        let (store, project) = makeStore()
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)
        _ = try store.createItem(
            projectID: project.id, parentID: epic.id, type: .task,
            title: "T", statusID: "backlog", actor: .user)
        let plan = try #require(planRemovingReview(store, project))

        try store.applyScheme(plan, to: project.id, actor: .user)

        let scheme = try #require(store.openProject(project.id)?.project.statusScheme)
        for item in store.allItems(in: project.id) {
            #expect(scheme.status(id: item.statusID) != nil)
        }
    }

    @Test("a plan built against a since-changed scheme is refused, and writes nothing")
    func refusesStalePlan() throws {
        let (store, project) = makeStore()
        let epic = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "todo", actor: .user)

        // Plan A: remove in_review.
        var proposedA = StatusScheme.softwareDefault
        proposedA.statuses.removeAll { $0.id == "in_review" }
        let planA = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: proposedA,
                reassignments: [:],
                items: store.allItems(in: project.id)
            ).value)

        // Someone else changes the scheme first — here, renaming Backlog.
        var proposedB = StatusScheme.softwareDefault
        proposedB.statuses[0] = Status(
            id: "backlog", name: "Icebox",
            category: .todo, colorToken: "muted")
        let planB = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: proposedB,
                reassignments: [:],
                items: store.allItems(in: project.id)
            ).value)
        try store.applyScheme(planB, to: project.id, actor: .agent)
        let activityAfterB = store.activity(for: project.id).count

        // Plan A is now stale: it was diffed against the pre-rename scheme.
        #expect(throws: QuestError.schemeChangedUnderneath) {
            try store.applyScheme(planA, to: project.id, actor: .user)
        }

        // Nothing from plan A landed, and the rename survives.
        let scheme = try #require(store.openProject(project.id)?.project.statusScheme)
        #expect(scheme.status(id: "backlog")?.name == "Icebox")
        #expect(scheme.status(id: "in_review") != nil)
        #expect(store.activity(for: project.id).count == activityAfterB)
        #expect(store.items(in: project.id).first { $0.id == epic.id }?.statusID == "todo")
    }

    @Test("a plan against the unchanged scheme still applies")
    func freshPlanStillApplies() throws {
        let (store, project) = makeStore()
        var proposed = StatusScheme.softwareDefault
        proposed.statuses.removeAll { $0.id == "in_review" }
        let plan = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: proposed,
                reassignments: [:],
                items: store.allItems(in: project.id)
            ).value)

        try store.applyScheme(plan, to: project.id, actor: .user)

        #expect(store.openProject(project.id)?.project.statusScheme.status(id: "in_review") == nil)
    }

    @Test("re-planning against the new scheme succeeds after a refusal")
    func replanRecovers() throws {
        let (store, project) = makeStore()
        var proposedB = StatusScheme.softwareDefault
        proposedB.statuses[0] = Status(
            id: "backlog", name: "Icebox",
            category: .todo, colorToken: "muted")
        let planB = try #require(
            SchemePlan.plan(
                current: .softwareDefault, proposed: proposedB,
                reassignments: [:], items: []
            ).value)
        try store.applyScheme(planB, to: project.id, actor: .agent)

        // Re-plan against what the store now holds.
        let live = try #require(store.openProject(project.id)?.project.statusScheme)
        var proposedC = live
        proposedC.statuses.removeAll { $0.id == "in_review" }
        let planC = try #require(
            SchemePlan.plan(
                current: live, proposed: proposedC,
                reassignments: [:], items: []
            ).value)

        try store.applyScheme(planC, to: project.id, actor: .user)

        let scheme = try #require(store.openProject(project.id)?.project.statusScheme)
        #expect(scheme.status(id: "in_review") == nil)
        #expect(scheme.status(id: "backlog")?.name == "Icebox")
    }

    @Test("mutations unrelated to the scheme do not trip the staleness guard")
    func guardIgnoresUnrelatedChanges() throws {
        let (store, project) = makeStore()
        let plan = try #require(planRemovingReview(store, project))

        // Between planning and applying, mutate the project and its items in
        // ways that do NOT touch the status scheme.
        _ = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "New epic", statusID: "todo", actor: .user)
        var renamed = try #require(store.openProject(project.id)).project
        renamed.name = "Renamed Project"
        try store.updateProject(renamed, actor: .user)

        try store.applyScheme(plan, to: project.id, actor: .user)

        let scheme = try #require(store.openProject(project.id)?.project.statusScheme)
        #expect(scheme.status(id: "in_review") == nil)
        #expect(store.openProject(project.id)?.project.name == "Renamed Project")
    }
}
