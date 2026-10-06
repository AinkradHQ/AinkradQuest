import Foundation

/// The rule an inline row edit must satisfy. Pure so it is testable without a
/// view, and shared with nothing else — an empty title from an inline field is
/// the same mistake `ProjectSidebar.create()` and the settings sheet already
/// guard against, so a row must not be able to lose its name either.
enum InlineEdit {
    static func normalizedTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
