import Foundation
import Testing

@testable import QuestFeature

@Suite("Connection model")
struct ConnectionModelTests {
    @Test("a connection round-trips through JSON")
    func roundTrip() throws {
        // createdAt is pinned to a whole-second value: ISO 8601 encoding
        // truncates sub-second precision, so the default `Date()` would make
        // this round-trip fail almost every time it runs.
        let connection = Connection(
            id: UUID(), provider: .jira,
            accountLabel: "Work Jira",
            accountIdentifier: "ahmed@work.com",
            baseURL: URL(string: "https://work.atlassian.net"),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Connection.self, from: encoder.encode(connection))
        #expect(decoded == connection)
    }

    @Test("an unknown provider decodes to local rather than failing")
    func unknownProvider() throws {
        let json = """
            {"id":"\(UUID().uuidString)","provider":"asana","accountLabel":"X",
             "accountIdentifier":"x","credentialRef":"r","createdAt":"2026-08-24T00:00:00Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Connection.self, from: Data(json.utf8))
        #expect(decoded.provider == .local)
    }

    @Test("the credential ref is derived from the connection id")
    func credentialRef() {
        let id = UUID()
        #expect(Connection.credentialRef(for: id) == "quest.connection.\(id.uuidString)")
    }

    @Test("a connection written before token provenance existed decodes as manual")
    func missingProvenanceDecodesLeniently() throws {
        let json = """
            {"id":"\(UUID().uuidString)","provider":"githubProjects","accountLabel":"X",
             "accountIdentifier":"x","credentialRef":"r","createdAt":"2026-08-24T00:00:00Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Connection.self, from: Data(json.utf8))
        #expect(decoded.tokenProvenance == .manual)
    }

    @Test("token provenance round-trips through JSON when present")
    func provenanceRoundTrips() throws {
        let connection = Connection(
            id: UUID(), provider: .githubProjects,
            accountLabel: "Work GitHub",
            accountIdentifier: "ahmed",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            tokenProvenance: .githubCLI)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Connection.self, from: encoder.encode(connection))
        #expect(decoded.tokenProvenance == .githubCLI)
    }
}
