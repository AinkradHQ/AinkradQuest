import Testing

@testable import QuestFeature

@Suite("StatusScheme")
struct StatusSchemeTests {
    @Test("software default is the five-status ladder in order")
    func softwareDefault() {
        #expect(
            StatusScheme.softwareDefault.statuses.map(\.id)
                == ["backlog", "todo", "in_progress", "in_review", "done"])
    }

    @Test("general default drops in review")
    func generalDefault() {
        #expect(
            StatusScheme.generalDefault.statuses.map(\.id)
                == ["backlog", "todo", "in_progress", "done"])
    }

    @Test("categories drive completion, not status names")
    func completion() {
        #expect(StatusScheme.softwareDefault.isDone("done"))
        #expect(!StatusScheme.softwareDefault.isDone("in_review"))
        #expect(!StatusScheme.softwareDefault.isDone("nonexistent"))
    }

    @Test("lookup by id returns the status")
    func lookup() {
        #expect(StatusScheme.softwareDefault.status(id: "in_progress")?.category == .active)
    }
}
