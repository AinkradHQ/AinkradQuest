import Foundation
import Testing

@testable import QuestFeature

@Suite("ProjectStateFilter")
struct ProjectFilterTests {
    private func summary(_ name: String, _ state: ProjectState) -> ProjectSummary {
        ProjectSummary(
            id: UUID(), name: name, icon: "folder", colorToken: "accentPrimary",
            kind: .software, state: state, updatedAt: Date())
    }

    private var all: [ProjectSummary] {
        [summary("A", .active), summary("P", .paused), summary("Z", .archived)]
    }

    @Test("each filter selects only its own state")
    func selects() {
        #expect(ProjectStateFilter.active.apply(to: all).map(\.name) == ["A"])
        #expect(ProjectStateFilter.paused.apply(to: all).map(\.name) == ["P"])
        #expect(ProjectStateFilter.archived.apply(to: all).map(\.name) == ["Z"])
    }

    @Test("all returns everything, so no project is unreachable")
    func showsAll() {
        #expect(ProjectStateFilter.all.apply(to: all).count == 3)
    }

    @Test("every filter has a title")
    func titles() {
        for filter in ProjectStateFilter.allCases { #expect(!filter.title.isEmpty) }
    }
}
