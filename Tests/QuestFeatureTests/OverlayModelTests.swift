import Foundation
import Testing

@testable import QuestFeature

@Suite("Overlay models")
struct OverlayModelTests {
    private func makeCoders() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    @Test("a project overlay round-trips with items, repos and time")
    func roundTrip() throws {
        let (encoder, decoder) = makeCoders()
        let projectID = UUID()
        let itemID = UUID()
        var overlay = ProjectOverlay(projectID: projectID)
        overlay.repos = [AttachedRepo(id: UUID(), connectionID: UUID(), owner: "a", name: "b")]
        overlay.vaultFolder = "/vault/Ainkrad"
        overlay.notes = "project scratch"
        var item = ItemOverlay()
        item.notes = "item scratch"
        item.personalOrder = 3
        // Pinned to a whole second: `.iso8601` drops sub-second precision, so a
        // default `Date()` would make this equality assertion flaky.
        item.timeEntries = [
            TimeEntry(
                id: UUID(), minutes: 45,
                spentOn: Date(timeIntervalSince1970: 1_756_000_000),
                note: "pairing")
        ]
        item.sessions = [
            SessionAttachment(
                id: UUID(), sessionID: "abc-123",
                pathSlug: "-Users-me-Projects-X",
                resolvedPath: "/Users/me/Projects/X",
                label: "fix the parser",
                attachedAt: Date(timeIntervalSince1970: 1_756_000_000))
        ]
        overlay.setItem(item, for: itemID)

        let decoded = try decoder.decode(ProjectOverlay.self, from: encoder.encode(overlay))
        #expect(decoded == overlay)
    }

    @Test("an overlay written before a field existed still loads")
    func lenientDecoding() throws {
        let (_, decoder) = makeCoders()
        let json = """
            {"projectID":"\(UUID().uuidString)","repos":[],"notes":"","items":{}}
            """
        let decoded = try decoder.decode(ProjectOverlay.self, from: Data(json.utf8))
        #expect(decoded.vaultFolder == nil)
        #expect(decoded.planFile == nil)
        #expect(decoded.personalOrder == nil)
    }

    @Test("an item overlay written before a field existed still loads")
    func lenientItemDecoding() throws {
        let (_, decoder) = makeCoders()
        let decoded = try decoder.decode(ItemOverlay.self, from: Data("{}".utf8))
        #expect(decoded.notes.isEmpty)
        #expect(decoded.timeEntries.isEmpty)
        #expect(decoded.sessions.isEmpty)
        #expect(decoded.personalOrder == nil)
    }

    @Test("a hand-written time entry with no note still loads")
    func lenientTimeEntryDecoding() throws {
        let (_, decoder) = makeCoders()
        let json = """
            {"id":"\(UUID().uuidString)","minutes":30,"spentOn":"2026-08-25T00:00:00Z"}
            """
        let decoded = try decoder.decode(TimeEntry.self, from: Data(json.utf8))
        #expect(decoded.note.isEmpty)
        #expect(decoded.minutes == 30)
    }

    @Test("an empty item overlay knows it is empty, a used one does not")
    func emptiness() {
        #expect(ItemOverlay().isEmpty)
        var used = ItemOverlay()
        used.notes = "x"
        #expect(used.isEmpty == false)
        var ordered = ItemOverlay()
        ordered.personalOrder = 0
        // personalOrder == 0 is a REAL position, not absence. `isEmpty` must not
        // treat a top-of-list item as empty and prune it away.
        #expect(ordered.isEmpty == false)
    }

    @Test("a project overlay is empty only when nothing in it is used")
    func projectEmptiness() {
        let id = UUID()
        #expect(ProjectOverlay(projectID: id).isEmpty)
        var withItem = ProjectOverlay(projectID: id)
        withItem.setItem(ItemOverlay(), for: UUID())
        // An item entry holding an EMPTY overlay does not make the project
        // overlay non-empty, or pruning could never reclaim anything.
        #expect(withItem.isEmpty)
        var withNotes = ProjectOverlay(projectID: id)
        withNotes.notes = "x"
        #expect(withNotes.isEmpty == false)
    }
}
