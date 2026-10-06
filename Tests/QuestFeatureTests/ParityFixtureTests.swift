import AinkradAppKit
import Foundation
import Testing

@testable import QuestFeature

/// Builds the "Parity Fixture" project through the real `DocumentProjectRepository`
/// so a Debug host can be seeded with it for before/after screenshot capture.
///
/// Normal runs only prove the fixture builds, saves and reloads in memory. Files
/// are written ONLY when `QUEST_PARITY_FIXTURE_OUT=<dir>` is set. Dates hang off
/// one reference day: today, or `QUEST_PARITY_FIXTURE_DATE=yyyy-MM-dd` (the
/// "due today" / "overdue" rows are relative to the day the host is run).
@Suite("ParityFixture")
struct ParityFixtureTests {
    static let projectID = UUID(uuidString: "5C0FFEE0-0000-4000-8000-000000000001")!

    static func referenceDay(_ env: [String: String]) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if let text = env["QUEST_PARITY_FIXTURE_DATE"] {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3,
                let day = calendar.date(
                    from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            {
                return day
            }
        }
        return calendar.startOfDay(for: Date())
    }

    static func makeDocuments(day: Date) throws -> MemoryDocumentStore {
        let calendar = Calendar.current
        func at(_ offsetDays: Int, hour: Int = 12) -> Date {
            let shifted = calendar.date(byAdding: .day, value: offsetDays, to: day)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shifted)!
        }
        func id(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "5C0FFEE0-0000-4000-8000-%012d", 100 + n))!
        }
        func item(
            _ n: Int, parent: Int? = nil, _ type: WorkItemType, _ title: String,
            _ status: String, priority: Priority = .none, labels: [String] = [],
            start: Date? = nil, due: Date? = nil, body: String = ""
        ) -> WorkItem {
            WorkItem(
                id: id(n), projectID: projectID, parentID: parent.map(id), type: type,
                title: title, statusID: status, body: body, priority: priority,
                labels: labels, startDate: start, dueDate: due, orderIndex: n,
                createdAt: at(-14), updatedAt: at(-n),
                closedAt: status == "done" ? at(-1) : nil)
        }

        let project = Project(
            id: projectID, name: "Parity Fixture", kind: .software,
            summaryText: "Seed data for screenshot parity.",
            createdAt: at(-14), updatedAt: at(-1))
        let items = [
            item(1, .epic, "Launch readiness", "in_progress", priority: .high),
            item(2, parent: 1, .task, "Write release notes", "backlog", labels: ["docs"]),
            item(
                3, parent: 1, .task, "Wire the settings page", "todo", priority: .medium,
                labels: ["ui"], start: at(-1), due: at(3)),
            item(
                4, parent: 1, .bug, "Crash on empty project", "in_progress", priority: .urgent,
                labels: ["bug", "ui"], start: at(-2), due: at(0),
                body: "Opening a project with no items crashes the Board."),
            item(
                5, parent: 1, .story, "Import from GitHub", "in_review", priority: .high,
                labels: ["integration"], start: at(-5), due: at(5)),
            item(6, parent: 1, .chore, "Update dependencies", "done", labels: ["chore"]),
            item(
                7, .task, "Fix flaky timeline test", "todo", priority: .low,
                labels: ["bug"], due: at(-3)),
            item(
                8, .spike, "Evaluate offline sync", "backlog", priority: .medium,
                start: at(2), due: at(9)),
        ]
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        try repository.saveProject(ProjectDocument(project: project, items: items))
        try repository.saveIndex([project.summary])
        return documents
    }

    /// The host's `ScopedPluginDocumentStore` file name for a key.
    static func fileName(forKey key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_") + ".bin"
    }

    @Test("the fixture covers every status, a label set, today and overdue, and reloads")
    func fixtureShape() throws {
        let day = Self.referenceDay(ProcessInfo.processInfo.environment)
        let documents = try Self.makeDocuments(day: day)
        let repository = DocumentProjectRepository(documents: documents)

        let summaries = repository.loadIndex()
        #expect(summaries.map(\.name) == ["Parity Fixture"])
        let document = try #require(repository.loadProject(Self.projectID))
        #expect(document.items.count == 8)
        #expect(
            Set(document.items.map(\.statusID))
                == Set(document.project.statusScheme.statuses.map(\.id)))
        #expect(Set(document.items.flatMap(\.labels)).count >= 2)

        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        let today = TodayInbox.build(
            items: document.items, scheme: document.project.statusScheme, now: noon)
        #expect(today.dueToday.count == 1)
        #expect(today.overdue.count == 1)
        #expect(today.active.contains { $0.statusID == "in_progress" })
    }

    @Test("writes <key>.bin files only when QUEST_PARITY_FIXTURE_OUT is set")
    func writeFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["QUEST_PARITY_FIXTURE_OUT"], !out.isEmpty else { return }
        let documents = try Self.makeDocuments(day: Self.referenceDay(env))
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for key in documents.keys.sorted() {
            let data = try #require(documents.data(forKey: key))
            try data.write(to: directory.appendingPathComponent(Self.fileName(forKey: key)))
        }
    }
}
