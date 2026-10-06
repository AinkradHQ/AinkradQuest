import Testing

@testable import QuestFeature

@Suite("LinkValidation")
struct LinkValidationTests {
    @Test("a repo-scoped link without a repo is refused")
    func repoRequired() {
        let result = LinkValidation.normalize(
            scheme: .branch, identifier: "main",
            label: "main", repo: nil)
        #expect(result.value == nil)
    }

    @Test("a repo-scoped link with a repo is accepted and keeps it")
    func repoKept() throws {
        let link = try #require(
            LinkValidation.normalize(
                scheme: .pr, identifier: "42", label: "PR 42", repo: "optimus-api"
            ).value)
        #expect(link.repo == "optimus-api")
    }

    @Test("an empty identifier is refused for every scheme")
    func emptyIdentifier() {
        #expect(
            LinkValidation.normalize(
                scheme: .url, identifier: "  ",
                label: "x", repo: nil
            ).value == nil)
    }

    @Test("a missing label falls back to the identifier rather than being blank")
    func labelFallback() throws {
        let link = try #require(
            LinkValidation.normalize(
                scheme: .folder, identifier: "~/Projects/quest", label: "", repo: nil
            ).value)
        #expect(link.label == "~/Projects/quest")
    }

    @Test(
        "a whitespace-only repo is treated as missing for a repo-scoped scheme",
        arguments: [LinkScheme.branch, .pr, .commit])
    func whitespaceOnlyRepoRefused(scheme: LinkScheme) {
        let result = LinkValidation.normalize(
            scheme: scheme, identifier: "main",
            label: "main", repo: "   ")
        #expect(result.value == nil)
    }

    @Test("a whitespace-only identifier is refused for a non-repo scheme")
    func whitespaceOnlyIdentifierRefused() {
        let result = LinkValidation.normalize(
            scheme: .file, identifier: "   \n",
            label: "x", repo: nil)
        #expect(result.value == nil)
    }

    @Test("a whitespace-only label falls back to the trimmed identifier")
    func whitespaceOnlyLabelFallsBack() throws {
        let link = try #require(
            LinkValidation.normalize(
                scheme: .url, identifier: "  https://example.com  ", label: "   ", repo: nil
            ).value)
        #expect(link.label == "https://example.com")
    }

    @Test("a valid link's identifier, label, and repo come back trimmed")
    func fieldsAreTrimmed() throws {
        let link = try #require(
            LinkValidation.normalize(
                scheme: .pr, identifier: "  42  ", label: "  PR 42  ", repo: "  optimus-api  "
            ).value)
        #expect(link.identifier == "42")
        #expect(link.label == "PR 42")
        #expect(link.repo == "optimus-api")
    }

    @Test("a non-repo scheme never carries a repo even if one is supplied")
    func stripsRepoForNonRepoSchemes() throws {
        let link = try #require(
            LinkValidation.normalize(
                scheme: .url, identifier: "https://example.com",
                label: "Docs", repo: "quest"
            ).value)
        #expect(link.repo == nil)
    }

    @Test("a commit link keeps its repo")
    func commitKeepsRepo() throws {
        let link = try #require(
            LinkValidation.normalize(
                scheme: .commit, identifier: "7683373", label: "", repo: "quest"
            ).value)
        #expect(link.repo == "quest")
        #expect(link.label == "7683373")
    }
}
