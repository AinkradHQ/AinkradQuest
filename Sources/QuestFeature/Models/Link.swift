import Foundation

/// The link kinds Quest can resolve today. Unknown values decode to `.unknown`
/// so a link written by a future version is displayed rather than dropped —
/// this is what lets M2 add resolvers with no data migration.
enum LinkScheme: String, Codable, Sendable, Hashable {
    case file, folder, url, repo, branch, pr, commit, unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LinkScheme(rawValue: raw) ?? .unknown
    }
}

struct Link: Codable, Sendable, Hashable, Identifiable {
    /// Identity INCLUDES the repo, because a project with eleven repos routinely
    /// has `branch main` in several of them: without the repo those are one id,
    /// and removing one deletes whichever the array happened to hold first.
    /// Computed, never encoded (see `ModelCodingTests.linkIDIsNotPersisted`), so
    /// changing this formula migrates no persisted document.
    var id: String {
        if let repo, !repo.isEmpty {
            "\(scheme.rawValue):\(repo)#\(identifier)"
        } else {
            "\(scheme.rawValue):\(identifier)"
        }
    }
    var scheme: LinkScheme
    /// A path, URL, or repo-qualified reference. Repo-scoped schemes
    /// (`branch`, `pr`, `commit`) MUST carry their repo: a project with eleven
    /// repos cannot disambiguate "main" otherwise.
    var identifier: String
    var label: String
    /// Which repo a `branch`/`pr`/`commit` belongs to. Nil for other schemes.
    var repo: String?

    init(scheme: LinkScheme, identifier: String, label: String, repo: String? = nil) {
        self.scheme = scheme
        self.identifier = identifier
        self.label = label
        self.repo = repo
    }
}
