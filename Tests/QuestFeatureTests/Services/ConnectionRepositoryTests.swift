import Foundation
import Testing

@testable import QuestFeature

@Suite("Connection persistence")
struct ConnectionRepositoryTests {
    @Test("connections round-trip through the document repository")
    func roundTrip() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        // `createdAt` is pinned to a whole second: `.iso8601` encoding drops
        // sub-second precision, so a default `Date()` would make the equality
        // assertion below flaky. Task 1 hit exactly this.
        let connection = Connection(
            id: UUID(), provider: .linear,
            accountLabel: "Personal Linear",
            accountIdentifier: "ahmed",
            createdAt: Date(timeIntervalSince1970: 1_756_000_000))
        try repository.saveConnections([connection])

        let reloaded = DocumentProjectRepository(documents: documents)
        #expect(reloaded.loadConnections() == [connection])
    }

    @Test("connections live in their own document, not the project index")
    func separateDocument() throws {
        let documents = MemoryDocumentStore()
        let repository = DocumentProjectRepository(documents: documents)
        try repository.saveConnections([
            Connection(
                id: UUID(), provider: .jira,
                accountLabel: "W", accountIdentifier: "w")
        ])
        #expect(documents.keys.contains("connection-index"))
        #expect(documents.data(forKey: "project-index") == nil)
    }

    @Test("a missing connection document loads as empty rather than failing")
    func missing() {
        let repository = DocumentProjectRepository(documents: MemoryDocumentStore())
        #expect(repository.loadConnections().isEmpty)
    }
}
