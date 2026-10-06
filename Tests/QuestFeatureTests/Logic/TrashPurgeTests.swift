import Foundation
import Testing

@testable import QuestFeature

@Suite("TrashPurge")
struct TrashPurgeTests {
    private let live = UUID()
    private let trashed = UUID()

    /// The ordering rule the whole type exists for: a purged project takes its
    /// document — and so its trashed items — with it, so those items must not
    /// also be listed for individual purge.
    @Test("items inside a project that is itself being purged are not listed")
    func itemsInPurgedProjectsAreExcluded() {
        let itemInLive = UUID()
        let plan = TrashPurge.plan(liveProjectIDs: [live], trashedProjectIDs: [trashed]) { id in
            id == live ? [itemInLive] : [UUID()]
        }
        #expect(plan.itemIDs == [itemInLive])
        #expect(plan.projectIDs == [trashed])
    }

    @Test("an empty trash produces an empty plan")
    func emptyPlan() {
        let plan = TrashPurge.plan(liveProjectIDs: [live], trashedProjectIDs: []) { _ in [] }
        #expect(plan.isEmpty)
    }

    @Test("the confirm message counts both kinds, and singulars read as singular")
    func confirmWording() {
        let both = TrashPurge.confirmMessage(TrashPurgePlan(itemIDs: [UUID()], projectIDs: [UUID()]))
        #expect(both.contains("1 item and 1 project"))
        #expect(both.contains("including everything inside those projects"))

        let many = TrashPurge.confirmMessage(TrashPurgePlan(itemIDs: [UUID(), UUID()], projectIDs: []))
        #expect(many.contains("2 items"))
        // No projects in this plan, so the clause about their contents would be
        // describing something that is not being deleted.
        #expect(!many.contains("including everything inside"))
    }

    @Test("a plan with nothing in it says so rather than threatening")
    func emptyWording() {
        #expect(
            TrashPurge.confirmMessage(TrashPurgePlan(itemIDs: [], projectIDs: []))
                == "The trash is already empty.")
    }

    @Test("a partial run leads with what was destroyed, then what survived")
    func partialOutcome() {
        let outcome = TrashPurgeOutcome(purgedItems: 2, purgedProjects: 0, failures: ["disk full"])
        #expect(outcome.message.hasPrefix("Deleted 2 items."))
        #expect(outcome.message.contains("1 could not be deleted: disk full"))
    }

    @Test("a clean run reports only the successes")
    func cleanOutcome() {
        let outcome = TrashPurgeOutcome(purgedItems: 1, purgedProjects: 2, failures: [])
        #expect(outcome.message == "Deleted 1 item and 2 projects.")
    }

    @Test("a run that destroyed nothing does not claim it deleted things")
    func nothingOutcome() {
        let outcome = TrashPurgeOutcome(purgedItems: 0, purgedProjects: 0, failures: ["gone"])
        #expect(outcome.message.hasPrefix("Nothing was deleted."))
    }
}
