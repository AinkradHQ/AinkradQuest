import Foundation
import Observation

/// Backs the "pick a `gh` account" alternative to typing a token, for the
/// GitHub Projects provider only. Split out of `ConnectionEditor` so the
/// logic — mapping an account pick or a `GitHubCLIError` to draft fields and
/// display text — is testable without a view host, the same split
/// `ConnectionDraft` gets.
///
/// `GitHubAccountSource.accounts()` and `.token(for:)` shell out and block, so
/// every call into `source` here runs off the main actor (`Task.detached`)
/// and only the result hop back onto it — a blocking subprocess on the main
/// actor would freeze the window.
@MainActor
@Observable
public final class GitHubAccountPickerState {
    public private(set) var accounts: [GitHubAccount] = []
    /// True while either `accounts()` or `token(for:)` is running off-actor.
    public private(set) var isLoading = false
    /// `.cliNotInstalled` and `.notLoggedIn` are expected, common states, not
    /// rare errors — their `.message` is already actionable, so it is shown
    /// here verbatim and the user carries on with manual entry.
    public private(set) var errorMessage: String?

    /// Builds the source lazily rather than holding one directly: the real
    /// `GitHubCLI.init()` itself can shell out (locating the binary via
    /// `/usr/bin/which` when it is not at a known path), so even
    /// CONSTRUCTING the real conformance must happen off the main actor.
    /// Defaults to the real CLI; tests inject `InMemoryGitHubAccountSource`.
    private let makeSource: @Sendable () throws -> any GitHubAccountSource

    public init(makeSource: @escaping @Sendable () throws -> any GitHubAccountSource = { try GitHubCLI() }) {
        self.makeSource = makeSource
    }

    public convenience init(source: any GitHubAccountSource) {
        self.init(makeSource: { source })
    }

    /// Loads the accounts `gh` already knows about. Safe to call repeatedly
    /// (e.g. a "Refresh" action) — each call replaces the previous result.
    public func load() async {
        isLoading = true
        errorMessage = nil
        let makeSource = self.makeSource
        let outcome = await Task.detached {
            Result { try makeSource().accounts() }
        }.value
        isLoading = false
        switch outcome {
        case .success(let accounts):
            self.accounts = accounts
        case .failure(let error):
            self.accounts = []
            self.errorMessage = Self.message(for: error)
        }
    }

    /// Fetches the token for `account`. Returns the login and token to write
    /// into the draft on success (`pick(_:into:)` on `ConnectionDraft` does
    /// that), or `nil` on failure — leaving the draft untouched, since the
    /// caller keeps whatever was already typed — with the failure surfaced
    /// through `errorMessage` instead.
    ///
    /// Returns a plain value rather than taking `draft` `inout` because an
    /// `inout` binding cannot cross the `await` this method needs.
    public func pick(_ account: GitHubAccount) async -> (login: String, token: String)? {
        isLoading = true
        errorMessage = nil
        let makeSource = self.makeSource
        let outcome = await Task.detached {
            Result { try makeSource().token(for: account) }
        }.value
        isLoading = false
        switch outcome {
        case .success(let token):
            return (account.login, token)
        case .failure(let error):
            self.errorMessage = Self.message(for: error)
            return nil
        }
    }

    private static func message(for error: Error) -> String {
        // `.message`, never `.localizedDescription`, matching every other
        // `GitHubCLIError` call site in this codebase.
        (error as? GitHubCLIError)?.message ?? error.localizedDescription
    }
}
