import Foundation

/// Which projects the sidebar lists. `all` exists so no state can strand a
/// project out of reach — the bug this filter was added to fix.
enum ProjectStateFilter: String, CaseIterable, Identifiable, Sendable {
    case active, paused, archived, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .archived: "Archived"
        case .all: "All"
        }
    }

    func apply(to summaries: [ProjectSummary]) -> [ProjectSummary] {
        switch self {
        case .all: summaries
        case .active: summaries.filter { $0.state == .active }
        case .paused: summaries.filter { $0.state == .paused }
        case .archived: summaries.filter { $0.state == .archived }
        }
    }
}
