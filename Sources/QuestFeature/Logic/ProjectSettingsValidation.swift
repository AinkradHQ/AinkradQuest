import Foundation

/// Validation for the settings sheet, pure so it can be tested without a view.
enum ProjectSettingsValidation {
    /// Mirrors `LinkValidation.Outcome`: either the normalized value or the
    /// message to put in front of the user.
    enum NameOutcome: Equatable {
        case valid(String)
        case invalid(String)

        var value: String? { if case .valid(let name) = self { name } else { nil } }
    }

    /// The same rule `ProjectSidebar.create()` enforces on the creation path.
    /// It was enforced there and nowhere else, so a rename could empty a name
    /// that could not have been created empty, producing a nameless sidebar row.
    static func validate(name: String) -> NameOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid("A project needs a name.") }
        return .valid(trimmed)
    }
}
