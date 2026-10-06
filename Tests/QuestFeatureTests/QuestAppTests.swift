import Testing

@testable import QuestFeature

@Suite("QuestApp")
struct QuestAppTests {
    @Test("identity matches the bundle metadata")
    @MainActor
    func identity() {
        #expect(QuestApp.id == "quest")
        #expect(QuestApp.displayName == "Quest")
        #expect(QuestApp.icon == "checklist")
    }
}
