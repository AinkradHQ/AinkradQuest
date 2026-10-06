import Foundation
import Testing

@testable import QuestFeature

@Suite("SchemePlan")
struct SchemePlanTests {
    private let projectID = UUID()

    private func item(_ title: String, _ statusID: String, deleted: Bool = false) -> WorkItem {
        var made = WorkItem(
            id: UUID(), projectID: projectID, parentID: UUID(), type: .task,
            title: title, statusID: statusID)
        if deleted { made.deletedAt = Date() }
        return made
    }

    private func status(
        _ id: String, _ category: StatusCategory,
        name: String? = nil
    ) -> Status {
        Status(
            id: id, name: name ?? id.capitalized, category: category,
            colorToken: "accentPrimary")
    }

    private var current: StatusScheme { .softwareDefault }

    @Test("a rename touches no item and is reported as a rename")
    func rename() throws {
        var proposed = current
        proposed.statuses[3] = status("in_review", .active, name: "QA")

        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: [:],
                items: [item("A", "in_review")]
            ).value)
        #expect(plan.renamed.map(\.id) == ["in_review"])
        #expect(plan.reassignments.isEmpty)
        #expect(plan.closing.isEmpty)
    }

    @Test("removing a status with items requires a destination")
    func removalNeedsDestination() {
        var proposed = current
        proposed.statuses.removeAll { $0.id == "in_review" }

        let outcome = SchemePlan.plan(
            current: current, proposed: proposed,
            reassignments: [:], items: [item("A", "in_review")])
        #expect(outcome.value == nil)
    }

    @Test("removing a status reassigns exactly its live items")
    func removalReassigns() throws {
        var proposed = current
        proposed.statuses.removeAll { $0.id == "in_review" }

        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: ["in_review": "todo"],
                items: [
                    item("A", "in_review"), item("B", "todo"),
                    item("C", "in_review", deleted: true),
                ]
            ).value)

        #expect(plan.removed.map(\.id) == ["in_review"])
        #expect(plan.reassignments["in_review"] == "todo")
        // A soft-deleted item still carries a statusID, so it must be reassigned
        // too — restoring it later must not resurrect a dangling status.
        #expect(plan.itemsReassigned == 2)
    }

    @Test("a removal with no items needs no destination")
    func emptyRemoval() throws {
        var proposed = current
        proposed.statuses.removeAll { $0.id == "in_review" }

        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: [:], items: []
            ).value)
        #expect(plan.removed.map(\.id) == ["in_review"])
    }

    @Test("a destination missing from the proposed scheme is refused")
    func destinationMustSurvive() {
        var proposed = current
        proposed.statuses.removeAll { $0.id == "in_review" || $0.id == "backlog" }

        let outcome = SchemePlan.plan(
            current: current, proposed: proposed,
            reassignments: ["in_review": "backlog"],
            items: [item("A", "in_review")])
        #expect(outcome.value == nil)
    }

    @Test("a reassignment key that is not being removed is refused")
    func reassignmentKeyMustBeRemoved() {
        // The whole scheme is unchanged, so nothing is being removed — yet
        // pre-fix this validated as `.valid` and summarised "no changes" while
        // silently rewriting every `todo` item's statusID to a status that is
        // not in the scheme at all.
        let outcome = SchemePlan.plan(
            current: current, proposed: current,
            reassignments: ["todo": "nonexistent"],
            items: [item("A", "todo")])
        #expect(outcome.value == nil)
        #expect(outcome.message?.contains("todo") == true)
    }

    @Test("a reassignment for a surviving status is refused even when the destination exists")
    func reassignmentForSurvivingStatusRefused() {
        // The benign-looking variant: a legal destination, so no dangling
        // status — but it still bulk-moves every `todo` item while the summary
        // says "no changes". A reassignment is only ever a consequence of a
        // removal; it is not a bulk-move API.
        let outcome = SchemePlan.plan(
            current: current, proposed: current,
            reassignments: ["todo": "done"],
            items: [item("A", "todo")])
        #expect(outcome.value == nil)
        #expect(outcome.message?.contains("todo") == true)
    }

    @Test("an EMPTY removal's destination is validated too, not just an occupied one's")
    func emptyRemovalDestinationValidated() {
        var proposed = current
        proposed.statuses.removeAll { $0.id == "in_review" }

        // No items in in_review, so the occupied-removal loop never looked at
        // this destination pre-fix; the entry then survived into the plan.
        let outcome = SchemePlan.plan(
            current: current, proposed: proposed,
            reassignments: ["in_review": "nonexistent"],
            items: [])
        #expect(outcome.value == nil)
        #expect(outcome.message?.contains("in_review") == true)
    }

    @Test("moving a status into done closes its items; moving out reopens them")
    func categoryChange() throws {
        var toDone = current
        toDone.statuses[3] = status("in_review", .done, name: "In Review")
        let closing = try #require(
            SchemePlan.plan(
                current: current, proposed: toDone,
                reassignments: [:],
                items: [item("A", "in_review")]
            ).value)
        #expect(closing.closing.count == 1)
        #expect(closing.reopening.isEmpty)

        var fromDone = current
        fromDone.statuses[3] = status("in_review", .done, name: "In Review")
        fromDone.statuses[4] = status("done", .active, name: "Done")
        let reopening = try #require(
            SchemePlan.plan(
                current: current, proposed: fromDone,
                reassignments: [:],
                items: [item("A", "done")]
            ).value)
        #expect(reopening.reopening.count == 1)
        #expect(reopening.closing.isEmpty)
    }

    @Test("a category change that would leave no done status is refused")
    func cannotVacateDoneCategory() {
        var proposed = current
        proposed.statuses[4] = status("done", .active, name: "Done")
        let outcome = SchemePlan.plan(
            current: current, proposed: proposed,
            reassignments: [:], items: [item("A", "done")])
        #expect(outcome.value == nil)
    }

    @Test("an empty scheme is refused")
    func emptyScheme() {
        #expect(
            SchemePlan.plan(
                current: current, proposed: StatusScheme(statuses: []),
                reassignments: [:], items: []
            ).value == nil)
    }

    @Test("a scheme with no done status is refused, because completion becomes unreachable")
    func noDoneStatus() {
        let proposed = StatusScheme(statuses: [status("todo", .todo), status("doing", .active)])
        #expect(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: [:], items: []
            ).value == nil)
    }

    @Test("duplicate ids are refused")
    func duplicateIDs() {
        let proposed = StatusScheme(statuses: [status("todo", .todo), status("todo", .done)])
        #expect(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: [:], items: []
            ).value == nil)
    }

    @Test("reordering alone is reported as a reorder and touches no item")
    func reorder() throws {
        var proposed = current
        proposed.statuses.swapAt(0, 1)

        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: [:], items: []
            ).value)
        #expect(plan.reordered)
        #expect(plan.renamed.isEmpty)
        #expect(plan.removed.isEmpty)
    }

    @Test("adding a status is reported and touches no item")
    func addition() throws {
        var proposed = current
        proposed.statuses.insert(status("blocked", .active), at: 3)

        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: [:], items: []
            ).value)
        #expect(plan.added.map(\.id) == ["blocked"])
    }

    @Test("a colour-only change is reported in the summary, not silently dropped")
    func recolouredSummary() throws {
        var proposed = current
        proposed.statuses[3] = status("in_review", .active, name: "In Review")
        proposed.statuses[3].colorToken = "danger"

        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: [:], items: []
            ).value)
        #expect(plan.recoloured.map(\.id) == ["in_review"])
        #expect(plan.summary.contains("In Review"))
        #expect(plan.summary != "no changes")
    }

    @Test("an identical scheme summarises as no changes")
    func identicalSchemeIsNoChanges() throws {
        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: current,
                reassignments: [:], items: []
            ).value)
        #expect(plan.summary == "no changes")
    }

    @Test("the summary names what will happen, for the confirm step and the agent")
    func summary() throws {
        var proposed = current
        proposed.statuses.removeAll { $0.id == "in_review" }
        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: ["in_review": "todo"],
                items: [item("A", "in_review")]
            ).value)

        #expect(plan.summary.contains("In Review"))
        #expect(plan.summary.contains("Todo"))
        #expect(plan.summary.contains("1"))
    }

    @Test("a plan records the scheme it was diffed against")
    func planRecordsCurrent() throws {
        var proposed = current
        proposed.statuses.removeAll { $0.id == "in_review" }
        let plan = try #require(
            SchemePlan.plan(
                current: current, proposed: proposed,
                reassignments: [:], items: []
            ).value)
        #expect(plan.current == current)
    }
}
