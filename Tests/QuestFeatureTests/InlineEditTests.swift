import Testing

@testable import QuestFeature

@Suite("InlineEdit")
struct InlineEditTests {
    @Test("a trimmed title is accepted")
    func trims() {
        #expect(InlineEdit.normalizedTitle("  Fix auth  ") == "Fix auth")
    }

    @Test("an empty or whitespace title is rejected, so a row cannot lose its name")
    func rejectsEmpty() {
        #expect(InlineEdit.normalizedTitle("") == nil)
        #expect(InlineEdit.normalizedTitle("   ") == nil)
    }

    @Test("an unchanged title normalizes to itself, so no write is needed")
    func unchanged() {
        #expect(InlineEdit.normalizedTitle("Ship it") == "Ship it")
    }
}
