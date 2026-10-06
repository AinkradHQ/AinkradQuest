import Foundation

/// One account `gh` already knows about, from `gh auth status --json hosts`.
/// `gh` supports several accounts per host, and the same login can exist on
/// two different hosts (personal github.com vs. an Enterprise host) — those
/// are two distinct accounts, so `id` is derived from host + login rather
/// than login alone, mirroring how `Connection` scopes duplicate-detection by
/// provider rather than by account name alone.
public struct GitHubAccount: Sendable, Hashable, Identifiable {
    public let login: String
    public let host: String
    public let isActive: Bool
    public let scopes: [String]
    public let isHealthy: Bool

    public var id: String { "\(host)|\(login)" }

    /// Lets the UI warn before the user picks an account that cannot read
    /// repos at all, instead of failing later on the first repo fetch.
    public var hasRepoScope: Bool { scopes.contains("repo") }

    public init(login: String, host: String, isActive: Bool, scopes: [String], isHealthy: Bool) {
        self.login = login
        self.host = host
        self.isActive = isActive
        self.scopes = scopes
        self.isHealthy = isHealthy
    }
}

/// Typed failures for the `gh` CLI seam. Written to be read by a person AND by
/// the assistant, matching `QuestError.message`'s convention — each message
/// says what to do next, not just what went wrong.
public enum GitHubCLIError: Error, Equatable, Sendable, LocalizedError {
    /// `gh` was not found at any known install location or on `PATH`.
    case cliNotInstalled
    /// `gh` is installed but reports no accounts (`hosts` is empty/missing).
    case notLoggedIn
    /// The process exited non-zero; carries a trimmed stderr excerpt for
    /// diagnosis without ever carrying a token (these commands never emit one).
    case commandFailed(stderr: String)
    /// stdout was not the JSON shape expected — a truncated excerpt for
    /// diagnosis, never the raw payload logged elsewhere.
    case unparsableOutput(String)
    /// The subprocess did not exit within the bound in `GitHubCLI.runProcess`.
    /// Kept distinct from `.commandFailed`: a hang (locked Keychain, an MDM
    /// hook, an expired credential prompting interactive re-auth) has a
    /// different remedy than a normal non-zero exit.
    case timedOut

    public var message: String {
        switch self {
        case .cliNotInstalled:
            "GitHub CLI (`gh`) is not installed. Install it from https://cli.github.com "
                + "or `brew install gh`, then try again."
        case .notLoggedIn:
            "GitHub CLI is installed but not signed in to any account. "
                + "Run `gh auth login` in a terminal, then try again."
        case .commandFailed(let stderr):
            "GitHub CLI command failed: \(stderr.isEmpty ? "no error output." : stderr)"
        case .unparsableOutput(let excerpt):
            "Could not understand GitHub CLI's output (expected JSON): \(excerpt). "
                + "This may mean an incompatible `gh` version — try updating it."
        case .timedOut:
            "GitHub CLI stopped responding. Try running the same `gh auth` command "
                + "yourself in a terminal to see what it's waiting on (a locked Keychain "
                + "or an interactive sign-in prompt are common causes)."
        }
    }

    /// Routes `localizedDescription` through the same actionable text,
    /// matching `CredentialError`'s exact shape — otherwise a call site that
    /// only knows `Error.localizedDescription` gets Foundation's generic
    /// fallback instead of the message written for a person to read.
    public var errorDescription: String? { message }
}

/// The seam Task B's UI asks through. Mirrors `CredentialStore`'s shape: a
/// narrow protocol the view depends on, with a real subprocess-backed
/// conformance (`GitHubCLI`) and an in-memory test double below.
public protocol GitHubAccountSource: Sendable {
    func accounts() throws -> [GitHubAccount]
    func token(for account: GitHubAccount) throws -> String
}

/// The shape of `gh auth status --json hosts`. Decoded loosely — an extra
/// field `gh` adds in a future version must not break Quest, so unknown keys
/// are simply ignored rather than causing a decode failure. Kept as a
/// free-standing type because a protocol extension cannot nest types.
private struct GitHubHostsPayload: Decodable {
    struct Entry: Decodable {
        let state: String
        let active: Bool
        let host: String
        let login: String
        let scopes: String
    }
    let hosts: [String: [Entry]]
}

/// Namespace for the pure parser. Not a protocol requirement — an existential
/// `any GitHubAccountSource` cannot carry a static member — so this lives as
/// a free-standing enum that both `GitHubCLI` and the tests call directly.
public enum GitHubAccountParsing {
    /// Pure by design: no `Process`, no filesystem, no network. This is what
    /// makes the parsing testable against fixture strings instead of a real
    /// `gh` invocation — the subprocess wrapper (`GitHubCLI`) calls straight
    /// into this and adds nothing but I/O.
    public static func parseAccounts(_ data: Data) throws -> [GitHubAccount] {
        let payload: GitHubHostsPayload
        do {
            payload = try JSONDecoder().decode(GitHubHostsPayload.self, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 output>"
            let excerpt = text.prefix(200)
            throw GitHubCLIError.unparsableOutput(String(excerpt))
        }

        let accounts = payload.hosts.values.flatMap { entries in
            entries.map { entry in
                GitHubAccount(
                    login: entry.login,
                    host: entry.host,
                    isActive: entry.active,
                    scopes: entry.scopes
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty },
                    isHealthy: entry.state == "success"
                )
            }
        }

        guard !accounts.isEmpty else {
            throw GitHubCLIError.notLoggedIn
        }
        return accounts
    }
}

/// Test double. Keeps UI/view-model tests off a real `gh` subprocess, which
/// would otherwise make them environment-dependent and slow, exactly the
/// reason `InMemoryCredentialStore` exists for `CredentialStore`.
public final class InMemoryGitHubAccountSource: GitHubAccountSource, @unchecked Sendable {
    private var configuredAccounts: [GitHubAccount]
    private var accountsError: Error?
    private var tokens: [String: String]
    private var tokenError: Error?

    public init(
        accounts: [GitHubAccount] = [],
        accountsError: Error? = nil,
        tokens: [String: String] = [:],
        tokenError: Error? = nil
    ) {
        self.configuredAccounts = accounts
        self.accountsError = accountsError
        self.tokens = tokens
        self.tokenError = tokenError
    }

    public func setAccounts(_ accounts: [GitHubAccount]) {
        self.configuredAccounts = accounts
    }

    public func setAccountsError(_ error: Error?) {
        self.accountsError = error
    }

    public func setToken(_ token: String, for account: GitHubAccount) {
        tokens[account.id] = token
    }

    public func setTokenError(_ error: Error?) {
        self.tokenError = error
    }

    public func accounts() throws -> [GitHubAccount] {
        if let accountsError { throw accountsError }
        return configuredAccounts
    }

    public func token(for account: GitHubAccount) throws -> String {
        if let tokenError { throw tokenError }
        guard let token = tokens[account.id] else {
            throw GitHubCLIError.notLoggedIn
        }
        return token
    }
}
