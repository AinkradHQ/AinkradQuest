import Foundation

/// What `ProjectSettingsSheet.save()` actually writes, pulled out so a test
/// can drive the SAME code the sheet calls rather than a hand-mirrored copy
/// of it — the same reason `ProjectSettingsValidation` above is a free
/// function instead of inline logic in `save()`.
///
/// Starts from the LIVE project (not the sheet's stale `draft`) and overlays
/// only the fields this sheet's controls actually own — Name, Summary, Icon,
/// Colour, Kind. Everything else on `live` (`links`, `state`, `archivedAt`,
/// `statusScheme`, and anything added to `Project` later) passes through
/// untouched, so nothing this sheet doesn't own can ever be reverted by a
/// stale `draft`, no matter what changed elsewhere while the sheet was open.
enum ProjectSettingsSheetWrite {
    static func apply(
        draft: Project, colorToken: ProjectColorToken, validatedName: String,
        to live: Project
    ) -> Project {
        var live = live
        live.name = validatedName
        // Genuinely owned by this sheet alone — nothing else writes it, so
        // last-writer-wins here is fine.
        live.summaryText = draft.summaryText
        live.icon = draft.icon
        live.colorToken = colorToken.rawValue
        live.kind = draft.kind
        return live
    }
}
