import Foundation

/// Pure decision logic for BLOCKER 1's automatic backup cadence: "debounced on
/// overlay change — roughly five minutes of quiet — plus one on app
/// termination if anything changed."
///
/// Deliberately has no dependency on `Timer`, `SnapshotStore`, or wall-clock
/// `Date()` — it is handed everything it needs as arguments, so the debounce
/// decision is testable as ordinary logic rather than by sleeping five
/// minutes in a test.
enum SnapshotCadence {
    /// How long the overlay must sit unchanged before a debounced snapshot
    /// fires. A burst of edits (e.g. a fast typing session) keeps pushing this
    /// out, so it produces one snapshot per pause, not one per keystroke.
    static let quietPeriod: TimeInterval = 5 * 60

    /// Whether a debounced snapshot should fire right now.
    ///
    /// - Parameters:
    ///   - currentRevision: `OverlayStore.revision` right now.
    ///   - lastSnapshotRevision: the overlay revision as of the last snapshot
    ///     written (automatic or manual), or `nil` if none has ever been taken
    ///     this session.
    ///   - lastChangeAt: when `currentRevision` was last observed to change.
    ///   - now: the current time.
    ///
    /// Returns `false` when nothing has changed since the last snapshot —
    /// firing here unconditionally would rotate five identical backups and
    /// destroy the user's real history, which is exactly the failure this
    /// cadence exists to avoid introducing.
    static func shouldSnapshot(
        currentRevision: Int, lastSnapshotRevision: Int?,
        lastChangeAt: Date, now: Date
    ) -> Bool {
        guard currentRevision != lastSnapshotRevision else { return false }
        return now.timeIntervalSince(lastChangeAt) >= quietPeriod
    }

    /// Whether a termination-time snapshot is warranted: anything changed
    /// since the last snapshot, regardless of how recently. Unlike
    /// `shouldSnapshot`, there is no quiet period to wait out — the app is
    /// going away, so this is the last chance.
    static func shouldSnapshotOnTeardown(
        currentRevision: Int,
        lastSnapshotRevision: Int?
    ) -> Bool {
        currentRevision != lastSnapshotRevision
    }
}
