/// Why a surface is blank. The old views rendered one indistinguishable
/// blank for "this project has no items" and "your filter excluded all of
/// them", which reads as a broken app rather than a state.
enum EmptyReason: Equatable, Sendable {
    case noProjectSelected
    case noItems
    case filteredOut
    case notEmpty

    /// `hasProject` is checked first: with no project the counts describe
    /// nothing the user can act on.
    static func classify(totalCount: Int, visibleCount: Int, hasProject: Bool) -> EmptyReason {
        guard hasProject else { return .noProjectSelected }
        if visibleCount > 0 { return .notEmpty }
        return totalCount == 0 ? .noItems : .filteredOut
    }

    var icon: String {
        switch self {
        case .noProjectSelected: "square.grid.2x2"
        case .noItems: "tray"
        case .filteredOut: "line.3.horizontal.decrease.circle"
        case .notEmpty: ""
        }
    }

    var title: String {
        switch self {
        case .noProjectSelected: "No project selected"
        case .noItems: "Nothing here yet"
        case .filteredOut: "No matches"
        case .notEmpty: ""
        }
    }

    var message: String {
        switch self {
        case .noProjectSelected: "Pick a project in the sidebar, or press ⌘N to start one."
        case .noItems: "This project has no work items yet."
        case .filteredOut: "Every item is hidden by the current filters."
        case .notEmpty: ""
        }
    }

    var actionTitle: String? {
        switch self {
        case .noItems: "Add an item"
        case .filteredOut: "Clear filters"
        case .noProjectSelected, .notEmpty: nil
        }
    }
}
