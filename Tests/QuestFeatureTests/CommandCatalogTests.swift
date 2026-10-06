import Foundation
import Testing

@testable import QuestFeature

@Suite("CommandCatalog")
struct CommandCatalogTests {
    private func summary(_ name: String) -> ProjectSummary {
        ProjectSummary(
            id: UUID(), name: name, icon: "folder", colorToken: "blue",
            kind: .software, state: .active, updatedAt: Date())
    }

    @Test("with no project selected, no surface, status or settings command is offered")
    func noProject() {
        let entries = CommandCatalog.entries(
            projects: [], hasProject: false,
            statuses: StatusScheme.softwareDefault.statuses)
        #expect(!entries.contains { if case .openSurface = $0.action { return true } else { return false } })
        #expect(!entries.contains { if case .setStatus = $0.action { return true } else { return false } })
        // Deliberately changed: `openSettings` used to be listed here
        // unconditionally, and choosing it with nothing selected did nothing at
        // all. It is project-scoped, like `newItem`.
        #expect(!entries.contains { $0.action == .openSettings })
    }

    @Test("truly global commands are always offered")
    func globals() {
        let ids = Set(CommandCatalog.entries(projects: [], hasProject: false, statuses: []).map(\.id))
        #expect(ids.isSuperset(of: ["newProject", "openTrash"]))
    }

    @Test("project settings is offered once a project is selected")
    func settingsGated() {
        let entries = CommandCatalog.entries(projects: [], hasProject: true, statuses: [])
        #expect(entries.filter { $0.action == .openSettings }.count == 1)
    }

    @Test("with a project, each project surface and each status is offered")
    func withProject() {
        let entries = CommandCatalog.entries(
            projects: [], hasProject: true,
            statuses: StatusScheme.softwareDefault.statuses)
        let surfaces = entries.compactMap { entry -> QuestSurface? in
            if case .openSurface(let s) = entry.action { return s } else { return nil }
        }
        #expect(surfaces == [.overview, .list, .board, .timeline])
        let statuses = entries.compactMap { entry -> String? in
            if case .setStatus(let id) = entry.action { return id } else { return nil }
        }
        #expect(statuses == ["backlog", "todo", "in_progress", "in_review", "done"])
    }

    @Test("every project becomes a jump-to entry")
    func projectJumps() {
        let a = summary("Ainkrad")
        let entries = CommandCatalog.entries(projects: [a], hasProject: false, statuses: [])
        #expect(entries.contains { $0.action == .selectProject(a.id) && $0.title == "Ainkrad" })
    }

    @Test("filtering is case-insensitive over title and detail")
    func filtering() {
        let a = summary("Ainkrad")
        let entries = CommandCatalog.entries(projects: [a], hasProject: false, statuses: [])
        #expect(CommandCatalog.filtered(entries, query: "ainkr").contains { $0.title == "Ainkrad" })
        #expect(CommandCatalog.filtered(entries, query: "AINKR").contains { $0.title == "Ainkrad" })
        #expect(CommandCatalog.filtered(entries, query: "zzzz").isEmpty)
    }

    @Test("an empty or whitespace query returns everything, unreordered")
    func emptyQuery() {
        let entries = CommandCatalog.entries(
            projects: [summary("A")], hasProject: true,
            statuses: StatusScheme.softwareDefault.statuses)
        #expect(CommandCatalog.filtered(entries, query: "") == entries)
        #expect(CommandCatalog.filtered(entries, query: "   ") == entries)
    }

    @Test("ids are unique, since AinkradCommandMenu keys rows on them")
    func uniqueIDs() {
        let entries = CommandCatalog.entries(
            projects: [summary("A"), summary("B")],
            hasProject: true,
            statuses: StatusScheme.softwareDefault.statuses)
        #expect(Set(entries.map(\.id)).count == entries.count)
    }
}
