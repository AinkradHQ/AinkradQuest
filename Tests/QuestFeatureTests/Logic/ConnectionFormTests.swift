import Foundation
import Testing

@testable import QuestFeature

@Suite("Connection form validation")
struct ConnectionFormTests {
    @Test("an empty draft is invalid")
    func empty() {
        #expect(ConnectionDraft(provider: .jira).isValid == false)
    }

    @Test("a complete Jira draft with a base URL is valid")
    func validJira() {
        var draft = ConnectionDraft(provider: .jira)
        draft.accountLabel = "Work"
        draft.accountIdentifier = "ahmed@work.com"
        draft.baseURLText = "https://work.atlassian.net"
        draft.secret = "token"
        #expect(draft.isValid)
        #expect(draft.baseURL == URL(string: "https://work.atlassian.net"))
    }

    @Test("Jira without a base URL is invalid and says why")
    func jiraNeedsBaseURL() {
        var draft = ConnectionDraft(provider: .jira)
        draft.accountLabel = "Work"
        draft.accountIdentifier = "ahmed@work.com"
        draft.secret = "token"
        #expect(draft.isValid == false)
        #expect(draft.validationMessage == "Jira needs the site URL, e.g. https://you.atlassian.net")
    }

    @Test("Linear does not need a base URL")
    func linearNeedsNoBaseURL() {
        var draft = ConnectionDraft(provider: .linear)
        draft.accountLabel = "Personal"
        draft.accountIdentifier = "ahmed"
        draft.secret = "lin_api_key"
        #expect(draft.isValid)
        #expect(draft.baseURL == nil)
    }

    @Test("a malformed base URL is rejected")
    func malformedBaseURL() {
        var draft = ConnectionDraft(provider: .jira)
        draft.accountLabel = "Work"
        draft.accountIdentifier = "ahmed@work.com"
        draft.baseURLText = "not a url"
        draft.secret = "token"
        #expect(draft.isValid == false)
        #expect(draft.validationMessage == "That site URL is not valid.")
    }

    @Test("a missing secret is rejected and never silently accepted")
    func missingSecret() {
        var draft = ConnectionDraft(provider: .linear)
        draft.accountLabel = "Personal"
        draft.accountIdentifier = "ahmed"
        #expect(draft.isValid == false)
        #expect(draft.validationMessage == "A token is required.")
    }

    @Test("whitespace-only fields do not count as filled in")
    func whitespace() {
        var draft = ConnectionDraft(provider: .linear)
        draft.accountLabel = "   "
        draft.accountIdentifier = "ahmed"
        draft.secret = "k"
        #expect(draft.isValid == false)
    }
}
