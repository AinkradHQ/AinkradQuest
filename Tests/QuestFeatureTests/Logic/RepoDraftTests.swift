import Foundation
import Testing

@testable import QuestFeature

@Suite("Repo draft")
struct RepoDraftTests {
    @Test("a well-formed slug splits into owner and name")
    func split() {
        var draft = RepoDraft()
        draft.connectionID = UUID()
        draft.slugText = "AhmedMElhalaby/AinkradQuest"
        #expect(draft.owner == "AhmedMElhalaby")
        #expect(draft.name == "AinkradQuest")
        #expect(draft.isValid)
    }

    @Test("a slug without a slash is rejected")
    func noSlash() {
        var draft = RepoDraft()
        draft.connectionID = UUID()
        draft.slugText = "AinkradQuest"
        #expect(draft.isValid == false)
        #expect(draft.validationMessage == "Enter the repo as owner/name.")
    }

    @Test("a slug with too many parts is rejected")
    func tooManyParts() {
        var draft = RepoDraft()
        draft.connectionID = UUID()
        draft.slugText = "a/b/c"
        #expect(draft.isValid == false)
        #expect(draft.validationMessage == "Enter the repo as owner/name.")
    }

    @Test("a repo with no connection chosen is rejected")
    func noConnection() {
        var draft = RepoDraft()
        draft.slugText = "a/b"
        #expect(draft.isValid == false)
        #expect(draft.validationMessage == "Choose which account this repo comes from.")
    }

    @Test("a valid draft builds an AttachedRepo carrying its connection")
    func buildsRepo() throws {
        let connectionID = UUID()
        var draft = RepoDraft()
        draft.connectionID = connectionID
        draft.slugText = "a/b"
        draft.localPath = "/Users/ahmed/Home/Projects/b"

        let repo = try #require(draft.repo(id: UUID()))
        #expect(repo.connectionID == connectionID)
        #expect(repo.slug == "a/b")
        #expect(repo.localPath == "/Users/ahmed/Home/Projects/b")
    }

    @Test("an empty local path becomes nil, not an empty string")
    func emptyPath() throws {
        var draft = RepoDraft()
        draft.connectionID = UUID()
        draft.slugText = "a/b"
        #expect(try #require(draft.repo(id: UUID())).localPath == nil)
    }
}
