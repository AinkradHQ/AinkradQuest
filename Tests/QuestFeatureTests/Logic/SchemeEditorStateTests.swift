import Foundation
import Testing

@testable import QuestFeature

/// Covers `SchemeEditorState.plan`/`afterApply`, the pure helper
/// `StatusSchemeEditor` calls into. These tests exercise the exact code path
/// the round-1 fix (read the scheme fresh from the store, not a stale capture)
/// lives in — unlike `ProjectStoreSchemeTests`, which calls `SchemePlan.plan`
/// directly and would pass identically even if the view still captured a
/// stale scheme.
@MainActor
@Suite("SchemeEditorState")
struct SchemeEditorStateTests {
    private func makeStore() -> (ProjectStore, Project) {
        let store = makeProjectStore(InMemoryProjectRepository())
        return (store, store.createProject(name: "Quest", kind: .software, actor: .user))
    }

    /// Moves `in_review` into `.done`, applies it, and returns the project
    /// plus both the pre-session original scheme and the scheme the store
    /// holds right after that first apply.
    private func setUpClosedInReview() throws
        -> (store: ProjectStore, project: Project, original: StatusScheme, afterFirstApply: StatusScheme)
    {
        let (store, project) = makeStore()
        _ = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)

        let original = StatusScheme.softwareDefault
        var toDone = original
        toDone.statuses[3] = Status(
            id: "in_review", name: "In Review",
            category: .done, colorToken: "success")
        let closing = try #require(
            SchemeEditorState.plan(
                current: original, drafts: StatusDraft.drafts(from: toDone),
                reassignments: [:], items: store.allItems(in: project.id)
            ).value)
        try store.applyScheme(closing, to: project.id, actor: .user)

        let afterFirstApply = try #require(store.openProject(project.id)?.project.statusScheme)
        return (store, project, original, afterFirstApply)
    }

    @Test("planning a revert against the CURRENT (post-apply) scheme finds the reopening")
    func revertAgainstCurrentSchemeReopens() throws {
        let (store, project, original, afterFirstApply) = try setUpClosedInReview()

        // `afterFirstApply` is what `currentScheme` in the live view reads —
        // in_review is .done there. Reverting drafts back to the original
        // (non-done) category against THAT scheme must surface a reopening.
        let revert = try #require(
            SchemeEditorState.plan(
                current: afterFirstApply, drafts: StatusDraft.drafts(from: original),
                reassignments: [:], items: store.allItems(in: project.id)
            ).value)
        #expect(!revert.reopening.isEmpty)
    }

    @Test("regression: planning the same revert against the STALE pre-session scheme misses the reopening")
    func revertAgainstStaleSchemeMissesReopening() throws {
        let (store, project, original, _) = try setUpClosedInReview()

        // This reproduces the pre-fix bug: if `current` is the stale
        // pre-session original (also non-done for in_review) instead of what
        // the store now holds, the proposed scheme looks identical to
        // `current` for in_review's category, so no recategorisation — and
        // therefore no reopening — is detected at all.
        let revert = try #require(
            SchemeEditorState.plan(
                current: original, drafts: StatusDraft.drafts(from: original),
                reassignments: [:], items: store.allItems(in: project.id)
            ).value)
        #expect(revert.reopening.isEmpty)
    }

    @Test("re-adding a removed status drops its stale reassignment entry")
    func reAddedStatusLosesItsReassignment() throws {
        let (store, project) = makeStore()
        _ = try store.createItem(
            projectID: project.id, parentID: nil, type: .epic,
            title: "E", statusID: "in_review", actor: .user)

        // The UI sequence: remove "In Review", pick a destination for its
        // items, then add a new row named "In Review". `StatusDraft.make`
        // re-mints the SAME id, so the row is no longer a removal and its
        // picker disappears — but `reassignments` still holds the entry.
        var drafts = StatusDraft.drafts(from: .softwareDefault)
        drafts.removeAll { $0.id == "in_review" }
        let reassignments = ["in_review": "todo"]
        drafts.append(StatusDraft.make(name: "In Review", existing: drafts))
        #expect(drafts.contains { $0.id == "in_review" })

        let plan = try #require(
            SchemeEditorState.plan(
                current: .softwareDefault, drafts: drafts,
                reassignments: reassignments, items: store.allItems(in: project.id)
            ).value)

        #expect(plan.reassignments["in_review"] == nil)
        #expect(plan.itemsReassigned == 0)

        // And applying it must leave the items where they were.
        try store.applyScheme(plan, to: project.id, actor: .user)
        let scheme = try #require(store.openProject(project.id)?.project.statusScheme)
        for item in store.allItems(in: project.id) {
            #expect(item.statusID == "in_review")
            #expect(scheme.status(id: item.statusID) != nil)
        }
    }

    @Test("afterApply re-seeds drafts from the plan's proposed scheme and clears reassignments")
    func afterApplyReseeds() throws {
        let (store, project) = makeStore()
        var proposed = StatusScheme.softwareDefault
        proposed.statuses.removeAll { $0.id == "in_review" }
        let plan = try #require(
            SchemeEditorState.plan(
                current: .softwareDefault, drafts: StatusDraft.drafts(from: proposed),
                reassignments: ["in_review": "todo"], items: store.allItems(in: project.id)
            ).value)

        let next = SchemeEditorState.afterApply(plan)
        #expect(next.drafts == StatusDraft.drafts(from: proposed))
        #expect(next.reassignments.isEmpty)
    }

    @Test("after a stale refusal the editor re-seeds from the live scheme and clears reassignments")
    func recoversFromStaleRefusal() {
        var live = StatusScheme.softwareDefault
        live.statuses[0] = Status(
            id: "backlog", name: "Icebox",
            category: .todo, colorToken: "muted")

        let recovered = SchemeEditorState.afterStaleRefusal(currentScheme: live)

        #expect(recovered.drafts.map(\.id) == live.statuses.map(\.id))
        #expect(recovered.drafts.first?.name == "Icebox")
        #expect(recovered.reassignments.isEmpty)
    }
}
