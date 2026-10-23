import AinkradAppKit
import Foundation
import QuestCitadelAPI
import Testing

@testable import QuestFeature

private final class MemorySecrets: PluginSecretStore, @unchecked Sendable {
    var storage: [String: String] = [:]
    func secret(forKey key: String) -> String? { storage[key] }
    func setSecret(_ value: String?, forKey key: String) { storage[key] = value }
}

@MainActor
@Suite("QuestServerStore")
struct QuestServerStoreTests {
    @Test("server mode survives a relaunch, and Disconnect leaves this Mac's projects untouched")
    func serverModeAndLocalData() {
        let documents = MemoryDocumentStore()
        documents.setData(Data("local".utf8), forKey: "index")
        let secrets = MemorySecrets()
        let store = QuestServerStore(documents: documents, secrets: secrets)
        #expect(!store.isServerMode)
        store.update {
            $0.server = "https://citadel.example.com"
            $0.hasConnected = true
        }
        let relaunched = QuestServerStore(documents: documents, secrets: secrets)
        #expect(relaunched.isServerMode)
        relaunched.disconnect()
        #expect(!relaunched.isServerMode)
        #expect(documents.data(forKey: "index") == Data("local".utf8))
    }

    @Test("an agent's change to an issue flashes its row; an unknown event type is skipped")
    func eventsFlash() throws {
        let store = QuestServerStore(documents: MemoryDocumentStore(), secrets: MemorySecrets())
        let event = try EventFrame.decoder.decode(
            Schemas.Event.self,
            from: Data(
                """
                {"seq": 4, "at": "2026-10-23T10:00:00.000Z", "payload": {"type": "audit", "audit_seq": 9,
                 "action": "issue.in_review", "actor": {"kind": "agent", "agent_id": 3}, "details": {},
                 "entity_kind": "issue", "entity_id": 62}}
                """.utf8))
        store.received(event)
        #expect(store.flashing.contains(62))
        let unknown = try EventFrame.decode(Data(#"{"seq": 5, "payload": {"type": "brand_new"}}"#.utf8))
        #expect(unknown.seq == 5 && unknown.event == nil)
    }
}
