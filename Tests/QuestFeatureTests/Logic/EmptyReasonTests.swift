import Testing

@testable import QuestFeature

@Suite("EmptyReason")
struct EmptyReasonTests {
    @Test("no project selected outranks every other reason")
    func noProject() {
        #expect(
            EmptyReason.classify(totalCount: 0, visibleCount: 0, hasProject: false)
                == .noProjectSelected)
        #expect(
            EmptyReason.classify(totalCount: 9, visibleCount: 0, hasProject: false)
                == .noProjectSelected)
    }

    @Test("a project with no items at all is noItems")
    func noItems() {
        #expect(EmptyReason.classify(totalCount: 0, visibleCount: 0, hasProject: true) == .noItems)
    }

    @Test("items exist but the filter hid them all")
    func filtered() {
        #expect(
            EmptyReason.classify(totalCount: 5, visibleCount: 0, hasProject: true)
                == .filteredOut)
    }

    @Test("anything visible is not empty")
    func notEmpty() {
        #expect(EmptyReason.classify(totalCount: 5, visibleCount: 2, hasProject: true) == .notEmpty)
    }

    @Test("every empty reason carries copy; only .notEmpty has none")
    func copy() {
        for reason in [EmptyReason.noProjectSelected, .noItems, .filteredOut] {
            #expect(!reason.icon.isEmpty)
            #expect(!reason.title.isEmpty)
            #expect(!reason.message.isEmpty)
        }
        #expect(EmptyReason.notEmpty.title.isEmpty)
    }

    @Test("noItems offers an action; filteredOut offers clearing the filter")
    func actions() {
        #expect(EmptyReason.noItems.actionTitle == "Add an item")
        #expect(EmptyReason.filteredOut.actionTitle == "Clear filters")
        #expect(EmptyReason.noProjectSelected.actionTitle == nil)
    }
}
