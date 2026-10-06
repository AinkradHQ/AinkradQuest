import Foundation

/// The add/edit form's state, split out of the view so validation is testable
/// without a view host — the same split `ProjectSettingsValidationTests` uses.
struct ConnectionDraft: Equatable {
    var provider: ProviderKind
    var accountLabel: String = ""
    var accountIdentifier: String = ""
    var baseURLText: String = ""
    var secret: String = ""
    /// Set when `secret` was filled in by picking a `gh` account rather than
    /// typing a token. Reset to `.manual` the moment the user edits the
    /// secret field by hand, so a stale pick never gets credited as CLI-backed.
    var tokenProvenance: TokenProvenance = .manual

    init(provider: ProviderKind) {
        self.provider = provider
    }

    /// Whether this provider is addressed by site. Jira is per-site and GitHub
    /// may be Enterprise; Linear is a single host.
    var requiresBaseURL: Bool {
        provider == .jira
    }

    var baseURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme != nil, url.host != nil
        else { return nil }
        return url
    }

    var validationMessage: String? {
        func blank(_ value: String) -> Bool {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if blank(accountLabel) { return "Give this account a name." }
        if blank(accountIdentifier) { return "Enter the account's email or login." }
        if requiresBaseURL && blank(baseURLText) {
            return "Jira needs the site URL, e.g. https://you.atlassian.net"
        }
        if !blank(baseURLText) && baseURL == nil { return "That site URL is not valid." }
        if blank(secret) { return "A token is required." }
        return nil
    }

    var isValid: Bool { validationMessage == nil }

    /// Applies a successful `gh` account pick: fills the identifier and
    /// secret and marks their provenance as CLI-backed.
    mutating func apply(login: String, token: String) {
        accountIdentifier = login
        secret = token
        tokenProvenance = .githubCLI
    }

    /// Writes a hand-typed secret and disowns any previous `gh` pick — a
    /// token pulled from `gh` that the user then types over is no longer a
    /// `gh` token, and a future refresh path must not try to re-pull it from
    /// the CLI. Extracted so this rule is unit-testable on its own, since
    /// the settings catalog's token field (the only call site today) needs a
    /// host to exercise directly.
    mutating func setManualSecret(_ value: String) {
        secret = value
        tokenProvenance = .manual
    }
}
