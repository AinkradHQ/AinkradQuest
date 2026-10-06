import Foundation
import Testing

@testable import QuestFeature

@Suite("StatusDraft")
struct StatusDraftTests {
    @Test("drafts round-trip a scheme unchanged")
    func roundTrip() {
        let drafts = StatusDraft.drafts(from: .softwareDefault)
        #expect(StatusDraft.scheme(from: drafts) == StatusScheme.softwareDefault)
    }

    @Test("a new draft gets an id derived from its name, unique against the others")
    func newIDs() {
        let existing = StatusDraft.drafts(from: .softwareDefault)
        let first = StatusDraft.make(name: "Blocked", existing: existing)
        #expect(first.id == "blocked")

        let second = StatusDraft.make(name: "Blocked", existing: existing + [first])
        #expect(second.id != first.id)
    }

    @Test("a name that yields no usable id still produces one")
    func awkwardName() {
        let draft = StatusDraft.make(name: "   ", existing: [])
        #expect(!draft.id.isEmpty)
    }

    @Test("an existing status keeps its id when renamed, because items store the id")
    func renameKeepsID() {
        var drafts = StatusDraft.drafts(from: .softwareDefault)
        drafts[3].name = "QA"
        #expect(StatusDraft.scheme(from: drafts).statuses[3].id == "in_review")
        #expect(StatusDraft.scheme(from: drafts).statuses[3].name == "QA")
    }
}
