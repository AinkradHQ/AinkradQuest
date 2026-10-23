import Foundation

/// Reconnect delays: 1 → 2 → 4 → 8 … capped at 60 s (mockup 01 note 4). `attempt` counts from 1.
enum Backoff {
    static let cap: TimeInterval = 60

    static func delay(attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 1 }
        return min(cap, pow(2, Double(min(attempt - 1, 6))))
    }
}
