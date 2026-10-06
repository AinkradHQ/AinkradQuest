import Foundation
import Testing

@testable import QuestFeature

@Suite("QuestError")
struct QuestErrorTests {
    /// Every view and the MCP layer show errors through one
    /// `localizedDescription` catch; that is only right while it IS `message`.
    @Test("an untyped catch shows the typed message")
    func localizedDescriptionIsMessage() {
        let error: Error = QuestError.connectionInUse(UUID(), 2)
        #expect(error.localizedDescription == QuestError.connectionInUse(UUID(), 2).message)
    }
}
