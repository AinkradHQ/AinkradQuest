import Foundation
import Testing

@testable import QuestFeature

/// BLOCKER 1: the debounce decision as pure logic — no timers, no sleeping
/// for five minutes. `SnapshotCadence` is handed a revision/time snapshot and
/// asked what to do; the timer plumbing in `SnapshotStore` is a thin,
/// separately-tested wrapper around this.
@Suite("Snapshot cadence")
struct SnapshotCadenceTests {
    private let start = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("nothing changed since the last snapshot: never fires, no matter how much time passed")
    func noChangeNeverFires() {
        #expect(
            SnapshotCadence.shouldSnapshot(
                currentRevision: 3, lastSnapshotRevision: 3,
                lastChangeAt: start,
                now: start.addingTimeInterval(60 * 60)) == false)
    }

    @Test("a change inside the quiet period does not yet fire")
    func withinQuietPeriodDoesNotFire() {
        #expect(
            SnapshotCadence.shouldSnapshot(
                currentRevision: 4, lastSnapshotRevision: 3,
                lastChangeAt: start,
                now: start.addingTimeInterval(60)) == false)
    }

    @Test("a change that has sat quiet for the full period fires")
    func afterQuietPeriodFires() {
        #expect(
            SnapshotCadence.shouldSnapshot(
                currentRevision: 4, lastSnapshotRevision: 3,
                lastChangeAt: start,
                now: start.addingTimeInterval(SnapshotCadence.quietPeriod)))
    }

    @Test("a burst of edits keeps pushing the debounce out — one snapshot, not one per keystroke")
    func burstProducesOneSnapshotNotMany() {
        // Each edit resets `lastChangeAt` to `now` in the caller (SnapshotStore.tick),
        // so as long as edits keep landing inside the quiet window, this stays false.
        var lastChangeAt = start
        for offset in stride(from: 0.0, to: SnapshotCadence.quietPeriod, by: 30) {
            let now = start.addingTimeInterval(offset)
            #expect(
                SnapshotCadence.shouldSnapshot(
                    currentRevision: 10, lastSnapshotRevision: 3,
                    lastChangeAt: lastChangeAt, now: now) == false)
            lastChangeAt = now  // simulates another edit landing, resetting the clock
        }
    }

    @Test("teardown fires whenever anything changed, regardless of elapsed time")
    func teardownFiresImmediatelyIfChanged() {
        #expect(SnapshotCadence.shouldSnapshotOnTeardown(currentRevision: 4, lastSnapshotRevision: 3))
        #expect(SnapshotCadence.shouldSnapshotOnTeardown(currentRevision: 4, lastSnapshotRevision: nil))
    }

    @Test("teardown does not fire when nothing changed since the last snapshot")
    func teardownSkipsWhenNothingChanged() {
        #expect(SnapshotCadence.shouldSnapshotOnTeardown(currentRevision: 3, lastSnapshotRevision: 3) == false)
    }
}
