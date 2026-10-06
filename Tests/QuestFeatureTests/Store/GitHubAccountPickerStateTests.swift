import Foundation
import Testing

@testable import QuestFeature

/// Covers `GitHubAccountPickerState` and `ConnectionDraft.apply(login:token:)`
/// — the logic behind Task B's "pick a gh account" alternative to typing a
/// token — against `InMemoryGitHubAccountSource`, never a real `gh`
/// subprocess.
@MainActor
@Suite("GitHub account picker state")
struct GitHubAccountPickerStateTests {
    private let workAccount = GitHubAccount(
        login: "ahmed-work", host: "github.com",
        isActive: true, scopes: ["repo", "gist"], isHealthy: true)
    private let noRepoScopeAccount = GitHubAccount(
        login: "ahmed-limited", host: "github.com",
        isActive: false, scopes: ["gist"], isHealthy: true)

    @Test("loading surfaces the accounts the source reports")
    func loadsAccounts() async {
        let source = InMemoryGitHubAccountSource(accounts: [workAccount, noRepoScopeAccount])
        let picker = GitHubAccountPickerState(source: source)
        await picker.load()
        #expect(picker.isLoading == false)
        #expect(picker.errorMessage == nil)
        #expect(Set(picker.accounts.map(\.login)) == ["ahmed-work", "ahmed-limited"])
    }

    @Test("an account without repo scope is flagged, not silently listed")
    func flagsMissingRepoScope() {
        #expect(noRepoScopeAccount.hasRepoScope == false)
        #expect(workAccount.hasRepoScope == true)
    }

    @Test("picking an account fills the draft's identifier and secret and marks it CLI-backed")
    func pickFillsDraft() async {
        let source = InMemoryGitHubAccountSource(
            accounts: [workAccount],
            tokens: [workAccount.id: "gho_abc123"])
        let picker = GitHubAccountPickerState(source: source)
        var draft = ConnectionDraft(provider: .githubProjects)

        let picked = await picker.pick(workAccount)
        #expect(picked != nil)
        if let picked { draft.apply(login: picked.login, token: picked.token) }

        #expect(draft.accountIdentifier == "ahmed-work")
        #expect(draft.secret == "gho_abc123")
        #expect(draft.tokenProvenance == .githubCLI)
        #expect(picker.errorMessage == nil)
        #expect(picker.isLoading == false)
    }

    @Test("a GitHubCLIError from a failed load surfaces its actionable message")
    func loadErrorSurfacesMessage() async {
        let source = InMemoryGitHubAccountSource(accountsError: GitHubCLIError.notLoggedIn)
        let picker = GitHubAccountPickerState(source: source)
        await picker.load()
        #expect(picker.accounts.isEmpty)
        #expect(picker.errorMessage == GitHubCLIError.notLoggedIn.message)
    }

    @Test("cliNotInstalled surfaces its actionable message the same way")
    func cliNotInstalledSurfacesMessage() async {
        let source = InMemoryGitHubAccountSource(accountsError: GitHubCLIError.cliNotInstalled)
        let picker = GitHubAccountPickerState(source: source)
        await picker.load()
        #expect(picker.errorMessage == GitHubCLIError.cliNotInstalled.message)
    }

    @Test("a failed token fetch leaves the draft untouched and surfaces the message")
    func tokenFetchFailureLeavesDraftUntouched() async {
        let source = InMemoryGitHubAccountSource(
            accounts: [workAccount],
            tokenError: GitHubCLIError.timedOut)
        let picker = GitHubAccountPickerState(source: source)
        var draft = ConnectionDraft(provider: .githubProjects)
        draft.accountIdentifier = "typed-already"
        draft.secret = "typed-token"

        let picked = await picker.pick(workAccount)
        #expect(picked == nil)
        #expect(draft.accountIdentifier == "typed-already")
        #expect(draft.secret == "typed-token")
        #expect(draft.tokenProvenance == .manual)
        #expect(picker.errorMessage == GitHubCLIError.timedOut.message)
    }

    @Test("editing the secret by hand after a pick disowns the CLI provenance")
    func manualEditDisownsProvenance() {
        var draft = ConnectionDraft(provider: .githubProjects)
        draft.apply(login: "ahmed-work", token: "gho_abc123")
        #expect(draft.tokenProvenance == .githubCLI)

        // The settings catalog's token field calls `setManualSecret(_:)` on
        // every keystroke — this is the actual rule under test, not a stand-in
        // for it, since the method is the real call site the view uses.
        draft.setManualSecret("typed-over")

        #expect(draft.secret == "typed-over")
        #expect(draft.tokenProvenance == .manual)
    }
}
