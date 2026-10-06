import Foundation

/// Input validation at the boundary where links enter the system.
public enum LinkValidation {
    public enum Outcome {
        case valid(Link)
        case invalid(String)

        public var value: Link? { if case .valid(let link) = self { link } else { nil } }
        public var isFailure: Bool { value == nil }
    }

    /// Repo-scoped schemes must name their repo: a project with eleven repos
    /// cannot resolve a bare branch name, and storing one would produce a link
    /// that looks fine and goes nowhere.
    public static func normalize(
        scheme: LinkScheme, identifier: String,
        label: String, repo: String?
    ) -> Outcome {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return .invalid("A link needs an identifier.") }

        let repoScoped: Set<LinkScheme> = [.branch, .pr, .commit]
        let trimmedRepo = repo?.trimmingCharacters(in: .whitespacesAndNewlines)
        if repoScoped.contains(scheme), trimmedRepo?.isEmpty != false {
            return .invalid("A \(scheme.rawValue) link must say which repo it belongs to.")
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return .valid(
            Link(
                scheme: scheme, identifier: trimmedIdentifier,
                label: trimmedLabel.isEmpty ? trimmedIdentifier : trimmedLabel,
                repo: repoScoped.contains(scheme) ? trimmedRepo : nil))
    }
}
