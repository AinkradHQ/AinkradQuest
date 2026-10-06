import Foundation

/// Which backend a connection speaks to. `local` is the native tracker, which
/// is a provider like any other so that nothing above the adapter layer has to
/// special-case an unlinked project.
enum ProviderKind: String, Codable, Sendable {
    case local, jira, linear, githubProjects
}

/// Where a connection's secret came from. Nothing reads this yet beyond
/// display, but it is recorded so a future refresh path can know whether a
/// stale token can be silently re-pulled from `gh` or needs the user to type
/// a new one.
enum TokenProvenance: String, Codable, Sendable {
    /// Typed in by hand — the only path for a provider `gh` does not know, or
    /// a token that predates this feature.
    case manual
    /// Fetched via `gh auth token` from an account the GitHub CLI already
    /// knew about.
    case githubCLI
}

/// One authenticated account at one provider. Deliberately NOT a global app
/// setting: two Jira sites and three GitHub identities coexist, and each
/// project binds to exactly one of them.
struct Connection: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var provider: ProviderKind
    /// What the user calls this account in the UI ("Work Jira").
    var accountLabel: String
    /// What the provider calls it — email, login, workspace slug. Used to
    /// refuse a duplicate registration of the same account.
    var accountIdentifier: String
    /// Self-hosted and per-site providers need this; Linear does not.
    var baseURL: URL?
    /// The Keychain account key. The secret itself is NEVER stored here — this
    /// document is written to disk in the clear.
    var credentialRef: String
    var createdAt: Date
    /// Where the secret behind `credentialRef` came from. Defaults to
    /// `.manual` for anything that predates this field.
    var tokenProvenance: TokenProvenance

    static func credentialRef(for id: UUID) -> String {
        "quest.connection.\(id.uuidString)"
    }

    init(
        id: UUID, provider: ProviderKind, accountLabel: String,
        accountIdentifier: String, baseURL: URL? = nil,
        createdAt: Date = Date(), tokenProvenance: TokenProvenance = .manual
    ) {
        self.id = id
        self.provider = provider
        self.accountLabel = accountLabel
        self.accountIdentifier = accountIdentifier
        self.baseURL = baseURL
        self.credentialRef = Self.credentialRef(for: id)
        self.createdAt = createdAt
        self.tokenProvenance = tokenProvenance
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, accountLabel, accountIdentifier, baseURL, credentialRef, createdAt
        case tokenProvenance
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // A connection written by a future Quest naming a provider this build
        // does not know decodes to `.local` rather than throwing, which would
        // take the whole registry down with it.
        let raw = try container.decode(String.self, forKey: .provider)
        provider = ProviderKind(rawValue: raw) ?? .local
        accountLabel = try container.decode(String.self, forKey: .accountLabel)
        accountIdentifier = try container.decode(String.self, forKey: .accountIdentifier)
        baseURL = try container.decodeIfPresent(URL.self, forKey: .baseURL)
        credentialRef =
            try container.decodeIfPresent(String.self, forKey: .credentialRef)
            ?? Self.credentialRef(for: id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // A connection written before this feature has no provenance field at
        // all — decode leniently to `.manual` rather than failing the whole
        // registry load, matching `Project.connectionID` and
        // `AttachedRepo.owner`'s lenient-decode convention.
        tokenProvenance =
            try container.decodeIfPresent(TokenProvenance.self, forKey: .tokenProvenance)
            ?? .manual
    }
}
