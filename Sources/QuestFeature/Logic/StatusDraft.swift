import Foundation

/// One editable row. Separate from `Status` because a row in flight may be
/// half-typed, and because a NEW row needs an id minted from its name while an
/// EXISTING row must keep the id items already store.
struct StatusDraft: Identifiable, Equatable {
    let id: String
    var name: String
    var category: StatusCategory
    var color: ProjectColorToken

    static func drafts(from scheme: StatusScheme) -> [StatusDraft] {
        scheme.statuses.map {
            StatusDraft(
                id: $0.id, name: $0.name, category: $0.category,
                color: ProjectColorToken.resolve($0.colorToken))
        }
    }

    static func scheme(from drafts: [StatusDraft]) -> StatusScheme {
        StatusScheme(
            statuses: drafts.map {
                Status(
                    id: $0.id, name: $0.name, category: $0.category,
                    colorToken: $0.color.rawValue)
            })
    }

    /// Mints a stable id from a name, unique among `existing`. Ids are permanent
    /// once items reference them, so this runs only when a row is created.
    static func make(name: String, existing: [StatusDraft]) -> StatusDraft {
        let base = name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let seed = base.isEmpty ? "status" : base
        var candidate = seed
        var suffix = 2
        while existing.contains(where: { $0.id == candidate }) {
            candidate = "\(seed)_\(suffix)"
            suffix += 1
        }
        return StatusDraft(
            id: candidate, name: name.isEmpty ? "New status" : name,
            category: .todo, color: .accentPrimary)
    }
}
