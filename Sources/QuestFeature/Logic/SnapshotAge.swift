import Foundation

/// Describes how stale the last backup is, in words a person reads at a
/// glance rather than a raw timestamp. A backup that stopped weeks ago is the
/// exact failure this whole surface exists to catch, so a stale age reads as
/// a problem to act on, not a neutral fact.
enum SnapshotAge {
    private static let staleThreshold: TimeInterval = 60 * 60 * 24 * 7

    static func describe(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never backed up" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed >= staleThreshold {
            let days = Int(elapsed / (60 * 60 * 24))
            return "Backed up \(days) day\(days == 1 ? "" : "s") ago — this looks stale, check your vault folder"
        }
        if elapsed < 60 {
            return "Backed up just now"
        }
        if elapsed < 60 * 60 {
            let minutes = Int(elapsed / 60)
            return "Backed up \(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        if elapsed < 60 * 60 * 24 {
            let hours = Int(elapsed / (60 * 60))
            return "Backed up \(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = Int(elapsed / (60 * 60 * 24))
        return "Backed up \(days) day\(days == 1 ? "" : "s") ago"
    }
}
