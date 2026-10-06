import Testing

@testable import QuestFeature

@Suite("SurfaceVisibility")
struct SurfaceVisibilityTests {
    @Test("with no project only Today is offered and the switcher is hidden")
    func noProject() {
        #expect(SurfaceVisibility.offered(hasProject: false) == [.today])
        #expect(!SurfaceVisibility.showsSwitcher(hasProject: false))
    }

    @Test("with a project the four project surfaces are offered, in order")
    func withProject() {
        #expect(SurfaceVisibility.offered(hasProject: true) == [.overview, .list, .board, .timeline])
        #expect(SurfaceVisibility.showsSwitcher(hasProject: true))
    }

    @Test("the header gear is withheld with no project, offered with one")
    func settingsGating() {
        #expect(!SurfaceVisibility.showsProjectSettings(hasProject: false))
        #expect(SurfaceVisibility.showsProjectSettings(hasProject: true))
    }

    @Test("Today is never offered in the switcher — it lives in the sidebar")
    func todayNotInSwitcher() {
        #expect(!SurfaceVisibility.offered(hasProject: true).contains(.today))
    }

    @Test("losing the project selection falls back to Today")
    func resolveFallsBack() {
        #expect(SurfaceVisibility.resolved(surface: .board, hasProject: false) == .today)
        #expect(SurfaceVisibility.resolved(surface: .today, hasProject: false) == .today)
    }

    @Test("a project surface is preserved while a project is selected")
    func resolvePreserves() {
        #expect(SurfaceVisibility.resolved(surface: .board, hasProject: true) == .board)
    }

    @Test("selecting a project while on Today stays on Today")
    func resolveKeepsToday() {
        #expect(SurfaceVisibility.resolved(surface: .today, hasProject: true) == .today)
    }
}
