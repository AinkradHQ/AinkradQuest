enum QuestSurface: String, CaseIterable, Identifiable, Sendable {
    case today, overview, list, board, timeline

    var id: String { rawValue }
    static let landing = QuestSurface.today

    var title: String {
        switch self {
        case .today: "Today"
        case .overview: "Overview"
        case .list: "List"
        case .board: "Board"
        case .timeline: "Timeline"
        }
    }

    var icon: String {
        switch self {
        case .today: "tray.full"
        case .overview: "square.text.square"
        case .list: "list.bullet.indent"
        case .board: "rectangle.split.3x1"
        case .timeline: "calendar.day.timeline.left"
        }
    }

    /// Today is cross-project; everything else reads one project's document.
    var requiresProject: Bool { self != .today }
}

/// Which surfaces the shell offers, and where. Pure so the shell cannot
/// strand itself on a project-only surface with no project selected — the
/// state the old sidebar allowed by hiding the picker but keeping `surface`.
enum SurfaceVisibility {
    /// Surfaces for the header switcher. `Today` is deliberately absent: it is
    /// cross-project and lives in the sidebar, not the per-project switcher.
    static func offered(hasProject: Bool) -> [QuestSurface] {
        hasProject ? QuestSurface.allCases.filter(\.requiresProject) : [.today]
    }

    static func showsSwitcher(hasProject: Bool) -> Bool { hasProject }

    /// The header's gear opens the SELECTED project's settings, so with nothing
    /// selected it has nothing to open — it used to render anyway and assign
    /// `nil`, which was a click that did nothing at all on the first screen a
    /// new user sees. Gated exactly like the switcher: no affordance is offered
    /// that cannot act.
    static func showsProjectSettings(hasProject: Bool) -> Bool { hasProject }

    /// Collapses an unreachable (surface, selection) pair to a reachable one.
    static func resolved(surface: QuestSurface, hasProject: Bool) -> QuestSurface {
        guard surface.requiresProject, !hasProject else { return surface }
        return .today
    }
}
