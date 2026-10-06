import Foundation

/// Which projects the sidebar lists. `all` exists so no state can strand a
/// project out of reach — the bug this filter was added to fix.
public enum ProjectStateFilter: String, CaseIterable, Identifiable, Sendable {
    case active, paused, archived, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .archived: "Archived"
        case .all: "All"
        }
    }

    public func apply(to summaries: [ProjectSummary]) -> [ProjectSummary] {
        switch self {
        case .all: summaries
        case .active: summaries.filter { $0.state == .active }
        case .paused: summaries.filter { $0.state == .paused }
        case .archived: summaries.filter { $0.state == .archived }
        }
    }
}
