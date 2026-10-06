import Foundation

/// The attach-repo form's state, split out of the view for the same reason as
/// `ConnectionDraft`.
public struct RepoDraft: Equatable {
    public var connectionID: UUID?
    public var slugText: String = ""
    public var localPath: String = ""

    public init() {}

    private var parts: [String] {
        slugText.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    public var owner: String? {
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[0]
    }

    public var name: String? {
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    public var validationMessage: String? {
        // Connection first: a repo without one cannot be disambiguated between
        // two accounts that can both see the same slug.
        if connectionID == nil { return "Choose which account this repo comes from." }
        if owner == nil || name == nil { return "Enter the repo as owner/name." }
        return nil
    }

    public var isValid: Bool { validationMessage == nil }

    public func repo(id: UUID) -> AttachedRepo? {
        guard let connectionID, let owner, let name else { return nil }
        let path = localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachedRepo(
            id: id, connectionID: connectionID, owner: owner,
            name: name, localPath: path.isEmpty ? nil : path)
    }
}
