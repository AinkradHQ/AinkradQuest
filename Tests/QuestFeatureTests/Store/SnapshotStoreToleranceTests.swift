import Foundation
import Testing

@testable import QuestFeature

@Suite("SnapshotStore tolerance")
struct SnapshotStoreToleranceTests {
    @Test @MainActor func pollToleranceIsHalfTheInterval() {
        #expect(SnapshotStore.pollTolerance == SnapshotStore.pollInterval * 0.5)
    }

    @Test @MainActor func pollToleranceIsGenerousEnoughToCoalesce() {
        // A tolerance below ~1s buys nothing: the coalescing window the kernel
        // uses is measured in seconds, not milliseconds.
        #expect(SnapshotStore.pollTolerance >= 1.0)
    }

    @Test @MainActor func aRevisionChangeSchedulesTheQuietPeriodWithoutAPoll() {
        // Calls `overlayDidChange` directly — this exercises the cadence
        // bookkeeping (the same logic the real `onChange` handler runs) but
        // NOT `withObservationTracking` itself, since it never touches
        // `overlay.revision`.
        let store = SnapshotStore.makeForTesting()
        store.startAutoBackup()
        store.overlayDidChange(revision: 7, at: Date(timeIntervalSince1970: 100))
        #expect(store.observedRevision == 7)
    }

    @Test @MainActor func aSecondRealOverlayMutationIsStillObserved() async {
        // Drives TWO real mutations through `OverlayStore.update`, which is
        // the only path that actually bumps `overlay.revision` and therefore
        // the only path that can fire `withObservationTracking`'s `onChange`.
        // `onChange` fires exactly once per registration, so this only
        // passes if `observeOverlay()` re-arms itself after the first
        // change — delete that re-arm and the second assertion fails.
        let store = SnapshotStore.makeForTesting()
        store.startAutoBackup()
        let projectID = UUID()

        store.overlay.update(projectID: projectID) { $0.notes = "first edit" }
        // `onChange`'s body runs inside `Task { @MainActor in ... }`, so it
        // lands on a later main-actor turn, not synchronously here.
        await Task.yield()
        let afterFirst = store.observedRevision
        #expect(afterFirst != nil)

        store.overlay.update(projectID: projectID) { $0.notes = "second edit" }
        await Task.yield()
        let afterSecond = store.observedRevision
        #expect(afterSecond != afterFirst)
    }
}
