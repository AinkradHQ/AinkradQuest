import Foundation
import Testing

@testable import QuestFeature

@Suite("Snapshot age")
struct SnapshotAgeTests {
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("never backed up says so plainly")
    func never() {
        #expect(SnapshotAge.describe(nil, now: now) == "Never backed up")
    }

    @Test("a recent backup reads as just now")
    func recent() {
        #expect(SnapshotAge.describe(now.addingTimeInterval(-30), now: now) == "Backed up just now")
    }

    @Test("hours and days are both described")
    func older() {
        #expect(SnapshotAge.describe(now.addingTimeInterval(-7200), now: now).contains("2 hours"))
        #expect(SnapshotAge.describe(now.addingTimeInterval(-259200), now: now).contains("3 days"))
    }

    @Test("a stale backup is called out, not just dated")
    func stale() {
        let text = SnapshotAge.describe(now.addingTimeInterval(-60 * 60 * 24 * 30), now: now)
        // A backup that stopped a month ago is the failure this indicator
        // exists to catch, so it must read as a problem rather than a fact.
        #expect(text.lowercased().contains("stale") || text.lowercased().contains("check"))
    }
}
