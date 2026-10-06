import Testing

@testable import QuestFeature

@Suite("QuickCapture")
struct QuickCaptureTests {
    @Test("a bare line is a task with no labels")
    func plain() {
        let parsed = QuickCapture.parse("Fix the login redirect")
        #expect(parsed.title == "Fix the login redirect")
        #expect(parsed.type == .task)
        #expect(parsed.labels.isEmpty)
        #expect(parsed.priority == .none)
    }

    @Test("a leading type token sets the type and is stripped")
    func typeToken() {
        let parsed = QuickCapture.parse("bug: auth refresh loops")
        #expect(parsed.type == .bug)
        #expect(parsed.title == "auth refresh loops")
    }

    @Test("hash tokens become labels and are stripped from the title")
    func labels() {
        let parsed = QuickCapture.parse("Ship board #frontend #m1")
        #expect(parsed.title == "Ship board")
        #expect(parsed.labels == ["frontend", "m1"])
    }

    @Test("a trailing bang sets urgency")
    func priority() {
        #expect(QuickCapture.parse("Deploy now !!").priority == .urgent)
        #expect(QuickCapture.parse("Deploy soon !").priority == .high)
    }

    @Test("an empty or whitespace line yields no title")
    func empty() {
        #expect(QuickCapture.parse("   ").title.isEmpty)
    }
}
