import Testing

@testable import QuestFeature

@Suite("QuestSurface")
struct SurfaceSelectionTests {
    @Test("today is the landing surface and needs no project")
    func today() {
        #expect(QuestSurface.landing == .today)
        #expect(!QuestSurface.today.requiresProject)
    }

    @Test("the project surfaces require a selected project")
    func projectSurfaces() {
        #expect(QuestSurface.board.requiresProject)
        #expect(QuestSurface.timeline.requiresProject)
        #expect(QuestSurface.overview.requiresProject)
        #expect(QuestSurface.list.requiresProject)
    }

    @Test("every surface has a title and an SF Symbol")
    func metadata() {
        for surface in QuestSurface.allCases {
            #expect(!surface.title.isEmpty)
            #expect(!surface.icon.isEmpty)
        }
    }
}
