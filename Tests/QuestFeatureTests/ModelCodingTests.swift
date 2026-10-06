import Foundation
import Testing

@testable import QuestFeature

@Suite("Model coding")
struct ModelCodingTests {
    @Test("a project document survives a JSON round trip")
    func roundTrip() throws {
        let projectID = UUID()
        let epicID = UUID()
        let document = ProjectDocument(
            project: Project(id: projectID, name: "Optimus", kind: .software),
            items: [
                WorkItem(
                    id: epicID, projectID: projectID, parentID: nil,
                    type: .epic, title: "Backend v2", statusID: "todo"),
                WorkItem(
                    id: UUID(), projectID: projectID, parentID: epicID,
                    type: .bug, title: "Fix auth refresh", statusID: "in_progress",
                    links: [
                        Link(
                            scheme: .repo, identifier: "~/Projects/optimus-api",
                            label: "optimus-api")
                    ]),
            ],
            activity: [
                ActivityEvent(
                    projectID: projectID, actor: .agent,
                    kind: .itemCreated, summary: "created Fix auth refresh")
            ])

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ProjectDocument.self, from: data)

        #expect(decoded.project.name == "Optimus")
        #expect(decoded.items.count == 2)
        #expect(decoded.items[1].links.first?.scheme == .repo)
        #expect(decoded.activity.first?.actor == .agent)
    }

    @Test("a new project defaults to the scheme its kind implies")
    func defaultScheme() {
        #expect(Project(id: UUID(), name: "A", kind: .software).statusScheme == .softwareDefault)
        #expect(Project(id: UUID(), name: "B", kind: .general).statusScheme == .generalDefault)
    }

    /// `Link.id` is derived from the stored fields, never written. That is what
    /// makes changing its formula (to include the repo) a no-migration change:
    /// no persisted document contains an `id` to become stale.
    @Test("a link's id is computed, so it is never persisted")
    func linkIDIsNotPersisted() throws {
        let link = Link(scheme: .branch, identifier: "main", label: "main", repo: "alpha")
        let json =
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(link)) as? [String: Any]

        #expect(json?["id"] == nil)
        #expect(Set(json?.keys ?? [:].keys) == ["scheme", "identifier", "label", "repo"])
    }

    @Test("a summary carries only what the index needs")
    func summary() {
        let project = Project(id: UUID(), name: "Ainkrad", kind: .software)
        #expect(project.summary.name == "Ainkrad")
        #expect(project.summary.id == project.id)
    }
}
