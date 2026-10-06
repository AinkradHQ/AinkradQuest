import Foundation
import Testing

@testable import QuestFeature

@Suite("Project settings — validation and colour tokens")
struct ProjectSettingsValidationTests {
    @Test("an empty or whitespace-only name is refused with a message")
    func emptyNameRefused() {
        for candidate in ["", "   ", "\n", " \t "] {
            switch ProjectSettingsValidation.validate(name: candidate) {
            case .valid(let name):
                Issue.record("expected \(candidate.debugDescription) to be refused, got \(name)")
            case .invalid(let message):
                #expect(!message.isEmpty)
            }
        }
    }

    @Test("a real name is accepted and trimmed, matching the creation path")
    func nameTrimmed() {
        #expect(ProjectSettingsValidation.validate(name: "  Quest  ").value == "Quest")
        #expect(ProjectSettingsValidation.validate(name: "Quest").value == "Quest")
    }

    @Test("the colour control offers theme token names, never raw colours")
    func tokensAreThemeNames() {
        let names = Set(ProjectColorToken.allCases.map(\.rawValue))
        #expect(
            names == [
                "accentPrimary", "accentSecondary", "success", "warning",
                "danger", "muted",
            ])
        // No stored value is a literal colour: nothing hex-like, nothing that
        // would survive a theme change as the wrong shade.
        #expect(names.allSatisfy { !$0.hasPrefix("#") })
    }

    @Test("an unresolvable stored token falls back to a renderable one")
    func unknownTokenResolves() {
        // Projects predating this control store the default "accent"; a document
        // could hold anything. Neither may leave the picker with no selection.
        #expect(ProjectColorToken.resolve("accent") == .accentPrimary)
        #expect(ProjectColorToken.resolve("#FF0000") == .accentPrimary)
        #expect(ProjectColorToken.resolve("warning") == .warning)
    }
}
